import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - AC-4: domain validators and time helpers
//
// Atom SERVER-MOD-A0 (WFOS-20260817-PSKS-020).
//
// These are pure functions today (AIHOSAssetServer.swift lines 778–869) and are
// characterized exactly as they behave — not as they arguably ought to behave. Where
// current behaviour looks surprising it is pinned with a comment saying so, because
// A0 exists to make a later move provably behaviour-preserving, not to improve
// anything.
//
// TIME ZONE DISCIPLINE (AC-4, final bullet): `humanReadableTimestamp` formats in the
// machine's local time zone and `iso8601DateStringForToday` resolves "today" in UTC.
// No assertion below hard-codes a zone-dependent string, so these tests behave the
// same on a developer machine and in a UTC container. What is left unpinned by that
// choice is reported as a remaining gap in the completion report rather than papered
// over with a locale assumption this atom is not allowed to introduce.

// MARK: - Lane allowlists

@Suite("Lane allowlists are two separate lists")
struct LaneAllowlistTests {

    @Test("The asset lane allowlist has exactly its seven current values")
    func assetLaneAllowlistIsExact() {
        #expect(allowedLaneKeys == ["kitchen", "service", "finance", "unassigned", "bar", "cleaning", "economy"])
        #expect(allowedLaneKeys.count == 7)
    }

    @Test("The operational-standard lane allowlist has exactly its six current values")
    func standardLaneAllowlistIsExact() {
        #expect(allowedOperationalStandardLaneKeys == ["kitchen", "service", "bar", "cleaning", "maintenance", "unassigned"])
        #expect(allowedOperationalStandardLaneKeys.count == 6)
    }

    @Test("The two allowlists genuinely differ and must never be merged")
    func allowlistsAreDeliberatelyDifferent() {
        // This is the assertion that stops a future "cleanup" from collapsing the two
        // lists into one shared constant. The difference is real in both directions.
        #expect(allowedLaneKeys != allowedOperationalStandardLaneKeys)

        #expect(allowedLaneKeys.subtracting(allowedOperationalStandardLaneKeys) == ["finance", "economy"])
        #expect(allowedOperationalStandardLaneKeys.subtracting(allowedLaneKeys) == ["maintenance"])
    }

    @Test("The track-type allowlist has exactly its four current values")
    func trackTypeAllowlistIsExact() {
        #expect(allowedOperationalStandardTrackTypes == ["observation", "photo", "audio", "ocr"])
    }
}

// MARK: - Validators

@Suite("Lane and track validators")
struct ValidatorCharacterizationTests {

    @Test("Positive control: every allowed asset lane validates to itself")
    func assetLanesValidate() {
        for lane in allowedLaneKeys {
            #expect(validatedLaneKey(lane) == lane)
        }
    }

    @Test("A nil asset lane defaults to unassigned rather than failing")
    func nilAssetLaneDefaults() {
        // Current behaviour: absence is allowed and means "unassigned". Only an
        // explicitly wrong value is rejected.
        #expect(validatedLaneKey(nil) == "unassigned")
    }

    @Test("Negative control: unknown, empty and cross-list asset lanes are rejected")
    func assetLaneRejections() {
        #expect(validatedLaneKey("maintenance") == nil, "maintenance belongs to the standards list, not the asset list")
        #expect(validatedLaneKey("") == nil)
        #expect(validatedLaneKey("Kitchen") == nil, "matching is case sensitive")
        #expect(validatedLaneKey(" kitchen") == nil, "no trimming is performed")
        #expect(validatedLaneKey("housekeeping") == nil)
    }

    @Test("Positive control: every allowed standard lane validates to itself")
    func standardLanesValidate() {
        for lane in allowedOperationalStandardLaneKeys {
            #expect(validatedOperationalStandardLaneKey(lane) == lane)
        }
    }

    @Test("Negative control: cross-list standard lanes are rejected")
    func standardLaneRejections() {
        #expect(validatedOperationalStandardLaneKey("finance") == nil, "finance belongs to the asset list")
        #expect(validatedOperationalStandardLaneKey("economy") == nil, "economy belongs to the asset list")
        #expect(validatedOperationalStandardLaneKey("") == nil)
        #expect(validatedOperationalStandardLaneKey("KITCHEN") == nil)
    }

