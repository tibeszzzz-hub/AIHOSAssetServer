import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - SERVER-MOD-A1b: canonical epoch, operations time zone, date-correct windows
//
// Order WFOS-20260818-PSKS-001. Fixes the defect proved in WFOS-20260817-KSPS-026:
// the gap and pulse calculations read captureTimestamp through an ISO 8601 predicate
// while every stored row is a canonical 10-digit Unix epoch, so observedCount was
// locked at 0, every active standard was reported as a gap, and pulse could never
// reach green by actually doing the work.
//
// The expected epoch values below are not derived from the implementation. They were
// computed independently from the IANA database before the code was written, so a
// wrong implementation cannot make them agree with it.

private let vienna = TimeZone(identifier: "Europe/Vienna")!
private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
private let utc = TimeZone(identifier: "UTC")!

// MARK: - AC-1 Canonical ingest contract

@Suite("AC-1 canonical capture timestamp contract")
struct CanonicalCaptureTimestampTests {

    @Test("Positive control: a 10-digit epoch in seconds is canonical")
    func canonicalValuesAccepted() {
        #expect(isCanonicalCaptureTimestamp("1786996800"))
        #expect(isCanonicalCaptureTimestamp("0000000000"))
        #expect(isCanonicalCaptureTimestamp("9999999999"))
    }

    @Test("A 13-digit millisecond value is refused, never divided")
    func millisecondsRefused() {
        // The failure mode this guards: silently treating ms as s would place every
        // such observation roughly 50 000 years in the future.
        #expect(isCanonicalCaptureTimestamp("1786996800000") == false)
    }

    @Test("Negative control: every non-canonical shape is refused")
    func nonCanonicalValuesRefused() {
        #expect(isCanonicalCaptureTimestamp("") == false)
        #expect(isCanonicalCaptureTimestamp("178699680") == false, "nine digits")
        #expect(isCanonicalCaptureTimestamp("17869968000") == false, "eleven digits")
        #expect(isCanonicalCaptureTimestamp("2026-08-17T22:00:00Z") == false)
        #expect(isCanonicalCaptureTimestamp("test-capture-timestamp") == false)
        #expect(isCanonicalCaptureTimestamp(" 1786996800") == false, "no trimming")
        #expect(isCanonicalCaptureTimestamp("1786996800 ") == false)
        #expect(isCanonicalCaptureTimestamp("178699680a") == false)
        #expect(isCanonicalCaptureTimestamp("-786996800") == false)
        #expect(isCanonicalCaptureTimestamp("1_786_996_800") == false)
    }

    @Test("Both ingest routes enforce the contract before any write")
    func ingestGuardsPrecedeAnyWrite() throws {
        // Whole library since F-H1 moved /audio into its own file. Both routes are
        // still scanned, and each is still checked against its OWN guard, file write
        // and transaction — the per-route scan below starts at that route's line.
        let lines = trimmedSourceLines(try serverModuleSourceText())

        #expect(lines.filter { $0.contains("isCanonicalCaptureTimestamp(metadata.captureTimestamp)") }.count == 2,
                "Expected one ingest guard in /sync and one in /audio")

        /// First line at or after `start` satisfying `predicate`.
        func firstIndex(from start: Int, where predicate: (String) -> Bool) -> Int? {
            lines.indices.dropFirst(start).first { predicate(lines[$0]) }
        }

        // Checked per handler rather than globally: the server also writes a file in
        // the /test/vision-ocr probe and opens a transaction in the standards status
        // route, and neither is an ingest path.
        let ingestRoutes = [
            #"apiV1.on(.POST, "sync""#,
            #"apiV1.on(.POST, "audio""#
        ]

