import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F6: the observation records read route
//
// Order WFOS-20260820-PSKS-001. `GET /api/v1/records` moved from main() into
// Sources/AIHOSAssetServer/ObservationRecordReadRoutes.swift.
//
// WHY THESE TESTS
//   This is the first extracted route that needed a value threaded through from
//   main(), and the first with behaviour that looks redundant and is not:
//
//   - It sorts ascending in SQL and then descending in Swift. Deleting either step
//     compiles and changes what the client sees.
//   - It drops records whose payload file is missing from disk. That is a filter, not
//     a diagnostic: turning the `continue` into a warning would start serving records
//     pointing at files that do not exist.
//   - It groups multiple files under one observation, so the same id must not appear
//     twice in the response.
//
//   All three are pinned here, together with storageDirectory being a parameter rather
//   than a second lookup.

private let routeFileName = "ObservationRecordReadRoutes.swift"

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

@Suite("F-F6 observation records read route extraction")
struct ObservationRecordReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("records")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the records read route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerObservationRecordReadRoutes(on: apiV1, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    // MARK: The threaded dependency

    @Test("storageDirectory is a parameter, not a second lookup")
    func storageDirectoryIsThreadedIn() throws {
        #expect(try routeFileText().contains(
            "func registerObservationRecordReadRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {"
        ))

        let code = try routeFileCodeLines().joined(separator: "\n")

        // main() resolves and validates STORAGE_PATH once, fail-closed. Resolving it
        // again here could disagree with that, and this route uses the value to decide
        // whether a record is returned at all.
        for lookup in ["Environment.get", "STORAGE_PATH", "resolvedStorageDirectory", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        // The same construction as before the move.
        #expect(code.contains(#"let filePath = storageDirectory + "/" + fileName"#))
    }

    @Test("The route file introduces no global state")
    func routeFileHasNoFileScopeState() throws {
        let codeLines = try routeFileCodeLines()

        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: The two-step ordering

    @Test("The SQL sorts ascending and the Swift comparator re-sorts descending")
    func twoStepOrderingSurvived() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"ORDER BY asset_records."captureTimestamp" ASC"#))
        #expect(countDescendingDateComparators(inSource: code) == 1)

        for pinned in [
            "records.sort { first, second in",
            "let firstDate = parsedTimestampDate(first.captureTimestamp) ?? Date.distantPast",
            "let secondDate = parsedTimestampDate(second.captureTimestamp) ?? Date.distantPast",
            "return firstDate > secondDate"
        ] {
            #expect(code.contains(pinned), "Comparator line changed or missing: \(pinned)")
        }

        // Unparseable timestamps sort to the far past rather than crashing or being
        // dropped. Pinned because `?? Date.distantPast` reads like defensive noise and
        // is the only thing keeping a malformed row from taking the request down.
        #expect(code.components(separatedBy: "?? Date.distantPast").count - 1 == 2)
    }

    // MARK: The file integrity filter

    @Test("Records whose payload file is missing are skipped, counted and logged")
    func fileIntegrityFilterSurvived() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "guard FileManager.default.fileExists(atPath: filePath) else {",
            "missingFileCount += 1",
            #"print("Observation retrieval skipped missing payload file: \(fileName)")"#,
            "continue"
        ] {
            #expect(code.contains(pinned), "File integrity filter element changed or missing: \(pinned)")
        }

        // `continue` is what makes this a filter rather than a warning. If the guard
        // body ever stops skipping, records pointing at missing files start being
        // served with a broken reference.
        let guardIndex = try #require(code.range(of: "guard FileManager.default.fileExists")?.lowerBound)
        let continueIndex = try #require(code.range(of: "continue")?.lowerBound)
        #expect(guardIndex < continueIndex)

        #expect(code.contains(#"print("Observation retrieval file integrity filter PASS")"#))
        #expect(code.contains(#"print("Observation records skipped missing files: \(missingFileCount)")"#))
        #expect(code.contains(#"print("Observation records returned: \(records.count)")"#))
    }

    // MARK: Grouping and response

    @Test("Files are grouped under one observation, in first-seen order")
    func groupingContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "var groupOrder: [String] = []",
            "var groupsByID: [String: GroupedObservationResponse] = [:]",
            "if let existing = groupsByID[id] {",
            "files: existing.files + [fileName]",
            "groupOrder.append(id)",
            "files: [fileName]",
            "var records: [GroupedObservationResponse] = groupOrder.compactMap { groupsByID[$0] }"
        ] {
            #expect(code.contains(pinned), "Grouping contract line changed or missing: \(pinned)")
        }

        // The join returns one row per file, so without grouping an observation with
        // three files would appear three times.
        #expect(code.contains("INNER JOIN asset_files"))
        #expect(code.contains(#"ON asset_files."assetRecordID" = asset_records.id"#))
    }

    @Test("The projection, display timestamp and status code are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "let sql = req.db as! SQLDatabase",
            "asset_records.id,",
            #"asset_records."captureTimestamp","#,
            #"asset_records."sourceTag","#,
            "asset_records.lane_key,",
            #"asset_files."fileName""#,
            "FROM asset_records",
            "displayTimestamp: humanReadableTimestamp(captureTimestamp)",
            "let response = Response(status: .ok)",
            "try response.content.encode(records)"
        ] {
            #expect(code.contains(pinned), "Response contract line changed or missing: \(pinned)")
        }

        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "return firstDate > secondDate",
                                  with: "return firstDate < secondDate")

        #expect(countDescendingDateComparators(inSource: mutated) == 0)
        #expect(countDescendingDateComparators(inSource: try routeFileText()) == 1)
    }
}
