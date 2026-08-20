import Testing
import Vapor
import SQLKit
import Foundation
@testable import AIHOSAssetServer

// MARK: - AC-4: volume and truthfulness of the timestamp read-expectation diagnostic
//
// Atom SERVER-MOD-A1a (WFOS-20260817-PSKS-025 v1.1).
//
// WHAT THIS ATOM CHANGED AND WHY THESE TESTS EXIST
//   `asset_records."captureTimestamp"` is stored in the canonical AIHOS format —
//   10-digit Unix epoch seconds, UTC (WFOS-20260817-NBPS-001). Those 301 rows are
//   correct data. The gap and pulse calculations still read timestamps through an ISO
//   8601 prefix predicate, so the diagnostic that reports the mismatch used to emit
//   three log lines per matching row: 903 lines per route call, 1806 per gaps+pulse
//   pair. That volume was large enough to push real machine-auth denials out of the
//   platform's log budget, which is a security-visibility problem, not a tidiness one.
//
//   The diagnostic is now a bounded aggregate: one row, one log line, at most five
//   example record IDs, no timestamp values at all.
//
// WHAT IS DELIBERATELY NOT TESTED HERE
//   The SQL is not executed — A1a contacts no database. The query's shape is pinned at
//   source level in `TimestampDiagnosticQueryTests`; the decoding and log-emission
//   behaviour is exercised for real below, against a stub row and a capturing log
//   handler. Together those cover every step between the database and the log line.

// MARK: - Test doubles

/// Minimal `SQLRow` stand-in so the aggregate decoder can be exercised without a
/// database. `SQLRow` requires `Sendable`, hence the `any Sendable` value storage.
private struct StubSQLRow: SQLRow {
    enum StubError: Error {
        case missingColumn(String)
        case typeMismatch(String)
    }

    let values: [String: any Sendable]

    var allColumns: [String] { Array(values.keys) }

    func contains(column: String) -> Bool { values[column] != nil }

    func decodeNil(column: String) throws -> Bool { values[column] == nil }

    func decode<D: Decodable>(column: String, as type: D.Type) throws -> D {
        guard let value = values[column] else { throw StubError.missingColumn(column) }
        guard let typed = value as? D else { throw StubError.typeMismatch(column) }
        return typed
    }
}

/// Collects every emitted log entry so volume can be asserted exactly rather than
/// estimated. Locked because `LogHandler` must be `Sendable`.
private final class LogCapture: @unchecked Sendable {
    struct Entry {
        let level: Logger.Level
        let message: String
        let metadata: Logger.Metadata
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ entry: Entry) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }
}

private struct CapturingLogHandler: LogHandler {
    let capture: LogCapture
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        capture.append(.init(level: level, message: message.description, metadata: metadata ?? [:]))
    }
}

private func capturingLogger() -> (Logger, LogCapture) {
    let capture = LogCapture()
    let logger = Logger(label: "a1a-test") { _ in CapturingLogHandler(capture: capture) }
    return (logger, capture)
}

/// The aggregate row the production query is shaped to return.
private func diagnosticRow(totalCount: Int, exampleIDs: [String]) -> StubSQLRow {
    StubSQLRow(values: [
        "totalCount": totalCount,
        "exampleRecordIDs": exampleIDs.joined(separator: ",")
    ])
}

/// The five example IDs the measured production state would yield.
private let measuredExampleIDs = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
    "33333333-3333-3333-3333-333333333333",
    "44444444-4444-4444-4444-444444444444",
    "55555555-5555-5555-5555-555555555555"
]

// MARK: - Decoding the aggregate

@Suite("Timestamp diagnostic decoding")
struct TimestampDiagnosticDecodingTests {

