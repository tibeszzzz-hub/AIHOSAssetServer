import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Operational pulse read route
//
// F-F9, the last read route to leave the composition root. Reports a single
// three-state colour for the current operations day.
//
// WHAT IS THREADED IN
//   `operationsTimeZone` only, following the pattern proved in F-F8: main() resolves it
//   once, fail-closed, and passes it in rather than having this file resolve it again.
//   Every other helper is reused from the module — the window helpers (F-E2), the
//   operations time helpers (F-E1), the timestamp diagnostic (F-E3) and
//   isStandardActive (F-E5). Nothing was duplicated to make the move possible.
//
// HOW THIS DIFFERS FROM gaps/mechanical, DESPITE THE SHARED SHAPE
//   The two walk the same standards with the same helpers, but they answer different
//   questions and must not be merged on the strength of looking alike:
//
//   - Pulse always evaluates TODAY in the operations zone. It takes no date parameter,
//     so it has no date validation and no 400 path at all.
//   - Pulse counts rather than lists. It returns two numbers reduced to one colour, and
//     the standards it skips as inactive are excluded from activeStandardsCount, which
//     is what makes "blue" mean "nothing active" rather than "nothing checked".
//   - Its gap branch logs both outcomes. A gap covered by a decision trace is reported
//     as historically intact rather than passed over silently, because an operator
//     reading the log needs to see that the decision was the reason.
//
//   The colour rule itself is ordered, not a set of independent cases: no active
//   standards wins over any gap count, so blue is checked first. Reordering the
//   branches compiles and changes what the board shows.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `GET /api/v1/state/pulse` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - operationsTimeZone: the zone resolved once in `main()`, fail-closed.
func registerOperationalPulseReadRoutes(on apiV1: MachineGatedRoutes, operationsTimeZone: TimeZone) {
    apiV1.get("state", "pulse") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        let gapsRows = try await sql.raw("""
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

        // Pulse reports the current operations day. Before A1b it compared only the
        // hour of day and therefore counted observations from any date (SF-A).
        let pulseDate = operationsDateString(for: Date(), in: operationsTimeZone)

        var activeStandardsCount = 0
        var informationGapsCount = 0

        let timestampDiagnosticRows = try await sql.raw(timestampReadExpectationDiagnosticQuery()).all()
        logTimestampReadExpectationDiagnostic(
            try timestampReadExpectationDiagnostic(from: timestampDiagnosticRows),
            calculation: "state/pulse",
            logger: req.logger
        )

        for standard in gapsRows {
            let standardID = try standard.decode(column: "id", as: UUID.self)
            let standardKey = try standard.decode(column: "standardKey", as: String.self)
            let startHour = try standard.decode(column: "startHour", as: Int.self)
            let endHour = try standard.decode(column: "endHour", as: Int.self)
            let requiredCount = try standard.decode(column: "requiredCount", as: Int.self)
            let createdAt = try standard.decode(column: "created_at", as: String.self)
            let evaluationTimestamp = iso8601Timestamp(dateString: pulseDate, hour: endHour)
            let standardWasActive = try await isStandardActive(
                standardID: standardID,
                at: evaluationTimestamp,
                createdAt: createdAt,
                sql: sql
            )

            guard standardWasActive else {
                print("Historical status resolution: standard inactive at pulse evaluation time — skipping \(standardKey)")
                continue
            }

            activeStandardsCount += 1

            // Same fail-closed rule and the same single window helper as gaps.
            guard let windowBounds = observationWindowBounds(
                localDate: pulseDate,
                startHour: startHour,
                endHour: endHour,
                timeZone: operationsTimeZone
            ) else {
                req.logger.warning(
                    "Unresolvable observation window, standard skipped",
                    metadata: [
                        "calculation": .string("state/pulse"),
                        "standardKey": .string(standardKey),
                        "localDate": .string(pulseDate)
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
                        localDate: pulseDate,
                        startHour: startHour,
                        endHour: endHour
                    )
                ).all()

                let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)

                if decisionCount == 0 {
                    informationGapsCount += 1
                    print("Open gap without Decision Trace: \(standardKey)")
                } else {
                    print("Gap has Decision Trace and remains historically intact: \(standardKey)")
                }
            }
        }

        let pulseState: String

        if activeStandardsCount == 0 {
            pulseState = "blue"
        } else if informationGapsCount > 0 {
            pulseState = "yellow"
        } else {
            pulseState = "green"
        }

        print("Mechanical pulse generation PASS")
        print("activeStandardsCount: \(activeStandardsCount)")
        print("informationGapsCount: \(informationGapsCount)")
        print("pulseState: \(pulseState)")
        print("sourceTag: [S]")

        let response = Response(status: .ok)
        try response.content.encode([
            "pulseState": pulseState,
            "sourceTag": "[S]"
        ])
        return response
    }
}
