import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F7: the shift handover log read route
//
// Order WFOS-20260820-PSKS-003. `GET /api/v1/shift-handover/log` moved from main() into
// Sources/AIHOSAssetServer/ShiftHandoverReadRoutes.swift.
//
// WHY THESE TESTS
//   This is the only read that merges two unrelated tables into one chronological
//   stream. Neither query orders in SQL, because ordering across two result sets can
//   only happen after they are merged — so the Swift comparator is the entire ordering
//   contract, not a refinement of a database sort. Adding an ORDER BY here would look
//   like an improvement and would change nothing except to hide that fact.
//
//   Three more properties are contract rather than style: the lane fallback chain, the
//   three message shapes an operator reads at handover, and the nullable decodes. Each
//   would compile if broken and fail, or mislead, only against real rows.

private let routeFileName = "ShiftHandoverReadRoutes.swift"

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

@Suite("F-F7 shift handover read route extraction")
struct ShiftHandoverReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("shift-handover", "log")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the handover log route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerShiftHandoverReadRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarSignatureIsPinned() throws {
        // One parameter: the handle comes from req.db, parsedTimestampDate is a
        // module-level helper and the entry type already lives in APIContentDTOs.
        #expect(try routeFileText().contains(
            "func registerShiftHandoverReadRoutes(on apiV1: MachineGatedRoutes) {"
        ))
    }

    @Test("The route file introduces no configuration lookup and no global state")
    func routeFileHasNoOwnConfigurationOrState() throws {
        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "storageDirectory", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Ordering lives only in Swift

    @Test("Neither query orders in SQL; the Swift comparator is the whole contract")
    func orderingIsSwiftOnly() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Two queries, neither ordered.
        let rawQueries = code.components(separatedBy: "sql.raw(").count - 1
        #expect(rawQueries == 2, "Expected exactly two queries, found \(rawQueries)")
        #expect(parseOrderByClauses(inSource: code).isEmpty,
                "The handover log gained an SQL ordering, which cannot order across two result sets")

        #expect(countDescendingDateComparators(inSource: code) == 1)
        for pinned in [
            "logEntries.sort { first, second in",
            "let firstDate = parsedTimestampDate(first.eventTimestamp) ?? Date.distantPast",
            "let secondDate = parsedTimestampDate(second.eventTimestamp) ?? Date.distantPast",
            "return firstDate > secondDate"
        ] {
            #expect(code.contains(pinned), "Comparator line changed or missing: \(pinned)")
        }

        // Unparseable timestamps sort to the far past instead of taking the request
        // down — the merged stream is the one place a single bad row could poison.
        #expect(code.components(separatedBy: "?? Date.distantPast").count - 1 == 2)

        // Merge order: observations are appended before decision traces, and the sort
        // runs after both. A sort placed between them would order only half the stream.
        let observationAppend = try #require(code.range(of: #"entryType: "Observation Record""#)?.lowerBound)
        let decisionAppend = try #require(code.range(of: #"entryType: "Decision Trace""#)?.lowerBound)
        let sortIndex = try #require(code.range(of: "logEntries.sort {")?.lowerBound)
        #expect(observationAppend < decisionAppend)
        #expect(decisionAppend < sortIndex, "The stream is sorted before the decision traces are merged in")
    }

    // MARK: The lane fallback

    @Test("The lane fallback chain is intact and its decode stays non-optional")
    func laneFallbackIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A trace with no lane of its own borrows the lane of the asset it targets, and
        // failing that reads "unassigned". Losing the COALESCE would make the column
        // nullable and break the non-optional decode below.
        #expect(code.contains(
            #"COALESCE(decision_traces.lane_key, asset_records.lane_key, 'unassigned') AS lane_key"#
        ))
        #expect(code.contains(#"try row.decode(column: "lane_key", as: String.self)"#))

        // LEFT JOIN, not INNER: a trace whose target asset is absent must still appear.
        #expect(code.contains("LEFT JOIN asset_records"))
        #expect(code.contains("ON asset_records.id = decision_traces.target_asset_record_id"))
    }

    // MARK: Message shapes and nullability

    @Test("The three message shapes and their branch order are unchanged")
    func messageShapesAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        let assetBound = try #require(code.range(of: #"message = "Observation decision trace: \(decisionType) — asset \(targetAssetRecordID.uuidString)""#)?.lowerBound)
        let standardBound = try #require(code.range(of: #"message = "Decision trace: \(decisionType) — \(standardKey) — \(expectedWindowStart) to \(expectedWindowEnd)""#)?.lowerBound)
        let unresolved = try #require(code.range(of: #"message = "Decision trace: \(decisionType) — unresolved target""#)?.lowerBound)

        // Branch order decides which shape wins when a trace has both a target asset and
        // a standard. Reordering these compiles and changes what the operator reads.
        #expect(assetBound < standardBound)
        #expect(standardBound < unresolved)

        #expect(code.contains(#"entryType: "Observation Record""#))
        #expect(code.contains(#"message: "Observation record: \(fileName)""#))
    }

    @Test("Every optional column is decoded optionally")
    func nullableDecodesAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // These four are legitimately absent on real rows. A non-optional decode would
        // compile and throw at runtime against exactly the rows this route exists to show.
        for optionalDecode in [
            #"try row.decode(column: "standard_key", as: String?.self)"#,
            #"try row.decode(column: "expected_window_start", as: String?.self)"#,
            #"try row.decode(column: "expected_window_end", as: String?.self)"#,
            #"try row.decode(column: "target_asset_record_id", as: UUID?.self)"#
        ] {
            #expect(code.contains(optionalDecode), "Nullable decode changed or missing: \(optionalDecode)")
        }

        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }

        #expect(code.contains("guard let sql = req.db as? SQLDatabase else {"))
        #expect(code.contains("return Response(status: .internalServerError)"))
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains("try response.content.encode(logEntries)"))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "LEFT JOIN asset_records", with: "INNER JOIN asset_records")

        #expect(mutated.contains("LEFT JOIN asset_records") == false)
        #expect(try routeFileText().contains("LEFT JOIN asset_records"))
    }
}
