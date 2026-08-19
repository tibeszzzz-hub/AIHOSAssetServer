import Foundation
import Vapor

// MARK: - Operations time zone
//
// Which local day an observation belongs to. Extracted verbatim from
// AIHOSAssetServer.swift by F-E1 — no value, signature, access level, fail-closed rule
// or behaviour changed.
//
// What stayed behind: the window arithmetic that consumes these helpers, the epoch
// formatting, and the server host and storage configuration. This file answers only
// "which zone, and which local date is it there".
//
// Hotel days are local days. A "22:00–23:00" standard means 22:00 local time, so
// every window boundary has to be resolved in the operation's own zone before it can
// be compared with a UTC epoch.
//
// INTERIM CONFIGURATION: the zone is supplied per deployment through
// `OPERATIONS_TIMEZONE`. The current value and the decision behind it live in the
// deployment configuration and in Tibi's decision of 2026-08-18 (see the A1b build
// order) — deliberately not here, because a zone name written into the source would
// go stale the day the operation moves and would then contradict the configuration.
// Moving zones must therefore be a configuration change only. When an Organization
// model exists and owns the zone, this reads from there instead; the resolution and
// fail-closed behaviour below stay the same.

/// Name of the environment variable holding the IANA operations time zone.
let operationsTimeZoneEnvironmentKey = "OPERATIONS_TIMEZONE"

/// Why the operations time zone could not be resolved.
///
/// Both cases refuse startup. There is no default and no fallback: a server that
/// guessed a zone would compute every hotel day boundary wrong while looking healthy.
enum OperationsTimeZoneError: Error, CustomStringConvertible {
    case notConfigured
    case notAnIANATimeZone(String)

    var description: String {
        switch self {
        case .notConfigured:
            return "\(operationsTimeZoneEnvironmentKey) is required and must be set to an IANA time zone identifier"
        case .notAnIANATimeZone(let value):
            return "\(operationsTimeZoneEnvironmentKey) is not a known IANA time zone identifier: \(value)"
        }
    }
}

/// Resolves the operations time zone from a raw configuration value.
///
/// Kept separate from the environment lookup so the fail-closed rule can be tested
/// without mutating process environment state — same shape as `MachineCredential`.
///
/// Membership in `knownTimeZoneIdentifiers` is checked explicitly: `TimeZone(identifier:)`
/// alone also accepts offset forms such as "GMT+0200", which carry no DST rules and
/// would silently produce wrong boundaries twice a year.
func resolvedOperationsTimeZone(fromConfiguredValue value: String?) throws -> TimeZone {
    guard let value else {
        throw OperationsTimeZoneError.notConfigured
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
        throw OperationsTimeZoneError.notConfigured
    }

    guard TimeZone.knownTimeZoneIdentifiers.contains(trimmed),
          let timeZone = TimeZone(identifier: trimmed) else {
        throw OperationsTimeZoneError.notAnIANATimeZone(trimmed)
    }

    return timeZone
}

/// Resolves the operations time zone from the process environment. Refuses startup on
/// a missing or unknown value.
func resolvedOperationsTimeZone() throws -> TimeZone {
    try resolvedOperationsTimeZone(fromConfiguredValue: Environment.get(operationsTimeZoneEnvironmentKey))
}

/// Gregorian calendar pinned to the operations zone.
func operationsCalendar(timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

/// The local operations date of `date`, as `YYYY-MM-DD`.
///
/// This is the day a hotel is working in, which is not the UTC day — at 00:30 local
/// in Vienna the UTC date is still yesterday.
func operationsDateString(for date: Date, in timeZone: TimeZone) -> String {
    let calendar = operationsCalendar(timeZone: timeZone)
    let components = calendar.dateComponents([.year, .month, .day], from: date)

    guard let year = components.year,
          let month = components.month,
          let day = components.day else {
        return String(ISO8601DateFormatter().string(from: date).prefix(10))
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}