    @Test("Positive and negative control for track types")
    func trackTypeValidation() {
        for trackType in allowedOperationalStandardTrackTypes {
            #expect(validatedOperationalStandardTrackType(trackType) == trackType)
        }

        #expect(validatedOperationalStandardTrackType("video") == nil)
        #expect(validatedOperationalStandardTrackType("Photo") == nil)
        #expect(validatedOperationalStandardTrackType("") == nil)
    }
}

// MARK: - Expected window parsing

@Suite("Expected window parsing")
struct ExpectedWindowTests {

    @Test("Whole hours from 00:00 to 23:00 parse to their hour")
    func wholeHoursParse() {
        #expect(hourFromExpectedWindow("00:00") == 0)
        #expect(hourFromExpectedWindow("09:00") == 9)
        #expect(hourFromExpectedWindow("22:00") == 22)
        #expect(hourFromExpectedWindow("23:00") == 23)
    }

    @Test("An unpadded hour is accepted, because Int parsing does not require padding")
    func unpaddedHourIsAccepted() {
        // Pinned as current behaviour, not endorsed: "7:00" is accepted even though the
        // system otherwise writes zero-padded windows.
        #expect(hourFromExpectedWindow("7:00") == 7)
    }

    @Test("Negative control: anything that is not a whole hour is rejected")
    func nonWholeHoursAreRejected() {
        #expect(hourFromExpectedWindow("22:30") == nil, "only :00 minutes are allowed")
        #expect(hourFromExpectedWindow("24:00") == nil, "hour must be <= 23")
        #expect(hourFromExpectedWindow("-1:00") == nil)
        #expect(hourFromExpectedWindow("22") == nil, "a colon is required")
        #expect(hourFromExpectedWindow("22:00:00") == nil, "exactly two components")
        #expect(hourFromExpectedWindow("") == nil)
        #expect(hourFromExpectedWindow("ab:00") == nil)
    }
}

// MARK: - Date and timestamp helpers

@Suite("Date and timestamp helpers")
struct TimestampHelperTests {

    @Test("Positive control: a plain ISO calendar date validates")
    func validCalendarDates() {
        #expect(isValidISO8601DateString("2026-08-17"))
        #expect(isValidISO8601DateString("0001-01-01"))
    }

    @Test("Negative control: partial, padded-wrong and full timestamps are rejected")
    func invalidCalendarDates() {
        #expect(isValidISO8601DateString("2026-8-17") == false)
        #expect(isValidISO8601DateString("2026-08-17T22:00:00Z") == false)
        #expect(isValidISO8601DateString("26-08-17") == false)
        #expect(isValidISO8601DateString("") == false)
        #expect(isValidISO8601DateString("not-a-date") == false)

        // Pinned as current behaviour: the check is a shape regex, not a calendar check,
        // so an impossible date passes. The gap calculation relies on Postgres for real
        // date semantics.
        #expect(isValidISO8601DateString("2026-13-45"))
    }

    @Test("iso8601Timestamp composes a zero-padded UTC hour boundary")
    func timestampComposition() {
        #expect(iso8601Timestamp(dateString: "2026-08-17", hour: 22) == "2026-08-17T22:00:00Z")
        #expect(iso8601Timestamp(dateString: "2026-08-17", hour: 0) == "2026-08-17T00:00:00Z")
        #expect(iso8601Timestamp(dateString: "2026-08-17", hour: 9) == "2026-08-17T09:00:00Z")
    }

    @Test("iso8601DateStringForToday produces a valid calendar date shape")
    func todayHasValidShape() {
        let today = iso8601DateStringForToday()

        // No absolute value is asserted: the helper resolves "today" in UTC and this
        // test must behave identically wherever it runs. Shape and self-consistency are
        // what can be pinned without importing a time-zone assumption.
        #expect(today.count == 10)
        #expect(isValidISO8601DateString(today))
        #expect(iso8601Timestamp(dateString: today, hour: 23).hasPrefix(today))
    }