        for route in ingestRoutes {
            let routeIndex = try #require(lines.firstIndex { $0.hasPrefix(route) }, "Ingest route not found: \(route)")

            let guardIndex = try #require(firstIndex(from: routeIndex) {
                $0.contains("isCanonicalCaptureTimestamp(metadata.captureTimestamp)")
            })
            let fileWriteIndex = try #require(firstIndex(from: routeIndex) {
                $0.hasPrefix("try Data(buffer: payload.")
            })
            let transactionIndex = try #require(firstIndex(from: routeIndex) {
                $0.hasPrefix("try await req.db.transaction")
            })

            // A refused upload must leave nothing behind: no file on disk, no row.
            #expect(guardIndex < fileWriteIndex, "\(route): guard runs after the file write")
            #expect(guardIndex < transactionIndex, "\(route): guard runs after the transaction opens")
        }
    }
}

// MARK: - AC-2 Operations time zone

@Suite("AC-2 operations time zone is mandatory and fail-closed")
struct OperationsTimeZoneTests {

    @Test("Positive control: a known IANA identifier resolves")
    func validIdentifiersResolve() throws {
        #expect(try resolvedOperationsTimeZone(fromConfiguredValue: "Europe/Vienna").identifier == "Europe/Vienna")
        #expect(try resolvedOperationsTimeZone(fromConfiguredValue: "Europe/Lisbon").identifier == "Europe/Lisbon")
        #expect(try resolvedOperationsTimeZone(fromConfiguredValue: "America/New_York").identifier == "America/New_York")

        // Surrounding whitespace in a deployment variable is stripped, as elsewhere.
        #expect(try resolvedOperationsTimeZone(fromConfiguredValue: "  Europe/Vienna \n").identifier == "Europe/Vienna")
    }

    @Test("A missing or empty value refuses startup rather than defaulting")
    func missingValueThrows() {
        #expect(throws: OperationsTimeZoneError.self) {
            _ = try resolvedOperationsTimeZone(fromConfiguredValue: nil)
        }
        #expect(throws: OperationsTimeZoneError.self) {
            _ = try resolvedOperationsTimeZone(fromConfiguredValue: "")
        }
        #expect(throws: OperationsTimeZoneError.self) {
            _ = try resolvedOperationsTimeZone(fromConfiguredValue: "   \n\t ")
        }
    }

    @Test("A non-IANA value refuses startup, including offset forms that carry no DST")
    func nonIANAValueThrows() {
        #expect(throws: OperationsTimeZoneError.self) {
            _ = try resolvedOperationsTimeZone(fromConfiguredValue: "Mars/Olympus")
        }
        #expect(throws: OperationsTimeZoneError.self) {
            _ = try resolvedOperationsTimeZone(fromConfiguredValue: "europe/vienna")
        }

        // "GMT+0200" is accepted by TimeZone(identifier:) but is a fixed offset with no
        // DST rules — it would silently compute wrong boundaries for half the year.
        #expect(throws: OperationsTimeZoneError.self) {
            _ = try resolvedOperationsTimeZone(fromConfiguredValue: "GMT+0200")
        }
    }

    @Test("The error says which variable is wrong without inventing a value")
    func errorIsActionable() {
        #expect(OperationsTimeZoneError.notConfigured.description.contains("OPERATIONS_TIMEZONE"))
        #expect(OperationsTimeZoneError.notAnIANATimeZone("Mars/Olympus").description.contains("Mars/Olympus"))
    }

    @Test("No zone name is hardcoded anywhere in the server source")
    func noHardcodedZone() throws {
        // Whole library since F-E1 moved the resolver into its own file: a zone name
        // hardcoded there would be just as wrong and must not escape this guard.
        let source = try serverModuleSourceText()

        // The interim zone is Europe/Vienna and the later target is Europe/Lisbon. A
        // move between them must be a configuration change only, which is only true if
        // neither name appears in the source.
        #expect(source.contains("Europe/Vienna") == false)
        #expect(source.contains("Europe/Lisbon") == false)
        #expect(source.contains(operationsTimeZoneEnvironmentKey))
    }

    @Test("Startup resolves the zone, and the interim status is documented in the source")
    func bootResolvesZone() throws {
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.contains { $0.hasPrefix("let operationsTimeZone = try resolvedOperationsTimeZone()") })

        // A future reader must be able to see that this is interim configuration and
        // that Organization will own it, without asking anyone. The documentation moved
        // with the resolver in F-E1; the startup call stays in the composition root.
        let source = try serverModuleSourceText()
        #expect(source.contains("INTERIM CONFIGURATION"))
        #expect(source.contains("Organization"))
    }

    @Test("The local operations date is the hotel's day, not the UTC day")
    func operationsDateUsesTheOperationsZone() {
        // 2026-08-18 00:30 in Vienna is still 2026-08-17 22:30 in UTC.
        let justAfterLocalMidnight = Date(timeIntervalSince1970: 1_787_005_800)

        #expect(operationsDateString(for: justAfterLocalMidnight, in: vienna) == "2026-08-18")
        #expect(operationsDateString(for: justAfterLocalMidnight, in: utc) == "2026-08-17")
        #expect(isValidISO8601DateString(operationsDateString(for: justAfterLocalMidnight, in: vienna)))
    }
}

