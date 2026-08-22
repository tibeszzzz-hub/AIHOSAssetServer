import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Mechanical gap detection read route
//
// F-F8, extended by Atom A (WFOS-20260822-PSKS-004). `GET /api/v1/gaps/mechanical`
// reports what is known about every operational standard for a given operations day.
//
// WHAT CHANGED IN ATOM A, AND WHY IT IS NOT COSMETIC
//   The route used to return only the standards it had decided were failing. Everything
//   else — a standard skipped as inactive, a standard whose window could not be
//   resolved, a standard that was met — left no trace in the response at all. A client
//   receiving a short list could not tell "these three are missing and the rest are
//   fine" from "these three are missing and four more were never checked". Silence read
//   as health.
//
//   Now every standard the route processes leaves exactly one entry, carrying its own
//   status. Silence is no longer an answer the route can give.
//
//   Counting changed for the same reason. It used to be `COUNT(*)` over every record in
//   the window regardless of lane, and regardless of whether the payload behind the
//   record still existed. A recording in the bar could therefore close a kitchen
//   expectation, and a record whose file had vanished from storage still counted as a
//   fulfilled observation. Counting is now scoped to the standard's own lane, counts
//   each record once however many artefacts it carries, and requires the evidence to be
//   readable — with the records it could not verify reported separately rather than
//   folded into either answer.
//
// WHAT THIS ROUTE STILL CANNOT DO, AND SAYS SO
//   It cannot match a standard's track type against the records it counts. No relation
//   registers the form of an asset record, so the only available signal is a
//   client-supplied file name, which is unvalidated and may be absent or wrong. Rather
//   than guess, every entry carries `trackEvaluable: "false"`, and a standard whose own
//   `track_type` was never declared is reported as Unknown rather than measured.
//
// WHAT IS THREADED IN AND WHY
//   `operationsTimeZone` decides which day a hotel is asking about, and
//   `storageDirectory` decides whether a record's evidence can be read. Both are
//   resolved once in main(), fail-closed, and passed in rather than resolved again:
//   two lookups could disagree, and both of these decide what a client is told.
//   Everything else it uses is already module-level — the window and evidence helpers
//   (F-E2, Atom A), the operations time helpers (F-E1), the timestamp diagnostic (F-E3),
//   the lane allowlist and isStandardActive (F-E5). Nothing was duplicated.
//
// FOUR THINGS THAT ARE CONTRACT, NOT STYLE
//   The default date is today in the OPERATIONS zone, not UTC. A hotel working at 00:30
//   local is still asking about its own day, and computing that in UTC would silently
//   report the wrong one for part of every night.
//
//   Both refusals are fail-closed and both answer 400. An unknown lane is refused rather
//   than answered with an empty array, because an empty array reads as "nothing is
//   missing in that lane" — the most dangerous possible answer to a typo.
//
//   The two remaining skips are still two different skips, and each now emits an entry
//   before it continues. A standard whose activation cannot be resolved is Unknown; a
//   standard whose window cannot be resolved is Unknown for a different reason and is
//   still logged as a fault with metadata. Collapsing them would hide a configuration
//   error inside routine output.
//
//   `Missing expected observation` is reported only when the count falls short, no
//   leave-empty decision covers it, and nothing else about the standard is unresolved.
//   The wording is unchanged because clients match on it.
//
//   The parameter is named `apiV1` on purpose: the route manifest resolves a
//   registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `GET /api/v1/gaps/mechanical` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged.
///   - operationsTimeZone: the zone resolved once in `main()`, fail-closed.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerMechanicalGapReadRoutes(
    on apiV1: MachineGatedRoutes,
    operationsTimeZone: TimeZone,
    storageDirectory: String
) {
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

        // Fail closed on the lane filter, and reuse the standards allowlist rather than
        // the asset one: they are deliberately different sets and merging them would
        // silently widen both.
        let requestedLaneKey: String?

        if let rawLaneKey = req.query[String.self, at: "laneKey"] {
            guard let validatedLaneKey = validatedOperationalStandardLaneKey(rawLaneKey) else {
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "laneKey must be a known operational standard lane"
                ])
                return response
            }
            requestedLaneKey = validatedLaneKey
        } else {
            requestedLaneKey = nil
        }

        // COALESCE is what keeps this one query rather than two: with no lane requested
        // the bind is NULL and the predicate degrades to `lane_key = lane_key`, which
        // selects everything. The value is bound, never interpolated.
        let standards = try await sql.raw("""
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
            WHERE lane_key = COALESCE(\(bind: requestedLaneKey), lane_key)
            ORDER BY "standardKey" ASC
        """).all()

        var entries: [[String: String]] = []

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
            let laneKey = try standard.decode(column: "lane_key", as: String.self)
            let createdAt = try standard.decode(column: "created_at", as: String.self)
            let evaluationTimestamp = iso8601Timestamp(dateString: requestedDate, hour: endHour)

            // Built once so the three places that emit an entry cannot disagree about
            // what this standard is called or which window it covers.
            let context = MechanicalGapStandardContext(
                sourceTag: sourceTag,
                standardKey: standardKey,
                description: description,
                laneKey: laneKey,
                expectedDate: requestedDate,
                evaluationTimestamp: evaluationTimestamp,
                expectedWindow: String(format: "%02d:00-%02d:00", startHour, endHour),
                requiredCount: requiredCount,
                trackEvaluable: false
            )

            let standardWasActive = try await isStandardActive(
                standardID: standardID,
                at: evaluationTimestamp,
                createdAt: createdAt,
                sql: sql
            )

            // Two different answers hide behind that one Bool. On a row whose governance
            // fields were never declared, isStandardActive falls back to a text
            // comparison the legacy sentinel always loses, so a false there means
            // "cannot tell", not "retired". Only a recorded decision separates them.
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
                print("Standard not evaluated against a window at gap evaluation time: \(standardKey)")
                entries.append(mechanicalGapEntry(
                    context: context,
                    evidence: .empty,
                    outcome: mechanicalGapOutcome(MechanicalGapFacts(
                        activationResolved: activationResolved,
                        standardActive: standardWasActive,
                        windowResolved: true,
                        trackTypeDeclared: governanceFieldsDeclared,
                        requiredCount: requiredCount,
                        evidence: .empty,
                        leaveEmptyDecisionRecorded: false
                    ))
                ))
                continue
            }

            // Fail closed: a standard whose window cannot be resolved is reported as
            // unknown rather than evaluated against a half-built range. It is still
            // logged as a fault with metadata, because it is a configuration error and
            // not a routine outcome.
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
                entries.append(mechanicalGapEntry(
                    context: context,
                    evidence: .empty,
                    outcome: mechanicalGapOutcome(MechanicalGapFacts(
                        activationResolved: true,
                        standardActive: true,
                        windowResolved: false,
                        trackTypeDeclared: governanceFieldsDeclared,
                        requiredCount: requiredCount,
                        evidence: .empty,
                        leaveEmptyDecisionRecorded: false
                    ))
                ))
                continue
            }

            let evidenceRows = try await sql.raw(laneScopedObservationEvidenceQuery(bounds: windowBounds, laneKey: laneKey)).all()

            let evidence = try observationEvidenceTally(
                from: evidenceRows,
                storageDirectory: storageDirectory
            )

            var leaveEmptyDecisionRecorded = false

            // The decision query runs only once the count is already short: a standard
            // that was met needs no excuse for being met.
            if evidence.observedCount < requiredCount {
                let decisionRows = try await sql.raw(
                    leaveEmptyDecisionCountQuery(
                        standardKey: standardKey,
                        localDate: requestedDate,
                        startHour: startHour,
                        endHour: endHour
                    )
                ).all()

                let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)
                leaveEmptyDecisionRecorded = decisionCount > 0
            }

            entries.append(mechanicalGapEntry(
                context: context,
                evidence: evidence,
                outcome: mechanicalGapOutcome(MechanicalGapFacts(
                    activationResolved: true,
                    standardActive: true,
                    windowResolved: true,
                    trackTypeDeclared: governanceFieldsDeclared,
                    requiredCount: requiredCount,
                    evidence: evidence,
                    leaveEmptyDecisionRecorded: leaveEmptyDecisionRecorded
                ))
            ))
        }

        print("Mechanical gap detection PASS: \(entries.count) standards evaluated")
        print("trackEvaluable: false")

        let response = Response(status: .ok)
        try response.content.encode(entries)
        return response
    }
}
