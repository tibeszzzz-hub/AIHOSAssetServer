import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - AC-6: existing ordering contracts
//
// Atom SERVER-MOD-A0 (WFOS-20260817-PSKS-020).
//
// WHAT IS PINNED HERE AND WHY IT IS SOURCE-LEVEL
//   The order a client receives rows in is part of the API contract, and it is decided
//   in two places that no type checker inspects: raw `ORDER BY` strings inside handler
//   SQL, and Swift comparators that re-sort the already-ordered result afterwards. Both
//   live inside `main()` and cannot be invoked from a test without changing production
//   code, which A0 forbids. They are therefore pinned as the exact source baseline.
//
// WHAT IS DELIBERATELY NOT PINNED
//   Status codes, error bodies and end-to-end row ordering need a database fixture or a
//   handler that can be called in isolation. AC-6 explicitly forbids extracting
//   production code just to make it testable in A0, so those stay open and are reported
//   as remaining gaps in the completion report rather than approximated here.
//
// The comparator-direction assertion below is the one that matters most: two read
// routes issue an ASCENDING SQL sort and then re-sort DESCENDING in Swift. Anyone
// tidying up "redundant" sorting would reverse two client-visible lists.

/// Every `ORDER BY` clause in the production library, in source order, normalised to
/// single spaces. Ten clauses in total.
///
/// F-E3 moved the diagnostic into its own file, so the ten are now pinned per file
/// instead of as one flat list. That is deliberately stricter, not looser: a flat
/// list read across the whole library would have made the expected order depend on
/// how the files happen to sort, which is not a contract about anything. Each file's
/// clauses are still pinned exactly, in order, and the total is still exactly ten.

/// The single clause in `TimestampDiagnostics.swift`.
private let expectedDiagnosticOrderByClauses: [String] = [
    "ORDER BY id"                                           // timestampReadExpectationDiagnosticQuery (A1a)
]

/// The single clause in `OperationalStandardHelpers.swift`.
private let expectedStandardOrderByClauses: [String] = [
    "ORDER BY changed_at DESC"                              // isStandardActive — latest status wins
]

/// The single clause in `PayloadTextReadRoutes.swift`.
private let expectedPayloadTextOrderByClauses: [String] = [
    "ORDER BY created_at ASC"                               // GET /api/v1/assets/:id/payload-text
]

/// The single clause in `StandardStatusTimelineReadRoutes.swift`.
private let expectedStatusTimelineOrderByClauses: [String] = [
    "ORDER BY changed_at ASC"                               // GET /api/v1/standards/:id/status-updates
]

/// The six clauses remaining in `AIHOSAssetServer.swift`, in source order.
private let expectedOrderByClauses: [String] = [
    #"ORDER BY asset_records."captureTimestamp" ASC"#,      // GET /api/v1/records
    "ORDER BY created_at ASC",                              // GET /api/v1/standards
    #"ORDER BY "created_at" ASC"#,                          // GET /api/v1/assets/:id/decision-traces
    #"ORDER BY "fileName" ASC"#,                            // POST /api/v1/assets/:id/transcribe-audio
    #"ORDER BY "standardKey" ASC"#,                         // GET /api/v1/gaps/mechanical
    #"ORDER BY "standardKey" ASC"#                          // GET /api/v1/state/pulse
]

@Suite("Result ordering contracts")
struct ResultOrderingContractTests {