// MARK: - AC-3 One shared window helper

@Suite("AC-3 window bounds")
struct ObservationWindowBoundsTests {

    @Test("Known anchor: 22:00–23:00 on 2026-08-17 in Vienna")
    func knownAnchorVienna() throws {
        let bounds = try #require(observationWindowBounds(
            localDate: "2026-08-17", startHour: 22, endHour: 23, timeZone: vienna
        ))

        // Independently computed from the IANA database: Vienna is UTC+2 in August.
        #expect(bounds.startEpoch == "1786996800")
        #expect(bounds.endEpoch == "1787000400")
    }

    @Test("The same window in another zone resolves to different instants")
    func zoneChangesTheInstants() throws {
        let viennaBounds = try #require(observationWindowBounds(
            localDate: "2026-08-17", startHour: 22, endHour: 23, timeZone: vienna
        ))
        let lisbonBounds = try #require(observationWindowBounds(
            localDate: "2026-08-17", startHour: 22, endHour: 23, timeZone: lisbon
        ))

        // This is the assertion that proves the zone is actually used rather than
        // ignored: Lisbon's 22:00 is Vienna's 23:00.
        #expect(lisbonBounds.startEpoch == "1787000400")
        #expect(lisbonBounds.startEpoch == viennaBounds.endEpoch)
        #expect(lisbonBounds != viennaBounds)
    }

    @Test("Every bound is exactly ten digits, which is what makes text ordering safe")
    func boundsAreFixedWidth() throws {
        for date in ["2026-01-15", "2026-08-17", "2026-10-25"] {
            let bounds = try #require(observationWindowBounds(
                localDate: date, startHour: 0, endHour: 24, timeZone: vienna
            ))
            #expect(bounds.startEpoch.count == 10)
            #expect(bounds.endEpoch.count == 10)
            #expect(isCanonicalCaptureTimestamp(bounds.startEpoch))
            #expect(isCanonicalCaptureTimestamp(bounds.endEpoch))
        }
    }

    @Test("Lexicographic ordering equals numeric ordering at fixed width")
    func lexicographicEqualsNumeric() {
        // The whole reason the window comparison can be a plain text range instead of a
        // cast. Checked across a wide span rather than on a couple of hand-picked pairs.
        var epochs: [Int] = []
        var value = 1_000_000_000
        while value < 1_900_000_000 {
            epochs.append(value)
            value += 7_777_777
        }

        let asStrings = epochs.map { canonicalEpochString($0)! }

        #expect(asStrings.sorted() == epochs.sorted().map { canonicalEpochString($0)! })

        for (left, right) in zip(epochs, epochs.dropFirst()) {
            let leftText = canonicalEpochString(left)!
            let rightText = canonicalEpochString(right)!
            #expect((left < right) == (leftText < rightText))
        }
    }

    @Test("Daylight saving: a 25-hour local day resolves to 25 real hours")
    func fallBackDayIsLonger() throws {
        // Vienna leaves DST on 2026-10-25, so local 00:00 to local 12:00 is 13 hours.
        let bounds = try #require(observationWindowBounds(
            localDate: "2026-10-25", startHour: 0, endHour: 12, timeZone: vienna
        ))

        #expect(bounds.startEpoch == "1792879200")
        #expect(bounds.endEpoch == "1792926000")
        #expect(Int(bounds.endEpoch)! - Int(bounds.startEpoch)! == 13 * 3600)
    }

    @Test("Daylight saving: a 23-hour local day resolves to 23 real hours")
    func springForwardDayIsShorter() throws {
        // Vienna enters DST on 2026-03-29, so local 00:00 to local 12:00 is 11 hours.
        let bounds = try #require(observationWindowBounds(
            localDate: "2026-03-29", startHour: 0, endHour: 12, timeZone: vienna
        ))

        #expect(bounds.startEpoch == "1774738800")
        #expect(bounds.endEpoch == "1774778400")
        #expect(Int(bounds.endEpoch)! - Int(bounds.startEpoch)! == 11 * 3600)
    }

    @Test("An ordinary day resolves to exactly the requested number of hours")
    func ordinaryDayIsExact() throws {
        let bounds = try #require(observationWindowBounds(
            localDate: "2026-01-15", startHour: 22, endHour: 23, timeZone: vienna
        ))

        #expect(bounds.startEpoch == "1768510800")
        #expect(bounds.endEpoch == "1768514400")
        #expect(Int(bounds.endEpoch)! - Int(bounds.startEpoch)! == 3600)
    }

    @Test("A window closing at midnight ends on the next local day")
    func midnightCloseIsNextDay() throws {
        let bounds = try #require(observationWindowBounds(
            localDate: "2026-08-17", startHour: 23, endHour: 24, timeZone: vienna
        ))

        #expect(bounds.startEpoch == "1787000400")
        #expect(Int(bounds.endEpoch)! - Int(bounds.startEpoch)! == 3600)
    }

    @Test("Negative control: an unusable request yields no bounds, never a half-built range")
    func unusableRequestsFailClosed() {
        #expect(observationWindowBounds(localDate: "17-08-2026", startHour: 22, endHour: 23, timeZone: vienna) == nil)
        #expect(observationWindowBounds(localDate: "", startHour: 22, endHour: 23, timeZone: vienna) == nil)
        #expect(observationWindowBounds(localDate: "2026-08-17", startHour: 23, endHour: 22, timeZone: vienna) == nil, "inverted")
        #expect(observationWindowBounds(localDate: "2026-08-17", startHour: 22, endHour: 22, timeZone: vienna) == nil, "empty window")
        #expect(observationWindowBounds(localDate: "2026-08-17", startHour: -1, endHour: 23, timeZone: vienna) == nil)
        #expect(observationWindowBounds(localDate: "2026-08-17", startHour: 22, endHour: 25, timeZone: vienna) == nil)
    }

    @Test("Negative control: an epoch outside the fixed width is refused")
    func fixedWidthIsEnforced() {
        #expect(canonicalEpochString(-1) == nil)
        #expect(canonicalEpochString(10_000_000_000) == nil)
        #expect(canonicalEpochString(0) == "0000000000")
        #expect(canonicalEpochString(1_786_996_800) == "1786996800")

        // Year 1900 is before the epoch and must not silently become a valid bound.
        #expect(observationWindowBounds(localDate: "1900-01-01", startHour: 0, endHour: 1, timeZone: vienna) == nil)
    }
}

