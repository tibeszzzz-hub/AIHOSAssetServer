import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F3: the operational standard status timeline read route
//
// Order WFOS-20260819-PSKS-023. `GET /api/v1/standards/:standardID/status-updates`
// moved from main() into Sources/AIHOSAssetServer/StandardStatusTimelineReadRoutes.swift.
//
// WHY THESE TESTS
//   This route reports the governance history of an operational standard, so three
//   things matter beyond it compiling: the sort direction (a timeline read backwards
//   misleads the reader), the JSON body on the 400 path (it is a payload, not just a
//   status code, and it is the only one of the three extracted routes that has one),
//   and the projection. None of those is protected by the type checker.
//
// Route count and gating stay covered by the manifest and the gate inventory, both of
// which already scan the whole library.

private let routeFileName = "StandardStatusTimelineReadRoutes.swift"

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

@Suite("F-F3 standard status timeline read route extraction")
struct StandardStatusTimelineReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("standards", ":standardID", "status-updates")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the status timeline route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerStandardStatusTimelineReadRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The standard write routes deliberately stayed behind")
    func writeRoutesRemainInTheCompositionRoot() throws {
        // Creating a standard and changing its status are writes and stay in the
        // composition root. Pinned so moving them later is a decision, not a tidy-up.
        let source = try serverSourceText()
        let routeFile = try routeFileText()

        // The PATCH is still in the composition root; F-G7 moved the create into its
        // own file. Either way, no write may appear in the standards READ file.
        let patch = #"apiV1.on(.PATCH, "standards", ":standardID", "status")"#
        #expect(source.contains(patch), "Write route left the composition root: \(patch)")
        #expect(routeFile.contains(patch) == false, "Write route appeared in \(routeFileName): \(patch)")

        let create = #"apiV1.post("standards")"#
        #expect(routeFile.contains(create) == false, "Write route appeared in \(routeFileName): \(create)")
        let createSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "OperationalStandardCreateRoutes.swift" }?.text,
            "OperationalStandardCreateRoutes.swift is missing from the library"
        )
        #expect(createSource.contains(#"apiV1.post("standards")"#))

    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarSignatureIsPinned() throws {
        // One parameter is the point: the handler takes its database from `req.db`, so
        // nothing had to be threaded through from main(). The label `apiV1` is
        // load-bearing for how the manifest resolves gate and prefix.
        #expect(try routeFileText().contains(
            "func registerStandardStatusTimelineReadRoutes(on apiV1: MachineGatedRoutes) {"
        ))
    }

    @Test("The route file introduces no configuration lookup and no global state")
    func routeFileHasNoOwnConfigurationOrState() throws {
        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        // Column zero makes this a scope check rather than a spelling check.
        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Query contract

    @Test("The query is read-only and selects exactly the five pinned columns")
    func queryContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "SELECT",
            "id,",
            "standard_id,",
            "status,",
            "source_tag,",
            "changed_at",
            "FROM standard_status_updates",
            #"WHERE standard_id = \(bind: standardID)"#,
            "ORDER BY changed_at ASC"
        ] {
            #expect(code.contains(pinned), "Query contract element changed or missing: \(pinned)")
        }

        // Ascending is the contract, and it is the opposite of the one descending sort
        // in the library (isStandardActive, which wants the latest status only). Getting
        // these two the wrong way round would compile and quietly invert a timeline.
        #expect(code.contains("ORDER BY changed_at DESC") == false,
                "The status timeline is sorted newest-first, reversing the history it reports")

        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }
    }

    // MARK: Response contract

    @Test("The response mapping, status codes and the 400 body are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "guard let sql = req.db as? SQLDatabase else {",
            "return Response(status: .internalServerError)",
            #"guard let standardIDString = req.parameters.get("standardID"),"#,
            "let standardID = UUID(uuidString: standardIDString) else {",
            "let response = Response(status: .badRequest)",
            "-> StandardStatusUpdateResponse in",
            #"try row.decode(column: "id", as: UUID.self).uuidString"#,
            #"try row.decode(column: "standard_id", as: UUID.self).uuidString"#,
            #"try row.decode(column: "status", as: String.self)"#,
            #"try row.decode(column: "source_tag", as: String.self)"#,
            #"try row.decode(column: "changed_at", as: String.self)"#,
            "let response = Response(status: .ok)",
            "try response.content.encode(updates)"
        ] {
            #expect(code.contains(pinned), "Response contract line changed or missing: \(pinned)")
        }

        // The 400 carries a body, unlike the other two extracted read routes. A client
        // reading `reason` would break silently if this became a bare status code.
        #expect(code.contains(#""reason": "invalid operational standard id""#))

        // Log lines are contract: the sort is stated in the log so an operator reading
        // it can tell which direction the timeline came back in.
        #expect(code.contains(#"print("Standard Status Timeline retrieval failed: invalid standardID")"#))
        #expect(code.contains(#"print("Standard Status Timeline retrieval PASS: \(updates.count) updates")"#))
        #expect(code.contains(#"print("Status Timeline sort: changed_at ASC")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "ORDER BY changed_at ASC", with: "ORDER BY changed_at DESC")

        #expect(mutated.contains("ORDER BY changed_at ASC") == false)
        #expect(mutated.contains("ORDER BY changed_at DESC"))
    }
}
