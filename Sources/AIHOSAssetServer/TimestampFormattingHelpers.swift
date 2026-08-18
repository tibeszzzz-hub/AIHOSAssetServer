import Foundation

// MARK: - Timestamp formatting, parsing and the canonical shape
//
// Pure text and date helpers: how a timestamp is written, read and recognised.
// Extracted verbatim from AIHOSAssetServer.swift by F-C3 — no signature, access level
// or behaviour changed.
//
// What deliberately stayed behind: the operations time zone, the calendar and window
// arithmetic that depends on it, `hourFromExpectedWindow`, and the diagnostic query.
// Those answer questions about a specific operation's day, not about the shape of a
// timestamp, and they carry dependencies this file does not.

func iso8601DateStringForToday() -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

    let now = Date()
    let components = calendar.dateComponents([.year, .month, .day], from: now)

    guard let year = components.year,
          let month = components.month,
          let day = components.day else {
        return String(ISO8601DateFormatter().string(from: now).prefix(10))
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}

func iso8601Timestamp(dateString: String, hour: Int) -> String {
    String(format: "%@T%02d:00:00Z", dateString, hour)
}

func isValidISO8601DateString(_ dateString: String) -> Bool {
    dateString.range(
        of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
        options: .regularExpression
    ) != nil
}

// --- Timestamp Parsing and Formatting Helpers ---
func parsedTimestampDate(_ timestamp: String) -> Date? {
    if let unixTimestamp = TimeInterval(timestamp) {
        return Date(timeIntervalSince1970: unixTimestamp)
    }

    let isoFormatter = ISO8601DateFormatter()
    return isoFormatter.date(from: timestamp)
}

func humanReadableTimestamp(_ timestamp: String) -> String {
    guard let date = parsedTimestampDate(timestamp) else {
        return timestamp
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

// MARK: - Canonical capture timestamp contract
//
// `asset_records."captureTimestamp"` is a 10-digit Unix epoch in seconds, UTC
// (WFOS-20260817-NBPS-001). That is the single accepted ingest form: no ISO 8601, no
// 13-digit milliseconds, no silent normalisation. A non-canonical upload is refused
// before anything is written, so a rejected request never leaves a file on disk or a
// row in the database.
//
// The fixed width is load-bearing. Because every accepted value is exactly ten
// digits, lexicographic ordering of the stored text equals numeric ordering, which is
// what lets the window comparison below be a plain string range instead of a cast.

/// The only capture timestamp shape this server accepts.
let canonicalCaptureTimestampPattern = "^[0-9]{10}$"

/// True when `value` is a 10-digit Unix epoch in seconds.
///
/// Deliberately strict: a 13-digit millisecond value is refused rather than divided,
/// because guessing a client's unit is how silent data corruption starts.
func isCanonicalCaptureTimestamp(_ value: String) -> Bool {
    value.range(of: canonicalCaptureTimestampPattern, options: .regularExpression) != nil
}
