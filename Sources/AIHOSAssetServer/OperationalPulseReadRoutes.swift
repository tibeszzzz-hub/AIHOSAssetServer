import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Operational pulse read route
//
// F-F9, extended by Atom A (WFOS-20260822-PSKS-004). Reports a single three-state
// colour for the current operations day.
//
// WHAT CHANGED IN ATOM A
//   The colour vocabulary did not change, and deliberately so — blue, yellow and green
//   are what the board renders, and Atom A is not the place to add a fourth state. What
//   changed is which facts produce them.
//
//   Counting is now scoped to each standard's own lane and requires the evidence behind
//   a record to be readable, exactly as in gaps/mechanical and through the same helper.
//   Before Atom A a recording in one lane could close another lane's expectation, and a
//   record whose payload file had vanished still counted as a fulfilled observation.
//
//   A standard whose activation cannot be established no longer disappears. Its
//   created_at is the legacy sentinel that `isStandardActive` compares as plain text and
//   always loses, so it used to be skipped as inactive — excluded from
//   activeStandardsCount, which is precisely the count that decides blue. Enough such
//   standards and the board reported "nothing active" while every one of them was
//   unexamined. It now counts as active AND as an information gap: unresolved is not a
//   reason to show a calmer colour than the data supports.
//
//   An unresolvable window is counted as an information gap for the same reason. It
//   previously left the loop without touching either counter, which let a configuration
//   fault contribute silently to green.
//
// WHAT THIS ROUTE MAY NOT BE USED FOR
//   Pulse does not match track types — no relation records the form of an asset record,
//   so there is nothing to match against. It reports one colour for the whole operations
//   day and is not evidence about any single lane or track. A green pulse is not proof
//   that a kitchen photo standard was met; only gaps/mechanical answers per standard,
//   and even there `trackEvaluable` is false. The limitation is logged on every call
//   rather than left to be inferred.
//
// WHAT IS THREADED IN
//   `operationsTimeZone` and `storageDirectory`, following the pattern proved in F-F8:
//   main() resolves each once, fail-closed, and passes them in rather than having this
//   file resolve them again. Every other helper is reused from the module — the window
//   and evidence helpers (F-E2, Atom A), the operations time helpers (F-E1), the
//   timestamp diagnostic (F-E3) and isStandardActive (F-E5). Nothing was duplicated to
//   make the move possible.
//
// HOW THIS DIFFERS FROM gaps/mechanical, DESPITE THE SHARED SHAPE
//   The two walk the same standards with the same helpers, but they answer different
//   questions and must not be merged on the strength of looking alike:
//
//   - Pulse always evaluates TODAY in the operations zone. It takes no date and no lane
//     parameter, so it has no validation and no 400 path at all.
//   - Pulse counts rather than lists. It returns two numbers reduced to one colour, and
//     the standards it skips as decided-inactive are excluded from activeStandardsCount,
//     which is what makes "blue" mean "nothing active" rather than "nothing checked".
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
///   - apiV1: the gated `/api/v1` route group; gating is unchanged.
///   - operationsTimeZone: the zone resolved once in `main()`, fail-closed.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerOperationalPulseReadRoutes(
    on apiV1: MachineGatedRoutes,
    operationsTimeZone: TimeZone,
    storageDirectory: String
) {
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
                lane_key,
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
            let laneKey = try standard.decode(column: "lane_key", as: String.self)
            let createdAt = try standard.decode(column: "created_at", as: String.self)
            let evaluationTimestamp = iso8601Timestamp(dateString: pulseDate, hour: endHour)
            let standardWasActive = try await isStandardActive(
                standardID: standardID,
                at: evaluationTimestamp,
                createdAt: createdAt,
                sql: sql
            )

            // Same reading as gaps/mechanical, through the same two helpers: a false
            // from isStandardActive means "decided inactive" only when the standard's
            // governance fields were actually declared, or when a status decision was
            // recorded. Otherwise it means the sentinel lost a text comparison.
            let governanceFieldsDeclared = standardCreatedAtIsDeclared(createdAt)
            var activationResolved = governanceFieldsDeclared

            if !governanceFieldsDeclared {
                let statusDecisionRows = try await sql.raw(
                    standardStatusDecisionCountQuery(standardID: standardID, at: evaluationTimestamp)
                ).all()

                let statusDecisionCount = try statusDecisionRows[0].decode(column: "decisionCount", as: Int.self)
                activationResolved = statusDecisionCount > 0
            }

            guard activationResolved, standardWasActive else {
                if activationResolved {
                    print("Historical status resolution: standard inactive at pulse evaluation time — skipping \(standardKey)")
                } else {
                    // Counted on both sides on purpose. Leaving it out of
                    // activeStandardsCount is what previously let a legacy sentinel wash
                    // the board blue, and leaving it out of informationGapsCount would
                    // let it pass as green.
                    activeStandardsCount += 1
                    informationGapsCount += 1
                    print("Standard activation unresolved at pulse evaluation time: \(standardKey)")
                }
                continue
            }

            activeStandardsCount += 1

            // Same fail-closed rule and the same single window helper as gaps. Unlike
            // before Atom A the fault also counts as an information gap, so a window
            // that cannot be resolved can no longer contribute silently to green.
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
                informationGapsCount += 1
                continue
            }

            let evidenceRows = try await sql.raw(laneScopedObservationEvidenceQuery(bounds: windowBounds, laneKey: laneKey)).all()

            let evidence = try observationEvidenceTally(
                from: evidenceRows,
                storageDirectory: storageDirectory
            )

            if evidence.observedCount < requiredCount {
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
        print("trackEvaluable: false")
        print("sourceTag: [S]")

        let response = Response(status: .ok)
        try response.content.encode([
            "pulseState": pulseState,
            "sourceTag": "[S]"
        ])
        return response
    }
}
