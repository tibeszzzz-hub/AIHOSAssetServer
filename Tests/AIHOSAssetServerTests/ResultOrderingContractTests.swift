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

/// The single clause in `OperationalStandardReadRoutes.swift`.
private let expectedStandardsReadOrderByClauses: [String] = [
    "ORDER BY created_at ASC"                               // GET /api/v1/standards
]

/// The single clause in `ObservationDecisionTraceReadRoutes.swift`.
private let expectedDecisionTraceOrderByClauses: [String] = [
    #"ORDER BY "created_at" ASC"#                           // GET /api/v1/assets/:id/decision-traces
]

/// The single clause in `ObservationRecordReadRoutes.swift`.
///
/// Ascending here, then re-sorted descending in Swift — see the comparator test below.
private let expectedRecordsOrderByClauses: [String] = [
    #"ORDER BY asset_records."captureTimestamp" ASC"#       // GET /api/v1/records
]

/// The single clause in `MechanicalGapReadRoutes.swift`.
private let expectedGapsOrderByClauses: [String] = [
    #"ORDER BY "standardKey" ASC"#                          // GET /api/v1/gaps/mechanical
]

/// The single clause in `OperationalPulseReadRoutes.swift`.
private let expectedPulseOrderByClauses: [String] = [
    #"ORDER BY "standardKey" ASC"#                          // GET /api/v1/state/pulse
]

/// The single clause in `VoiceTranscriptionRoutes.swift`.
private let expectedTranscriptionOrderByClauses: [String] = [
    #"ORDER BY "fileName" ASC"#                             // POST /api/v1/assets/:id/transcribe-audio
]

/// What remains in `AIHOSAssetServer.swift`: nothing.
///
/// F-G10 moved the last route that ordered anything, so the composition root now
/// declares no ordering at all. Asserted rather than assumed — a clause reappearing
/// there would mean a route was registered in main() instead of a route file.
private let expectedOrderByClauses: [String] = []

@Suite("Result ordering contracts")
struct ResultOrderingContractTests {

    @Test("The SQL ordering clauses are exactly the ten pinned ones, in order")
    func orderByClausesAreExact() throws {
        let clauses = parseOrderByClauses(inSource: try serverSourceText())

        #expect(clauses.isEmpty, "Found \(clauses.count) ORDER BY clauses: \(clauses)")
        #expect(clauses == expectedOrderByClauses)

        for (file, expected) in [
            ("TimestampDiagnostics.swift", expectedDiagnosticOrderByClauses),
            ("OperationalStandardHelpers.swift", expectedStandardOrderByClauses),
            ("PayloadTextReadRoutes.swift", expectedPayloadTextOrderByClauses),
            ("StandardStatusTimelineReadRoutes.swift", expectedStatusTimelineOrderByClauses),
            ("OperationalStandardReadRoutes.swift", expectedStandardsReadOrderByClauses),
            ("ObservationDecisionTraceReadRoutes.swift", expectedDecisionTraceOrderByClauses),
            ("ObservationRecordReadRoutes.swift", expectedRecordsOrderByClauses),
            ("MechanicalGapReadRoutes.swift", expectedGapsOrderByClauses),
            ("OperationalPulseReadRoutes.swift", expectedPulseOrderByClauses),
            ("VoiceTranscriptionRoutes.swift", expectedTranscriptionOrderByClauses)
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
                + expectedStandardsReadOrderByClauses
                + expectedDecisionTraceOrderByClauses
                + expectedRecordsOrderByClauses
                + expectedGapsOrderByClauses
                + expectedPulseOrderByClauses
                + expectedTranscriptionOrderByClauses
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
        // Counted across the library since F-F6 moved the records route out. The demand
        // is unchanged: exactly two, no more and no fewer.
        //
        // GET /api/v1/records and GET /api/v1/shift-handover/log both present newest
        // first, despite their SQL reading oldest first (or, for the handover log,
        // being unordered in SQL entirely).
        #expect(countDescendingDateComparators(inSource: try serverModuleSourceText()) == 2)

        // One each, and specifically in these two places. The library-wide count above
        // would still pass if both comparators ended up in the same file, which would
        // mean one route had silently lost its ordering.
        let recordsSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "ObservationRecordReadRoutes.swift" }?.text,
            "ObservationRecordReadRoutes.swift is missing from the library"
        )
        #expect(countDescendingDateComparators(inSource: recordsSource) == 1)

        let handoverSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "ShiftHandoverReadRoutes.swift" }?.text,
            "ShiftHandoverReadRoutes.swift is missing from the library"
        )
        #expect(countDescendingDateComparators(inSource: handoverSource) == 1)

        // Since F-F7 both comparators live in route files, so the composition root has
        // none left. Asserted rather than assumed: a comparator reappearing in main()
        // would mean a route was registered there again.
        #expect(countDescendingDateComparators(inSource: try serverSourceText()) == 0)
    }

    @Test("The shift-handover query is the one read with no SQL ordering at all")
    func handoverLogHasNoSQLOrdering() throws {
        let clauses = parseOrderByClauses(inSource: try serverModuleSourceText())

        // Its ordering exists only in the Swift comparator. Pinned because moving that
        // route without the comparator would silently return database-arbitrary order.
        #expect(clauses.contains { $0.contains("eventTimestamp") } == false)
        #expect(countDescendingDateComparators(inSource: try serverModuleSourceText()) == 2)
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