// MARK: - AC-4 Correct observation counting

@Suite("AC-4 observation counting")
struct ObservationCountingTests {

    /// The night-photo standard on a known local date.
    private func nightPhotoWindow() throws -> ObservationWindowBounds {
        try #require(observationWindowBounds(
            localDate: "2026-08-17", startHour: 22, endHour: 23, timeZone: vienna
        ))
    }

    @Test("An observation inside the window is counted; the boundary is half-open")
    func inWindowAndBoundaries() throws {
        let bounds = try nightPhotoWindow()

        // Swift's String comparison is the same ordering Postgres applies to text, and
        // the SQL uses exactly these two operators — see `sqlUsesTheHalfOpenRange`.
        func counted(_ captureTimestamp: String) -> Bool {
            isCanonicalCaptureTimestamp(captureTimestamp)
                && captureTimestamp >= bounds.startEpoch
                && captureTimestamp < bounds.endEpoch
        }

        #expect(counted("1786998600"), "22:30 local, inside the window")
        #expect(counted(bounds.startEpoch), "22:00 local, start is inclusive")
        #expect(counted(bounds.endEpoch) == false, "23:00 local, end is exclusive")
        #expect(counted("1786996799") == false, "one second before the window")
        #expect(counted("1787000401") == false, "one second after the window")
    }

    @Test("The same clock time on a different date is not counted")
    func otherDatesAreExcluded() throws {
        let bounds = try nightPhotoWindow()

        // This is SF-A: before A1b, pulse compared only the hour of day and therefore
        // counted 22:30 from any date as if it were today's observation.
        let sameHourPreviousDay = "1786912200"   // 2026-08-16 22:30 Vienna
        let sameHourNextDay = "1787085000"       // 2026-08-18 22:30 Vienna

        #expect(sameHourPreviousDay < bounds.startEpoch)
        #expect(sameHourNextDay >= bounds.endEpoch)
    }

    @Test("A non-canonical row cannot be counted even if it sorts into the range")
    func nonCanonicalRowsAreExcluded() throws {
        let bounds = try nightPhotoWindow()

        // Defence in depth: the shape guard in the SQL is what stops this, not luck.
        #expect(isCanonicalCaptureTimestamp("test-capture-timestamp") == false)
        #expect(isCanonicalCaptureTimestamp("1786998600000") == false)
        #expect(bounds.startEpoch.count == 10)
    }

    @Test("The window SQL is a half-open text range with a shape guard and no cast")
    func sqlUsesTheHalfOpenRange() throws {
        // Whole library since F-E2 moved the window helpers into their own file. Atom A
        // replaced the bare COUNT(*) with a lane-scoped per-artefact read; every
        // property the count query was pinned for is still pinned below, and the lane
        // predicate is pinned on top of them.
        let body = try #require(declarationBody(
            startingWithLinePrefix: "func laneScopedObservationEvidenceQuery(",
            inSource: try serverModuleSourceText()
        ))
        let sql = body.joined(separator: "\n")

        #expect(sql.contains("FROM asset_records"))
        #expect(sql.contains(#""captureTimestamp" ~ '^[0-9]{10}$'"#))
        #expect(sql.contains(#""captureTimestamp" >= \(bind: bounds.startEpoch)"#))
        #expect(sql.contains(#""captureTimestamp" < \(bind: bounds.endEpoch)"#))

        // Atom A A-AC4: the lane predicate is what stops one lane closing another's
        // expectation, and it is bound rather than interpolated (A-AC security rule).
        #expect(sql.contains(#"WHERE asset_records.lane_key = \(bind: laneKey)"#))

        // Atom A A-AC5: LEFT, not INNER. An INNER join would drop exactly the records
        // that carry no registered form, which is a distinct outcome that must stay
        // visible rather than being reported as a cleaner day than the data supports.
        #expect(sql.contains("LEFT JOIN asset_files"))
        #expect(sql.contains("INNER JOIN") == false)

        // AC-3: no cast, and no leftover ISO predicate in the product calculation.
        #expect(sql.uppercased().contains("CAST") == false)
        #expect(sql.contains("[0-9]{4}") == false)

        // Result ordering is a per-file client contract; a counting helper must not
        // acquire one of its own.
        #expect(sql.uppercased().contains("ORDER BY") == false)
    }

    @Test("There is exactly one window helper, used by both calculations")
    func singleWindowHelper() throws {
        // Declaration and call sites now live in different files, so both are counted
        // across the library. The point is unchanged: one helper, used twice.
        let lines = trimmedSourceLines(try serverModuleSourceText())

        let helperDeclarations = lines.filter { $0.hasPrefix("func laneScopedObservationEvidenceQuery(") }
        let callSites = lines.filter { $0.contains("laneScopedObservationEvidenceQuery(bounds:") && $0.contains("sql.raw") }
        let boundsCallSites = lines.filter { $0.hasPrefix("guard let windowBounds = observationWindowBounds(") }

        #expect(helperDeclarations.count == 1)
        #expect(callSites.count == 2, "gaps and pulse must share the one helper")
        #expect(boundsCallSites.count == 2)

        // The replaced helper must be gone rather than left behind unused: a second
        // window helper is exactly how the two calculations start to disagree.
        #expect(lines.contains { $0.contains("observationCountInWindowQuery") } == false)

        // The old duplicated window SQL must be gone from both calculations.
        #expect(lines.contains { $0.contains(#"CAST(SUBSTRING("captureTimestamp""#) } == false)
    }
}

