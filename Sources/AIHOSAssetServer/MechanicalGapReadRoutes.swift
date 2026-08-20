import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Mechanical gap detection read route
//
// F-F8. Reports operational standards whose expected observation did not arrive, for a
// given operations day. `GET /api/v1/state/pulse` deliberately stays in the composition
// root for now; the two share helpers but not code, so this file holds the gaps read
// only and is named accordingly.
//
// WHAT IS THREADED IN AND WHY
//   `operationsTimeZone` is the only value this route needs from main(). It is resolved
//   there once, fail-closed, and passed in rather than resolved again: two lookups
//   could disagree, and this one decides which day a hotel is asking about. Everything
//   else it uses is already module-level — the window helpers (F-E2), the operations
//   time helpers (F-E1), the timestamp diagnostic (F-E3) and isStandardActive (F-E5).
//   Nothing was duplicated to make this move.
//
// FOUR THINGS THAT ARE CONTRACT, NOT STYLE
//   The default date is today in the OPERATIONS zone, not UTC. A hotel working at 00:30
//   local is still asking about its own day, and computing that in UTC would silently
//   report the wrong one for part of every night.
//
//   Two fail-closed skips, and they are not the same skip. A standard that was inactive
//   at evaluation time is skipped as a normal outcome and logged as such. A standard
//   whose window cannot be resolved is skipped as a fault and logged as a warning with
//   metadata — never evaluated against a half-built range. Collapsing them would hide a
//   configuration error inside routine output.
//
//   A gap is reported only when the observation count falls short AND no leave-empty
//   decision was recorded. The second check is what keeps a deliberate decision from
//   being re-reported as a failure.
//
//   The parameter is named `apiV1` on purpose: the route manifest resolves a
//   registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `GET /api/v1/gaps/mechanical` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - operationsTimeZone: the zone resolved once in `main()`, fail-closed.
func registerMechanicalGapReadRoutes(on apiV1: MachineGatedRoutes, operationsTimeZone: TimeZone) {
    apiV1.get("gaps", "mechanical") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }
        // The default is today in the operations zone, not in UTC: a hotel working
        // at 00:30 local is still asking about its own day.
        let requestedDate = req.query[String.self, at: "date"]
            ?? operationsDateString(for: Date(), in: operationsTimeZone)

        guard isValidISO8601DateString(requestedDate) else {
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "date must use YYYY-MM-DD format"
            ])
            return response
        }
        let standards = try await sql.raw("""
            SELECT
                id,
                "standardKey",
                "description",
                "sourceTag",
                "startHour",
                "endHour",
                "requiredCount",
                created_at
            FROM operational_standards
            ORDER BY "standardKey" ASC
        """).all()

        var gaps: [[String: String]] = []

        let timestampDiagnosticRows = try await sql.raw(timestampReadExpectationDiagnosticQuery()).all()
        logTimestampReadExpectationDiagnostic(
            try timestampReadExpectationDiagnostic(from: timestampDiagnosticRows),
            calculation: "gaps/mechanical",
            logger: req.logger
        )

        for standard in standards {
            let standardID = try standard.decode(column: "id", as: UUID.self)
            let standardKey = try standard.decode(column: "standardKey", as: String.self)
            let description = try standard.decode(column: "description", as: String.self)
            let sourceTag = try standard.decode(column: "sourceTag", as: String.self)
            let startHour = try standard.decode(column: "startHour", as: Int.self)
            let endHour = try standard.decode(column: "endHour", as: Int.self)
            let requiredCount = try standard.decode(column: "requiredCount", as: Int.self)
            let createdAt = try standard.decode(column: "created_at", as: String.self)
            let evaluationTimestamp = iso8601Timestamp(dateString: requestedDate, hour: endHour)
            let standardWasActive = try await isStandardActive(
                standardID: standardID,
                at: evaluationTimestamp,
                createdAt: createdAt,
                sql: sql
            )

            guard standardWasActive else {
                print("Historical status resolution: standard inactive at gap evaluation time — skipping \(standardKey)")
                continue
            }

            // Fail closed: a standard whose window cannot be resolved is skipped and
            // reported rather than evaluated against a half-built range.
            guard let windowBounds = observationWindowBounds(
                localDate: requestedDate,
                startHour: startHour,
                endHour: endHour,
                timeZone: operationsTimeZone
            ) else {
                req.logger.warning(
                    "Unresolvable observation window, standard skipped",
                    metadata: [
                        "calculation": .string("gaps/mechanical"),
                        "standardKey": .string(standardKey),
                        "localDate": .string(requestedDate)
                    ]
                )
                continue
            }

            let countRows = try await sql.raw(observationCountInWindowQuery(bounds: windowBounds)).all()

            let observedCount = try countRows[0].decode(column: "recordCount", as: Int.self)

            if observedCount < requiredCount {
                let decisionRows = try await sql.raw(
                    leaveEmptyDecisionCountQuery(
                        standardKey: standardKey,
                        localDate: requestedDate,
                        startHour: startHour,
                        endHour: endHour
                    )
                ).all()

                let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)

                if decisionCount == 0 {
                    gaps.append([
                        "sourceTag": sourceTag,
                        "standardKey": standardKey,
                        "description": description,
                        "expectedDate": requestedDate,
                        "evaluationTimestamp": evaluationTimestamp,
                        "expectedWindow": String(format: "%02d:00-%02d:00", startHour, endHour),
                        "requiredCount": String(requiredCount),
                        "observedCount": String(observedCount),
                        "gapStatus": "Missing expected observation"
                    ])
                }
            }
        }

        print("Mechanical gap detection PASS: \(gaps.count) gaps")

        let response = Response(status: .ok)
        try response.content.encode(gaps)
        return response
    }
}
