import Foundation
import SQLKit

// MARK: - Observation window
//
// Turning a standard's "22:00–23:00" into a range that can be compared against stored
// timestamps, and the two queries that use it. Extracted verbatim from
// AIHOSAssetServer.swift by F-E2 — no signature, access level, time zone rule, epoch
// handling, SQL or behaviour changed.
//
// What stayed behind: the operations time zone that these helpers resolve boundaries
// in (F-E1), the diagnostic query, isStandardActive, and the server host and storage
// configuration.

/// Half-open epoch bounds of one standard's window on one local operations date.
///
/// Both values are exactly ten digits so they can be compared directly against the
/// stored text. `endEpoch` is exclusive.
struct ObservationWindowBounds: Equatable {
    let startEpoch: String
    let endEpoch: String
}

/// Formats an epoch second as the canonical fixed-width text form.
///
/// Returns `nil` outside the representable range, so a value that would break the
/// fixed width — and therefore break lexicographic ordering — can never be emitted.
func canonicalEpochString(_ epochSeconds: Int) -> String? {
    guard epochSeconds >= 0, epochSeconds <= 9_999_999_999 else { return nil }
    return String(format: "%010d", epochSeconds)
}

/// Resolves `localDate` plus `startHour..<endHour` into canonical epoch bounds.
///
/// The single window helper both the gap and the pulse calculation use. Boundaries
/// are built from date components rather than by adding hours to midnight, so a day
/// that is 23 or 25 hours long resolves to the correct wall-clock instants.
///
/// Returns `nil` for an unusable request — malformed date, inverted or out-of-range
/// hours, or an epoch outside the fixed width — so the caller fails closed instead of
/// counting against a half-built window.
func observationWindowBounds(
    localDate: String,
    startHour: Int,
    endHour: Int,
    timeZone: TimeZone
) -> ObservationWindowBounds? {
    guard isValidISO8601DateString(localDate) else { return nil }
    guard startHour >= 0, endHour > startHour, endHour <= 24 else { return nil }

    let parts = localDate.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]) else { return nil }

    let calendar = operationsCalendar(timeZone: timeZone)

    var startComponents = DateComponents()
    startComponents.year = year
    startComponents.month = month
    startComponents.day = day
    startComponents.hour = startHour

    guard let startDate = calendar.date(from: startComponents) else { return nil }

    let endDate: Date?
    if endHour == 24 {
        // A window closing at midnight belongs to the next local day's 00:00.
        var midnightComponents = DateComponents()
        midnightComponents.year = year
        midnightComponents.month = month
        midnightComponents.day = day
        midnightComponents.hour = 0

        endDate = calendar.date(from: midnightComponents).flatMap {
            calendar.date(byAdding: .day, value: 1, to: $0)
        }
    } else {
        var endComponents = DateComponents()
        endComponents.year = year
        endComponents.month = month
        endComponents.day = day
        endComponents.hour = endHour

        endDate = calendar.date(from: endComponents)
    }

    guard let endDate,
          let startEpoch = canonicalEpochString(Int(startDate.timeIntervalSince1970)),
          let endEpoch = canonicalEpochString(Int(endDate.timeIntervalSince1970)),
          startEpoch < endEpoch else { return nil }

    return ObservationWindowBounds(startEpoch: startEpoch, endEpoch: endEpoch)
}

/// Counts observations inside one window. The only window SQL in the server.
///
/// The comparison is a plain half-open text range. That is exact rather than
/// convenient: every stored value is fixed-width, so lexicographic order is numeric
/// order. The shape guard is defence in depth — should a non-canonical row ever exist
/// despite the ingest contract, it is excluded rather than mis-ranked.
func observationCountInWindowQuery(bounds: ObservationWindowBounds) -> SQLQueryString {
    """
        SELECT COUNT(*) AS "recordCount"
        FROM asset_records
        WHERE "captureTimestamp" ~ '^[0-9]{10}$'
          AND "captureTimestamp" >= \(bind: bounds.startEpoch)
          AND "captureTimestamp" < \(bind: bounds.endEpoch)
    """
}

/// Counts human `leave_empty` decisions for one standard, on one local date, for one
/// window. The only decision-trace window SQL in the server.
///
/// `expected_window_start` and `expected_window_end` stay ISO 8601: they record what a
/// person decided about a named window, not when an observation was captured, and are
/// deliberately not converted to epoch here.
///
/// The date filter is the correction: without it a `leave_empty` decision made on any
/// earlier day suppressed today's gap for the same standard, forever.
func leaveEmptyDecisionCountQuery(
    standardKey: String,
    localDate: String,
    startHour: Int,
    endHour: Int
) -> SQLQueryString {
    """
        SELECT COUNT(*) AS "decisionCount"
        FROM decision_traces
        WHERE "standard_key" = \(bind: standardKey)
          AND "expected_window_start" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
          AND "expected_window_end" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
          AND SUBSTRING("expected_window_start" FROM 1 FOR 10) = \(bind: localDate)
          AND SUBSTRING("expected_window_end" FROM 1 FOR 10) = \(bind: localDate)
          AND CAST(SUBSTRING("expected_window_start" FROM 12 FOR 2) AS INTEGER) = \(bind: startHour)
          AND CAST(SUBSTRING("expected_window_end" FROM 12 FOR 2) AS INTEGER) = \(bind: endHour)
          AND "decision_type" = 'leave_empty'
          AND "source_tag" = '[M]'
    """
}

func hourFromExpectedWindow(_ expectedWindow: String) -> Int? {
    let parts = expectedWindow.split(separator: ":")

    guard parts.count == 2,
          let hour = Int(parts[0]),
          hour >= 0,
          hour <= 23,
          parts[1] == "00" else {
        return nil
    }

    return hour
}