    @Test("parsedTimestampDate accepts both Unix seconds and ISO 8601")
    func timestampParsing() {
        let unix = parsedTimestampDate("1750000000")
        #expect(unix == Date(timeIntervalSince1970: 1_750_000_000))

        let iso = parsedTimestampDate("2026-08-17T22:15:00Z")
        #expect(iso != nil)

        // Both forms coexist in stored data, which is exactly why the sorting helpers
        // funnel through this function instead of comparing strings.
        #expect(unix != iso)
    }

    @Test("Negative control: unparseable timestamps return nil")
    func timestampParsingFailure() {
        #expect(parsedTimestampDate("legacy-timestamp") == nil)
        #expect(parsedTimestampDate("") == nil)
        #expect(parsedTimestampDate("2026-08-17") == nil, "a bare calendar date is not an ISO 8601 instant here")
    }

    @Test("humanReadableTimestamp returns the input unchanged when it cannot be parsed")
    func unparseableTimestampPassesThrough() {
        // Time-zone independent by construction: this path never formats anything.
        #expect(humanReadableTimestamp("legacy-timestamp") == "legacy-timestamp")
        #expect(humanReadableTimestamp("") == "")
        #expect(humanReadableTimestamp("2026-08-17") == "2026-08-17")
    }

    @Test("humanReadableTimestamp reformats a parseable timestamp to yyyy-MM-dd HH:mm")
    func parseableTimestampIsReformatted() {
        let formatted = humanReadableTimestamp("2026-08-17T22:15:00Z")

        // Shape only. The absolute value depends on the machine's local time zone,
        // which this atom is forbidden from changing or asserting away.
        #expect(formatted != "2026-08-17T22:15:00Z")
        #expect(formatted.count == 16)
        #expect(formatted.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
                "Unexpected format: \(formatted)")

        let fromUnix = humanReadableTimestamp("1750000000")
        #expect(fromUnix.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil)
    }
}

// MARK: - Legacy timestamp helper

@Suite("Legacy timestamp skip query")
struct LegacyTimestampQueryTests {

    /// The SQL is built as an `SQLQueryString`, which has no dialect-free rendering, so
    /// this is characterized from the declaration in the source instead of by executing
    /// or serializing it. No database is touched, as A0 requires.
    private func queryBody() throws -> [String] {
        let source = try serverSourceText()

        let body = declarationBody(
            startingWithLinePrefix: "func legacyTimestampSkipLogQuery(",
            inSource: source
        )

        // Positive control: a moved or renamed declaration must fail loudly rather than
        // hand back an empty body that satisfies every "does not contain" assertion.
        #expect(body != nil, "legacyTimestampSkipLogQuery declaration not found in the server source")
        #expect((body ?? []).isEmpty == false)

        return body ?? []
    }

    @Test("The query selects only non-ISO rows and is unbounded")
    func queryShape() throws {
        let body = try queryBody()
        let sql = body.joined(separator: "\n")

        #expect(sql.contains("FROM asset_records"))
        #expect(sql.contains(#""captureTimestamp" !~"#))
        #expect(sql.contains(#"ORDER BY "captureTimestamp" ASC"#))

        // Pinned as current behaviour and as the code-level cause of the log-volume
        // finding (KSPS-021 §7): there is no LIMIT, so the result set — and therefore
        // the three log lines emitted per row — grows with the whole table. A1 owns the
        // change; A0 only pins the starting point so the change is visible in a diff.
        #expect(sql.uppercased().contains("LIMIT") == false)
    }

    @Test("The context parameter never reaches the SQL (SF-C, independently verified by GS)")
    func contextParameterIsUnused() throws {
        let body = try queryBody()

        // The parameter is accepted and then dropped; the calling sites express context
        // through their own hard-coded print statements instead. Pinned so that removing
        // the dead parameter later is provably behaviour-neutral.
        #expect(body.contains { $0.contains("context") } == false,
                "context is now referenced inside the query body: \(body)")
    }
}