// MARK: - AC-5 Decision trace date boundary

@Suite("AC-5 decision trace date boundary")
struct DecisionTraceWindowTests {

    private func decisionQueryBody() throws -> String {
        let body = try #require(declarationBody(
            startingWithLinePrefix: "func leaveEmptyDecisionCountQuery(",
            inSource: try serverModuleSourceText()
        ))
        #expect(body.isEmpty == false)
        return body.joined(separator: "\n")
    }

    @Test("Both window fields are filtered on the intended local date")
    func filtersOnLocalDate() throws {
        let sql = try decisionQueryBody()

        // Without these two lines a leave_empty decision from any earlier day
        // suppressed today's gap for the same standard, permanently.
        #expect(sql.contains(#"SUBSTRING("expected_window_start" FROM 1 FOR 10) = \(bind: localDate)"#))
        #expect(sql.contains(#"SUBSTRING("expected_window_end" FROM 1 FOR 10) = \(bind: localDate)"#))
    }

    @Test("The window hours and the decision semantics are unchanged")
    func windowAndSemanticsPreserved() throws {
        let sql = try decisionQueryBody()

        #expect(sql.contains(#"CAST(SUBSTRING("expected_window_start" FROM 12 FOR 2) AS INTEGER) = \(bind: startHour)"#))
        #expect(sql.contains(#"CAST(SUBSTRING("expected_window_end" FROM 12 FOR 2) AS INTEGER) = \(bind: endHour)"#))
        #expect(sql.contains(#""decision_type" = 'leave_empty'"#))
        #expect(sql.contains(#""source_tag" = '[M]'"#))
        #expect(sql.contains(#""standard_key" = \(bind: standardKey)"#))
    }

    @Test("The decision window fields stay ISO 8601 and are never converted to epoch")
    func fieldsRemainISO() throws {
        let sql = try decisionQueryBody()

        // These record what a person decided about a named window, not when something
        // was captured. Converting them to epoch is explicitly out of scope for A1b.
        #expect(sql.contains(#""expected_window_start" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'"#))
        #expect(sql.contains(#""expected_window_end" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'"#))
        #expect(sql.contains("[0-9]{10}") == false)
    }

    @Test("There is exactly one decision-trace helper, used by both calculations")
    func singleDecisionHelper() throws {
        let lines = trimmedSourceLines(try serverModuleSourceText())

        #expect(lines.filter { $0.hasPrefix("func leaveEmptyDecisionCountQuery(") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("leaveEmptyDecisionCountQuery(") }.count == 2)
    }
}

