import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G1: the night photo standard fixation route
//
// Order WFOS-20260820-PSKS-009. `POST /api/v1/standards/night-photo` moved from main()
// into Sources/AIHOSAssetServer/NightPhotoStandardRoutes.swift. First write route to
// leave the composition root; ingestion stays last and was not touched.
//
// WHY THESE TESTS
//   This route writes, so the failure modes differ from the read extractions. The one
//   that matters is idempotence: it is a fixation, not a create. The
//   INSERT ... SELECT ... WHERE NOT EXISTS is what makes a second call insert nothing
//   and still answer .ok. Rewritten as a plain INSERT it would compile, pass a first
//   call and then duplicate or fail on every call after that.
//
//   The seeded values are governance data, not defaults: the window, the required
//   count, the standard key and the "[?]" source tag are what the rest of the system
//   is built around, so each is pinned literally.

private let routeFileName = "NightPhotoStandardRoutes.swift"

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

@Suite("F-G1 night photo standard route extraction")
struct NightPhotoStandardRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.post("standards", "night-photo")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the night-photo route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerNightPhotoStandardRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("Ingestion stayed in the composition root and was not touched")
    func ingestionDidNotMove() throws {
        // Ingestion is explicitly last in the extraction order. Pinned so a write
        // extraction cannot drift into it.
        let source = try serverSourceText()
        let routeFile = try routeFileText()

        for ingestion in [
            #"apiV1.on(.POST, "sync""#,
            #"apiV1.on(.POST, "audio""#
        ] {
            #expect(source.contains(ingestion), "Ingestion route left the composition root: \(ingestion)")
            #expect(routeFile.contains(ingestion) == false)
        }
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarSignatureIsPinned() throws {
        // Nothing to thread: no value from main(), no request body, no path parameter,
        // no storage access.
        #expect(try routeFileText().contains(
            "func registerNightPhotoStandardRoutes(on apiV1: MachineGatedRoutes) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "storageDirectory", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }
        #expect(code.contains("req.content.decode") == false, "The route gained a request body")
        #expect(code.contains("req.parameters.get") == false, "The route gained a path parameter")

        for declaration in ["var ", "let ", "struct ", "func "] where declaration != "func " {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: Idempotence

    @Test("The write is a fixation, not a create")
    func writeIsIdempotent() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // The guard clause is the whole contract: a second call must insert nothing.
        #expect(code.contains("WHERE NOT EXISTS ("))
        #expect(code.contains("SELECT 1 FROM operational_standards"))
        #expect(code.contains(#"WHERE "standardKey" = \(bind: "night-photo-22-23")"#))

        // INSERT ... SELECT, not INSERT ... VALUES. The VALUES form cannot carry a
        // WHERE NOT EXISTS, so this distinction is what keeps the guard possible.
        #expect(code.contains("INSERT INTO operational_standards"))
        #expect(code.contains("VALUES (") == false,
                "The insert became a VALUES form, which cannot be guarded by WHERE NOT EXISTS")

        // Exactly one statement: a second write would escape the guard above.
        #expect(code.components(separatedBy: "INSERT INTO").count - 1 == 1)
        #expect(code.contains("sql.raw(") && code.contains(").run()"))
    }

    // MARK: The seeded values

    @Test("Every seeded value is unchanged")
    func seededValuesArePinned() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            #"INSERT INTO operational_standards (id, "standardKey", "description", "sourceTag", "startHour", "endHour", "requiredCount")"#,
            #"\(bind: UUID())"#,
            #"\(bind: "night-photo-22-23")"#,
            #"\(bind: "At least one photo between 22:00 and 23:00")"#,
            #"\(bind: "[?]")"#,
            #"\(bind: 22)"#,
            #"\(bind: 23)"#,
            #"\(bind: 1)"#
        ] {
            #expect(code.contains(pinned), "Seeded value changed or missing: \(pinned)")
        }

        // The source tag records that the standard is machine-fixated rather than
        // attributable to an operator or to the system's own reasoning. It is a
        // governance value, not a placeholder.
        #expect(code.contains(#"\(bind: "[M]")"#) == false)
        #expect(code.contains(#"\(bind: "[S]")"#) == false)
    }

    @Test("The status codes and the log line are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("guard let sql = req.db as? SQLDatabase else {"))
        #expect(code.contains("return .internalServerError"))
        #expect(code.contains("return .ok"))
        #expect(code.contains(#"print("Operational standard fixation PASS: night-photo-22-23")"#))

        // It returns a bare HTTPStatus, not a Response with a body.
        #expect(code.contains("-> HTTPStatus in"))
        #expect(code.contains("response.content.encode") == false)
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "WHERE NOT EXISTS (", with: "WHERE EXISTS (")

        #expect(mutated.contains("WHERE NOT EXISTS (") == false)
        #expect(try routeFileText().contains("WHERE NOT EXISTS ("))
    }
}
