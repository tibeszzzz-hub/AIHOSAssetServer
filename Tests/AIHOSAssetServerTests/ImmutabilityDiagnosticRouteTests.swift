import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G3: the immutability diagnostic route
//
// Order WFOS-20260820-PSKS-013. `GET /test/immutable` moved from main() into
// Sources/AIHOSAssetServer/ImmutabilityDiagnosticRoutes.swift.
//
// WHY THESE TESTS
//   This route proves the governance triggers on asset_records actually block UPDATE
//   and DELETE, and it does so by attempting exactly the writes that must fail. That
//   makes its success and failure inverted: for the two governance checks, a statement
//   that succeeds is the alarm, and the catch branches are the PASS paths.
//
//   Two ways to break it would both compile and both look like cleanups. Removing the
//   do/catch inversion would turn a governance alarm into a green light. Registering it
//   on `app` instead of `gated` would expose a route that writes real rows to whoever
//   can reach the host. Both are pinned below.

private let routeFileName = "ImmutabilityDiagnosticRoutes.swift"

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

@Suite("F-G3 immutability diagnostic route extraction")
struct ImmutabilityDiagnosticRouteTests {

    // MARK: Placement and classification

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"gated.get("test", "immutable")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the immutability diagnostic")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerImmutabilityDiagnosticRoutes(on: gated)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("It stays gated, and gated is what the receiver name makes it")
    func routeRemainsGated() throws {
        // The manifest resolves gate and prefix from the receiver's name, so `gated` is
        // what keeps this route classified as gated and spelled GET /test/immutable,
        // unprefixed. This route writes a real row, so registering it on `app` would
        // expose production writes to anyone who can reach the host.
        #expect(try routeFileText().contains(
            "func registerImmutabilityDiagnosticRoutes(on gated: MachineGatedRoutes) {"
        ))

        let code = try routeFileCodeLines().joined(separator: "\n")
        #expect(code.contains("app.") == false, "The diagnostic was registered outside the machine gate")
        #expect(code.contains("apiV1.") == false, "The diagnostic gained the /api/v1 prefix")

        // Confirmed against the pinned manifest rather than only against the source.
        #expect(unauthenticatedRouteAllowlist.contains("GET /test/immutable") == false,
                "The write-performing diagnostic was allowlisted for unauthenticated access")
    }

    // MARK: Dependencies

    @Test("The registrar takes the gated group and nothing else")
    func registrarTakesNothingElse() throws {
        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "storageDirectory", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: The inverted contract

    @Test("A successful UPDATE or DELETE is the failure case, not the success case")
    func governanceChecksStayInverted() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // The alarm messages sit in the do branch and return 500; the catch branches are
        // where PASS is reported. Removing the inversion would compile and turn a
        // governance failure into a green light.
        for alarm in [
            #"print("Immutable validation UPDATE unexpectedly succeeded")"#,
            #"print("Immutable validation DELETE unexpectedly succeeded")"#
        ] {
            #expect(code.contains(alarm), "Alarm path changed or missing: \(alarm)")
        }
        for pass in [
            #"print("Immutable validation UPDATE blocked by governance trigger")"#,
            #"print("Immutable validation DELETE blocked by governance trigger")"#
        ] {
            #expect(code.contains(pass), "PASS path changed or missing: \(pass)")
        }

        // Each alarm must be immediately followed by the 500 return, inside the do.
        for alarm in ["UPDATE unexpectedly succeeded", "DELETE unexpectedly succeeded"] {
            let alarmIndex = try #require(code.range(of: alarm)?.upperBound)
            let rest = code[alarmIndex...]
            let nextReturn = try #require(rest.range(of: "return .")?.upperBound)
            #expect(rest[..<nextReturn].hasSuffix("return .") == true)
            #expect(rest[nextReturn...].hasPrefix("internalServerError"),
                    "A succeeding \(alarm) no longer fails the diagnostic")
        }

        // Three statements, three do/catch blocks: insert, update, delete.
        #expect(code.components(separatedBy: "do {").count - 1 == 3)
        #expect(code.components(separatedBy: "} catch {").count - 1 == 3)
    }

    @Test("The insert is the only statement allowed to succeed")
    func insertIsTheOnlyExpectedSuccess() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"print("Immutable validation INSERT PASS")"#))
        #expect(code.contains(#"print("Immutable validation INSERT failed: \(error)")"#))

        // Unlike the other two, a failing INSERT is a genuine failure — the diagnostic
        // cannot test immutability on a row it never created.
        #expect(code.contains(#"INSERT INTO asset_records (id, "captureTimestamp", "sourceTag")"#))
        #expect(code.contains(#"VALUES ('\(unsafeRaw: testID)', 'test-capture-timestamp', '[TEST]');"#))

        // The row is written with a distinguishable source tag, and it is never cleaned
        // up — it cannot be, which is the property being demonstrated.
        #expect(code.contains("[TEST]"))
        #expect(code.contains("[TEST-UPDATED]"))
    }

    @Test("The statements target one generated row, and the final status is unchanged")
    func statementsAndStatusAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("let testID = UUID().uuidString"))
        #expect(code.components(separatedBy: #"\(unsafeRaw: testID)"#).count - 1 == 3,
                "The three statements no longer all target the same generated row")

        #expect(code.contains("UPDATE asset_records"))
        #expect(code.contains("DELETE FROM asset_records"))
        #expect(code.contains("guard let sql = req.db as? SQLDatabase else {"))
        #expect(code.contains(#"print("Immutable validation PASS")"#))
        #expect(code.contains("return .ok"))
        #expect(code.contains("-> HTTPStatus in"))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"gated.get("test", "immutable")"#,
                                  with: #"app.get("test", "immutable")"#)

        #expect(mutated.contains(#"gated.get("test", "immutable")"#) == false)
        #expect(try routeFileText().contains(#"gated.get("test", "immutable")"#))
    }
}