// MARK: - AC-6 / AC-7 preservation

@Suite("AC-6 and AC-7 preservation")
struct A1bPreservationTests {

    @Test("No stored row is mutated or migrated by this atom")
    func historyUntouched() throws {
        // Whole library: the lane backfill moved to SchemaMigrations.swift in F-D1, and
        // this check must keep seeing every mutation wherever it lives.
        let lines = trimmedSourceLines(try serverModuleSourceText())

        // Every UPDATE/DELETE against asset_records in the whole server, pinned exactly.
        // Two belong to the pre-existing /test/immutable probe, which exists to prove
        // the governance triggers reject them; the third is the pre-existing lane
        // backfill inside CreateLaneMetadataFoundation, which has already run. A1b adds
        // none and must never add one.
        let mutations = lines.filter {
            $0.contains("UPDATE asset_records") || $0.contains("DELETE FROM asset_records")
        }

        #expect(mutations.count == 3, "Unexpected mutation of asset_records: \(mutations)")
        #expect(mutations.filter { $0 == "UPDATE asset_records" }.count == 1, "the /test/immutable UPDATE probe")
        #expect(mutations.filter { $0 == "DELETE FROM asset_records" }.count == 1, "the /test/immutable DELETE probe")
        #expect(mutations.filter { $0.contains("SET lane_key = 'unassigned'") }.count == 1, "the CreateLaneMetadataFoundation backfill")

        // Migration count and order are pinned by MigrationInventoryTests; assert here
        // that A1b introduced no new migration type.
        #expect(declaredStructNames(conformingTo: "AsyncMigration", inSource: try serverModuleSourceText()).count == 12)
    }

