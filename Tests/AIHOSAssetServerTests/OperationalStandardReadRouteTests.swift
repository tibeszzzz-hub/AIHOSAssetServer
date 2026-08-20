import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F4: the operational standards read route
//
// Order WFOS-20260819-PSKS-025. `GET /api/v1/standards` moved from main() into
// Sources/AIHOSAssetServer/OperationalStandardReadRoutes.swift.
//
// WHY THESE TESTS
//   This is the route clients use to discover which standards exist and what each one
//   expects. Its projection is therefore the published shape of a standard: the lane
//   key, the track type and the expected window are what a caller uses to decide which
//   standard a reading belongs to, and requiredCount is what it compares against.
//   Dropping, renaming or reordering a column would compile and silently change the
//   API, so all nine are pinned, together with the sort and the decoded types.

private let routeFileName = "OperationalStandardReadRoutes.swift"

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

@Suite("F-F4 operational standards read route extraction")
struct OperationalStandardReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("standards") {"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the standards read route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerOperationalStandardReadRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The standard write routes deliberately stayed behind")
    func writeRoutesRemainInTheCompositionRoot() throws {
        let routeFile = try routeFileText()

        // The PATCH is still in the composition root; F-G7 moved the create into its
        // own file. Either way, no write may appear in the standards READ file.
        // Both standard writes now live in their own files. What this guards is
        // unchanged: no write may appear in a standards READ file.
        let patch = #"apiV1.on(.PATCH, "standards", ":standardID", "status")"#
        #expect(routeFile.contains(patch) == false, "Write route appeared in \(routeFileName): \(patch)")
        let statusSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "OperationalStandardStatusRoutes.swift" }?.text,
            "OperationalStandardStatusRoutes.swift is missing from the library"
        )
        #expect(statusSource.contains(patch))


        let create = #"apiV1.post("standards")"#
        #expect(routeFile.contains(create) == false, "Write route appeared in \(routeFileName): \(create)")
        let createSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "OperationalStandardCreateRoutes.swift" }?.text,
            "OperationalStandardCreateRoutes.swift is missing from the library"
        )
        #expect(createSource.contains(#"apiV1.post("standards")"#))


        // The night-photo fixation is also a write, and F-G1 moved it into a file of
        // its own. What this test guards is unchanged either way: no write may end up
        // in the standards READ file.
        let nightPhoto = #"apiV1.post("standards", "night-photo")"#
        #expect(routeFile.contains(nightPhoto) == false,
                "A write route appeared in \(routeFileName): \(nightPhoto)")

        let nightPhotoSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "NightPhotoStandardRoutes.swift" }?.text,
            "NightPhotoStandardRoutes.swift is missing from the library"
        )
        #expect(nightPhotoSource.contains(nightPhoto))
    }

    @Test("The status timeline route stayed in its own file")
    func timelineRouteIsNotAbsorbed() throws {
        // Two standards-scoped read routes now live in two files. Pinned so a later
        // consolidation is a deliberate change rather than something that drifts.
        // Code only: the header comment names the PATCH route when explaining what
        // stayed behind, and a whole-text match would flag that explanation.
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(":standardID") == false,
                "A standard-scoped route appeared in \(routeFileName)")
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarSignatureIsPinned() throws {
        #expect(try routeFileText().contains(
            "func registerOperationalStandardReadRoutes(on apiV1: MachineGatedRoutes) {"
        ))
    }

    @Test("The route file introduces no configuration lookup and no global state")
    func routeFileHasNoOwnConfigurationOrState() throws {
        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Query contract

    @Test("The query is read-only, unfiltered, and selects exactly the nine pinned columns")
    func queryContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for column in [
            "id,",
            #""standardKey","#,
            "lane_key,",
            "track_type,",
            "expected_window_start,",
            "expected_window_end,",
            #""requiredCount","#,
            "status,",
            "created_at"
        ] {
            #expect(code.contains(column), "Projected column changed or missing: \(column)")
        }

        #expect(code.contains("FROM operational_standards"))
        #expect(code.contains("ORDER BY created_at ASC"))

        // The listing is deliberately unfiltered: it returns every standard, including
        // inactive ones, and the caller decides. A WHERE clause here would silently
        // shrink what clients can see.
        #expect(code.contains("WHERE") == false,
                "The standards listing gained a filter, changing what clients receive")

        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }
    }

    // MARK: Response contract

    @Test("The response mapping, decoded types and status codes are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "guard let sql = req.db as? SQLDatabase else {",
            "return Response(status: .internalServerError)",
            "-> OperationalStandardResponse in",
            #"try row.decode(column: "id", as: UUID.self).uuidString"#,
            #"try row.decode(column: "standardKey", as: String.self)"#,
            #"try row.decode(column: "lane_key", as: String.self)"#,
            #"try row.decode(column: "track_type", as: String.self)"#,
            #"try row.decode(column: "expected_window_start", as: String.self)"#,
            #"try row.decode(column: "expected_window_end", as: String.self)"#,
            #"try row.decode(column: "status", as: String.self)"#,
            #"try row.decode(column: "created_at", as: String.self)"#,
            "let response = Response(status: .ok)",
            "try response.content.encode(standards)"
        ] {
            #expect(code.contains(pinned), "Response contract line changed or missing: \(pinned)")
        }

        // requiredCount is the only numeric field in the projection. Decoding it as a
        // String would compile at the call site and fail at runtime against real rows.
        #expect(code.contains(#"try row.decode(column: "requiredCount", as: Int.self)"#))

        // Log lines are contract: the sort and the source of truth are both stated.
        #expect(code.contains(#"print("Operational Standards retrieval PASS: \(standards.count) standards")"#))
        #expect(code.contains(#"print("Operational Standards sort: createdAt ASC")"#))
        #expect(code.contains(#"print("Operational Standards source: server-side operational_standards")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "lane_key,", with: "")

        #expect(mutated.contains("lane_key,") == false)
        #expect(try routeFileText().contains("lane_key,"))
    }
}
