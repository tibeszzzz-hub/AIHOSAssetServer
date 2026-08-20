import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Decision trace fixation route
//
// F-G5. `POST /api/v1/decisions` records that a human deliberately left an expected
// observation window empty. It is the counterpart to the gap calculations: a standard
// whose window is empty is a gap, unless a decision like this one says otherwise.
//
// WHAT IT DEPENDS ON
//   Nothing from main()'s local scope. The database handle comes from the request and
//   DecisionPayload lives in APIContentDTOs.swift, so the registrar takes only the
//   route group. Note that it needs no time zone: the window bounds arrive in the
//   request and are stored as given, and `createdAt` is a UTC instant.
//
// FOUR THINGS THAT ARE CONTRACT
//   The decision type is an allowlist of exactly one. Anything other than
//   "leave_empty" is refused with 400 rather than stored, so an unrecognised decision
//   can never enter the record as if it were understood. Widening this to accept what
//   arrives would compile and would let the gap calculations be silenced by a value
//   nobody defined.
//
//   Three of the stored fields are decided here, not by the caller: the source tag is
//   always "[M]", the lane key is always "unassigned", and createdAt is generated
//   server-side. A caller-supplied source tag would let a machine decision claim to be
//   a human one; a caller-supplied timestamp would let it claim a time it did not
//   happen at.
//
//   The window bounds are stored exactly as received. This route does not interpret or
//   normalise them — the gap and pulse calculations match on them verbatim, so any
//   reshaping here would silently stop suppressing the gap it was meant to suppress.
//
//   The response echoes every stored field, so the caller need not read the row back.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/decisions` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerDecisionTraceFixationRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.post("decisions") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        let payload: DecisionPayload

        do {
            payload = try req.content.decode(DecisionPayload.self)
        } catch {
            print("Decision payload decode failed: \(error)")
            return Response(status: .badRequest)
        }

        guard payload.decisionType == "leave_empty" else {
            print("Decision rejected: unsupported decisionType \(payload.decisionType)")
            return Response(status: .badRequest)
        }

        let decisionID = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let sourceTag = "[M]"
        let inheritedLaneKey = "unassigned"

        do {
            try await sql.raw("""
                INSERT INTO decision_traces
                (id, "standard_key", "expected_window_start", "expected_window_end", "decision_type", "source_tag", "created_at", lane_key)
                VALUES
                (\(bind: decisionID), \(bind: payload.standardKey), \(bind: payload.expectedWindowStart), \(bind: payload.expectedWindowEnd), \(bind: payload.decisionType), \(bind: sourceTag), \(bind: createdAt), \(bind: inheritedLaneKey));
            """).run()
        } catch {
            print("Decision Trace INSERT failed: \(error)")
            return Response(status: .internalServerError)
        }

        print("Decision Trace fixation PASS")
        print("decisionID: \(decisionID.uuidString)")
        print("standardKey: \(payload.standardKey)")
        print("expectedWindowStart: \(payload.expectedWindowStart)")
        print("expectedWindowEnd: \(payload.expectedWindowEnd)")
        print("decisionType: \(payload.decisionType)")
        print("sourceTag: \(sourceTag)")
        print("createdAt: \(createdAt)")
        print("laneKey: \(inheritedLaneKey)")

        let response = Response(status: .ok)
        try response.content.encode([
            "id": decisionID.uuidString,
            "sourceTag": sourceTag,
            "decisionType": payload.decisionType,
            "standardKey": payload.standardKey,
            "expectedWindowStart": payload.expectedWindowStart,
            "expectedWindowEnd": payload.expectedWindowEnd,
            "createdAt": createdAt,
            "laneKey": inheritedLaneKey
        ])
        return response
    }
}