    @Test("parsedTimestampDate keeps its epoch-first, ISO-tolerant behaviour")
    func parsingToleranceKept() {
        // /records and /shift-handover/log rely on this for display and sorting of the
        // existing rows; A1b must not narrow it to epoch only.
        #expect(parsedTimestampDate("1786996800") == Date(timeIntervalSince1970: 1_786_996_800))
        #expect(parsedTimestampDate("2026-08-17T22:00:00Z") != nil)
        #expect(parsedTimestampDate("legacy-timestamp") == nil)
    }

    @Test("The read routes keep their queries and ordering")
    func readRoutesUnchanged() throws {
        // Whole library since F-F6 moved the records route into its own file; both
        // demands are unchanged.
        let source = try serverModuleSourceText()

        #expect(source.contains(#"ORDER BY asset_records."captureTimestamp" ASC"#))
        #expect(countDescendingDateComparators(inSource: source) == 2)
    }

    @Test("The bounded diagnostic survives and now guards the ingest contract")
    func diagnosticRepointedNotRemoved() throws {
        let body = try #require(declarationBody(
            startingWithLinePrefix: "func timestampReadExpectationDiagnosticQuery(",
            inSource: try serverModuleSourceText()
        ))
        let sql = body.joined(separator: "\n")

        // Still bounded, still count + example IDs only (A1a, AC-7).
        #expect(sql.contains("COUNT(*)"))
        #expect(sql.uppercased().contains("LIMIT"))

        // Repointed: the ISO read expectation no longer exists, so the diagnostic now
        // reports rows that fall outside the canonical ingest contract instead. With
        // the ingest guard in place a healthy server logs nothing at all.
        #expect(sql.contains(#""captureTimestamp" !~ '^[0-9]{10}$'"#))
        #expect(sql.contains("[0-9]{4}") == false)
    }

    @Test("No per-row logging was reintroduced anywhere")
    func noPerRowLogging() throws {
        // Whole library: F-F8 moved the gaps calculation into its own file, so one of
        // the two diagnostic call sites went with it. The demand is unchanged — exactly
        // two, one per calculation, and nothing per-row anywhere.
        let lines = trimmedSourceLines(try serverModuleSourceText())

        #expect(lines.contains { $0.contains("skippedTimestamp") } == false)
        #expect(lines.contains { $0.contains("skippedID") } == false)
        #expect(lines.filter { $0.hasPrefix("logTimestampReadExpectationDiagnostic(") }.count == 2)

        // One each, and specifically in these two places. The library-wide count above
        // would still pass if both ended up in the same calculation, which would mean
        // one of them had stopped reporting.
        let gapsSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "MechanicalGapReadRoutes.swift" }?.text,
            "MechanicalGapReadRoutes.swift is missing from the library"
        )
        #expect(trimmedSourceLines(gapsSource)
            .filter { $0.hasPrefix("logTimestampReadExpectationDiagnostic(") }.count == 1)
        let pulseSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "OperationalPulseReadRoutes.swift" }?.text,
            "OperationalPulseReadRoutes.swift is missing from the library"
        )
        #expect(trimmedSourceLines(pulseSource)
            .filter { $0.hasPrefix("logTimestampReadExpectationDiagnostic(") }.count == 1)

        // Since F-F9 both calculations live in route files, so the composition root has
        // no diagnostic call left at all.
        #expect(trimmedSourceLines(try serverSourceText())
            .filter { $0.hasPrefix("logTimestampReadExpectationDiagnostic(") }.count == 0)
    }
}