    @Test("The measured production state decodes to an exact count and five examples")
    func measuredStateDecodes() throws {
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 301, exampleIDs: measuredExampleIDs)]
        )

        #expect(diagnostic?.totalCount == 301)
        #expect(diagnostic?.exampleRecordIDs == measuredExampleIDs)
        #expect((diagnostic?.exampleRecordIDs.count ?? .max) <= timestampDiagnosticExampleLimit)
    }

    @Test("An empty example list decodes to no examples rather than one empty string")
    func emptyExampleListDecodes() throws {
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 0, exampleIDs: [])]
        )

        #expect(diagnostic?.totalCount == 0)
        #expect(diagnostic?.exampleRecordIDs.isEmpty == true)
    }

    @Test("Negative control: no row at all decodes to nil, never to a clean zero")
    func missingRowDecodesToNil() throws {
        // A broken or empty measurement must be distinguishable from a healthy one.
        #expect(try timestampReadExpectationDiagnostic(from: []) == nil)
    }

    @Test("Negative control: a row missing the aggregate columns throws")
    func malformedRowThrows() {
        #expect(throws: (any Error).self) {
            _ = try timestampReadExpectationDiagnostic(from: [StubSQLRow(values: ["somethingElse": 1])])
        }
    }

    @Test("The diagnostic type carries no timestamp field at all")
    func diagnosticCarriesNoTimestamp() throws {
        let diagnostic = try #require(try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 301, exampleIDs: measuredExampleIDs)]
        ))

        // Structural, not stylistic: there is no member that could leak a stored
        // timestamp into a log line even by accident.
        let mirror = Mirror(reflecting: diagnostic)
        let memberNames = mirror.children.compactMap(\.label).sorted()

        #expect(memberNames == ["exampleRecordIDs", "totalCount"])
    }
}

// MARK: - Log volume

@Suite("Timestamp diagnostic log volume")
struct TimestampDiagnosticVolumeTests {

    @Test("At the measured 301 rows a gaps+pulse pair costs two log lines, not 1806")
    func gapsAndPulsePairCostsTwoLines() throws {
        let (logger, capture) = capturingLogger()
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 301, exampleIDs: measuredExampleIDs)]
        )

        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "gaps/mechanical", logger: logger)
        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "state/pulse", logger: logger)

        // The previous per-row form emitted 3 x 301 = 903 lines per route, 1806 per pair.
        #expect(capture.entries.count == 2)
        #expect(capture.entries.map { $0.metadata["calculation"]?.description } == ["gaps/mechanical", "state/pulse"])
    }

    @Test("Cost is O(1): ten times the rows still costs one line per route")
    func costDoesNotGrowWithRowCount() throws {
        let (logger, capture) = capturingLogger()

        for totalCount in [1, 301, 3_010, 1_000_000] {
            let diagnostic = try timestampReadExpectationDiagnostic(
                from: [diagnosticRow(totalCount: totalCount, exampleIDs: measuredExampleIDs)]
            )
            logTimestampReadExpectationDiagnostic(diagnostic, calculation: "gaps/mechanical", logger: logger)
        }

        #expect(capture.entries.count == 4)
    }

    @Test("Positive control: the emitted line carries the exact count and the examples")
    func emittedLineCarriesCountAndExamples() throws {
        let (logger, capture) = capturingLogger()
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 301, exampleIDs: measuredExampleIDs)]
        )

        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "gaps/mechanical", logger: logger)

        let entry = try #require(capture.entries.first)

        #expect(entry.level == .warning)
        #expect(entry.metadata["totalCount"]?.description == "301")
        #expect(entry.metadata["calculation"]?.description == "gaps/mechanical")

        let examples = try #require(entry.metadata["exampleRecordIDs"]?.description)
        #expect(examples.split(separator: ",").count == 5)
        #expect(examples.split(separator: ",").count <= timestampDiagnosticExampleLimit)
    }

    @Test("Nothing is logged when no row matches")
    func zeroCountLogsNothing() throws {
        let (logger, capture) = capturingLogger()
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 0, exampleIDs: [])]
        )

        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "gaps/mechanical", logger: logger)
        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "state/pulse", logger: logger)

        #expect(capture.entries.isEmpty)
    }

    @Test("A missing measurement logs nothing rather than a misleading zero")
    func nilDiagnosticLogsNothing() {
        let (logger, capture) = capturingLogger()

        logTimestampReadExpectationDiagnostic(nil, calculation: "gaps/mechanical", logger: logger)

        #expect(capture.entries.isEmpty)
    }
}

