import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G2: the database liveness probe
//
// Order WFOS-20260820-PSKS-011. `GET /health/db` moved from main() into
// Sources/AIHOSAssetServer/DatabaseHealthRoutes.swift.
//
// WHY THIS MOVE NEEDED MORE CARE THAN THE OTHERS
//   This is the only route in the server that answers without a machine credential, so
//   the thing at risk was never the SQL — it was the classification. Three mechanisms
//   decide it, and the tests below assert that each one still lands the same way:
//
//   1. The receiver's name. The route manifest resolves gate and prefix from it, so
//      registering on `app` is what keeps this route ungated and spelled /health/db.
//      Registering on `apiV1` or `gated` would silently change both and still compile.
//   2. `unauthenticatedRouteAllowlist`, which did not move and still holds exactly one
//      entry — and it must be the same route the source registers outside the gate.
//   3. `verifyMachineGateCoverage`, which refuses to boot on any mismatch and stayed in
//      the composition root.
//
//   The existing manifest and gate-inventory suites already scan the whole library and
//   passed this move unchanged. What is added here is the part they cannot see: that
//   the exposure decision stayed put while the registration moved.

private let routeFileName = "DatabaseHealthRoutes.swift"

private func routeFileText() throws -> String {
    try #require(
        try serverModuleSourceTexts().first { $0.name == routeFileName }?.text,
        "\(routeFileName) is missing from the library"
    )
}

/// Code lines only, so a term explained in a comment cannot satisfy or trip an assertion.
private func routeFileCodeLines() throws -> [String] {
    try routeFileText()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}

@Suite("F-G2 database health route extraction")
struct DatabaseHealthRouteTests {

    // MARK: Placement

    @Test("The probe is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"app.get("health", "db")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The probe is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the liveness probe")
    }

    @Test("main() reaches the probe only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerDatabaseHealthRoutes(on: app)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    // MARK: The classification did not move with the registration

    @Test("The registrar takes the application, so the route stays outside the gate")
    func registrarKeepsTheRouteUngated() throws {
        // The parameter name is load-bearing, not cosmetic: the manifest reads gate and
        // prefix from the receiver. `app` means ungated and unprefixed.
        #expect(try routeFileText().contains(
            "func registerDatabaseHealthRoutes(on app: Application) {"
        ))

        let code = try routeFileCodeLines().joined(separator: "\n")
        #expect(code.contains("apiV1.") == false, "The probe was registered on the gated group")
        #expect(code.contains("gated.") == false, "The probe was registered on the gated group")
    }

    @Test("The exposure decision stayed in the gate, and still names this one route")
    func allowlistIsUnchangedAndStillMatches() throws {
        // The allowlist is the single place that says a route may answer without a
        // credential. It did not move, still holds exactly one entry, and that entry is
        // the route this file registers outside the gate.
        #expect(unauthenticatedRouteAllowlist == ["GET /health/db"])

        // Code only: the header comment names both mechanisms when explaining that they
        // stayed behind, and a whole-text match would flag its own documentation.
        let code = try routeFileCodeLines().joined(separator: "\n")
        #expect(code.contains("unauthenticatedRouteAllowlist") == false,
                "The allowlist was copied into \(routeFileName)")
        #expect(code.contains("verifyMachineGateCoverage") == false,
                "The boot-time coverage check was dragged into \(routeFileName)")

        // The boot check itself stays in the composition root, where it runs once.
        #expect(try serverSourceText().contains("try verifyMachineGateCoverage(routes: app.routes.all)"))
    }

    @Test("It is still the only registration outside the gate, library-wide")
    func itRemainsTheSingleUngatedRegistration() throws {
        let verbs = ["get", "post", "put", "patch", "delete", "on", "webSocket", "group", "grouped"]
        let appLevel = trimmedSourceLines(try serverModuleSourceText())
            .filter { line in verbs.contains { line.hasPrefix("app.\($0)(") } }

        #expect(appLevel == [#"app.get("health", "db") { req async -> Response in"#],
                "Registrations outside the machine gate: \(appLevel)")
    }

    // MARK: The probe's own contract

    @Test("Both failure stages stay separately reportable")
    func twoStagesAreDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Reporting which half failed is the only thing this probe exists to tell the
        // platform apart. One boolean would hide it.
        #expect(code.contains(#"{"status":"fail","stage":"sql_cast"}"#))
        #expect(code.contains(#"{"status":"fail","stage":"select_1"}"#))
        #expect(code.contains(#"{"status":"ok","stage":"select_1"}"#))

        #expect(code.contains("guard let sql = req.db as? SQLDatabase else {"))
        #expect(code.contains(#"try await sql.raw("SELECT 1").run()"#))
        #expect(code.contains("} catch {"))
    }

    @Test("The unauthenticated body carries no operational data")
    func probeLeaksNothing() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // This is the one route reachable without a credential, so its body is a fixed
        // shape: no counts, no configuration, no identifiers.
        for forbidden in ["storageDirectory", "operationsTimeZone", "Environment.get",
                         "AIHOS_", "STORAGE_PATH", "asset_records", "operational_standards"] {
            #expect(code.contains(forbidden) == false, "\(forbidden) reachable without a credential")
        }

        // Written across lines in the source, so matched on the status arguments.
        #expect(code.contains("status: .ok,"))
        #expect(code.components(separatedBy: "status: .internalServerError,").count - 1 == 2,
                "The probe no longer reports both failure stages with 500")
        #expect(code.contains(#"headers.add(name: .contentType, value: "application/json")"#))

        for logged in [
            #"req.logger.info("DB HEALTH ROUTE ENTERED")"#,
            #"req.logger.error("DB HEALTH SQL CAST FAIL")"#,
            #"req.logger.info("DB HEALTH SQL CAST PASS")"#,
            #"req.logger.info("DB HEALTH SELECT 1 PASS")"#
        ] {
            #expect(code.contains(logged), "Log line changed or missing: \(logged)")
        }
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"app.get("health", "db")"#, with: #"apiV1.get("health", "db")"#)

        #expect(mutated.contains(#"app.get("health", "db")"#) == false)
        #expect(try routeFileText().contains(#"app.get("health", "db")"#))
    }
}