    @Test("The SQL ordering clauses are exactly the ten pinned ones, in order")
    func orderByClausesAreExact() throws {
        let clauses = parseOrderByClauses(inSource: try serverSourceText())

        #expect(clauses.count == 6, "Found \(clauses.count) ORDER BY clauses: \(clauses)")
        #expect(clauses == expectedOrderByClauses)

        for (file, expected) in [
            ("TimestampDiagnostics.swift", expectedDiagnosticOrderByClauses),
            ("OperationalStandardHelpers.swift", expectedStandardOrderByClauses),
            ("PayloadTextReadRoutes.swift", expectedPayloadTextOrderByClauses),
            ("StandardStatusTimelineReadRoutes.swift", expectedStatusTimelineOrderByClauses)
        ] {
            let source = try #require(
                try serverModuleSourceTexts().first { $0.name == file }?.text,
                "\(file) is missing from the library"
            )
            #expect(parseOrderByClauses(inSource: source) == expected, "Ordering clauses changed in \(file)")
        }
    }

    @Test("The library as a whole still has exactly ten ordering clauses")
    func libraryOrderByTotalIsUnchanged() throws {
        // Catches a clause moved into any other file rather than lost: the per-file
        // assertions above would both still pass if one reappeared somewhere new.
        let clauses = parseOrderByClauses(inSource: try serverModuleSourceText())

        #expect(clauses.count == 10, "Found \(clauses.count) ORDER BY clauses in the library: \(clauses)")
        #expect(clauses.sorted() == (
            expectedOrderByClauses
                + expectedDiagnosticOrderByClauses
                + expectedStandardOrderByClauses
                + expectedPayloadTextOrderByClauses
                + expectedStatusTimelineOrderByClauses
        ).sorted())
    }

    @Test("Exactly one ordering clause is descending, and it is the status lookup")
    func onlyStatusLookupIsDescending() throws {
        let clauses = parseOrderByClauses(inSource: try serverModuleSourceText())
        let descending = clauses.filter { $0.uppercased().hasSuffix("DESC") }

        // `isStandardActive` takes the most recent status at or before the evaluation
        // timestamp, so it must read newest-first. Every other query reads oldest-first.
        #expect(descending == ["ORDER BY changed_at DESC"])
    }

    @Test("Exactly two routes re-sort descending in Swift after an ascending SQL sort")
    func swiftComparatorsAreExact() throws {
        let source = try serverSourceText()

        // GET /api/v1/records and GET /api/v1/shift-handover/log both present newest
        // first, despite their SQL reading oldest first (or, for the handover log,
        // being unordered in SQL entirely).
        #expect(countDescendingDateComparators(inSource: source) == 2)
    }

    @Test("The shift-handover query is the one read with no SQL ordering at all")
    func handoverLogHasNoSQLOrdering() throws {
        let source = try serverSourceText()
        let clauses = parseOrderByClauses(inSource: source)

        // Its ordering exists only in the Swift comparator. Pinned because moving that
        // route without the comparator would silently return database-arbitrary order.
        #expect(clauses.contains { $0.contains("eventTimestamp") } == false)
        #expect(countDescendingDateComparators(inSource: source) == 2)
    }

    // MARK: Negative controls

    @Test("Positive control: the clause parser reads a known block")
    func clauseParserReadsClauses() {
        let fixture = """
                SELECT id
                FROM asset_records
                ORDER BY created_at ASC
                SELECT id
                ORDER BY changed_at DESC
        """

        #expect(parseOrderByClauses(inSource: fixture) == ["ORDER BY created_at ASC", "ORDER BY changed_at DESC"])
    }

    @Test("Negative control: a flipped sort direction is detected")
    func flippedDirectionIsDetected() {
        let fixture = "ORDER BY created_at ASC"
        let mutated = "ORDER BY created_at DESC"

        #expect(parseOrderByClauses(inSource: fixture) != parseOrderByClauses(inSource: mutated))
    }

    @Test("Negative control: a removed ordering clause is detected")
    func removedClauseIsDetected() {
        let fixture = """
                ORDER BY created_at ASC
                ORDER BY changed_at DESC
        """

        let mutated = fixture.replacingOccurrences(of: "        ORDER BY changed_at DESC", with: "")

        #expect(parseOrderByClauses(inSource: mutated) == ["ORDER BY created_at ASC"])
    }

    @Test("Negative control: a dropped Swift comparator is detected")
    func droppedComparatorIsDetected() {
        let fixture = """
                return firstDate > secondDate
                return firstDate > secondDate
        """

        #expect(countDescendingDateComparators(inSource: fixture) == 2)
        #expect(countDescendingDateComparators(inSource: "return firstDate > secondDate") == 1)
        #expect(countDescendingDateComparators(inSource: "return firstDate < secondDate") == 0)
    }
}