// MARK: - Truthfulness and data hygiene

@Suite("Timestamp diagnostic truthfulness")
struct TimestampDiagnosticTruthfulnessTests {

    @Test("No stored timestamp value ever reaches a log line")
    func noTimestampIsLogged() throws {
        let (logger, capture) = capturingLogger()
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 301, exampleIDs: measuredExampleIDs)]
        )

        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "gaps/mechanical", logger: logger)

        let entry = try #require(capture.entries.first)
        let rendered = entry.message + entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")

        // No 10-digit epoch value and no ISO instant may appear anywhere in the line.
        // `totalCount` is a count, not a timestamp, and is bounded well below 10 digits
        // in every realistic state; the assertion below targets epoch-shaped tokens.
        let epochShaped = rendered.range(of: #"(?<![0-9])1[0-9]{9}(?![0-9])"#, options: .regularExpression)
        #expect(epochShaped == nil, "An epoch-shaped value appears in the log line: \(rendered)")

        let isoShaped = rendered.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:"#, options: .regularExpression)
        #expect(isoShaped == nil, "An ISO timestamp appears in the log line: \(rendered)")
    }

    @Test("Canonical epoch rows are never called legacy or invalid")
    func canonicalRowsAreDescribedNeutrally() throws {
        let (logger, capture) = capturingLogger()
        let diagnostic = try timestampReadExpectationDiagnostic(
            from: [diagnosticRow(totalCount: 301, exampleIDs: measuredExampleIDs)]
        )

        logTimestampReadExpectationDiagnostic(diagnostic, calculation: "state/pulse", logger: logger)

        let entry = try #require(capture.entries.first)
        let rendered = (entry.message + entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")).lowercased()

        // NBPS-001: the stored format is canonical. Describing it as legacy, invalid,
        // bad or corrupt would be untrue and would misdirect whoever reads the log.
        for forbidden in ["legacy", "invalid", "malformed", "corrupt", "bad ", "broken"] {
            #expect(rendered.contains(forbidden) == false, "Log line calls canonical data '\(forbidden)': \(rendered)")
        }

        // And it must still say something useful about what is actually mismatched.
        #expect(rendered.contains("mismatch"))
        #expect(rendered.contains("epoch"))
    }

    @Test("The server source no longer describes captureTimestamp rows as legacy")
    func serverSourceUsesNeutralWording() throws {
        let source = try serverSourceText()

        #expect(source.contains("Legacy timestamp detected") == false)
        #expect(source.contains("legacyTimestampSkipLogQuery") == false)
        #expect(source.contains("skipping for Gap calculation") == false)
        #expect(source.contains("skipping for Pulse calculation") == false)
    }

    @Test("Both call sites use the logger and emit no per-record print")
    func callSitesUseLoggerNotPrint() throws {
        // Whole library since F-F8 moved the gaps calculation into its own file; the
        // two call sites now live in two files. The count demanded is unchanged.
        let lines = trimmedSourceLines(try serverModuleSourceText())

        let callSites = lines.filter { $0.hasPrefix("logTimestampReadExpectationDiagnostic(") }
        let querySites = lines.filter { $0.contains("timestampReadExpectationDiagnosticQuery()") && $0.contains("sql.raw") }

        // Positive control: exactly the two intended call sites, no more and no fewer.
        #expect(callSites.count == 2)
        #expect(querySites.count == 2)

        // The removed loop variables must not survive anywhere in the source.
        #expect(lines.contains { $0.contains("skippedTimestampRows") } == false)
        #expect(lines.contains { $0.contains("skippedTimestamp") } == false)
        #expect(lines.contains { $0.contains("skippedID") } == false)
    }
}
