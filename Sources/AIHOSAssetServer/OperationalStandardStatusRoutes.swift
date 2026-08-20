import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Operational standard status update route
//
// F-G8. `PATCH /api/v1/standards/:standardID/status` pauses or reactivates a standard.
// It is the only route in the server that updates an existing row, and the only one
// that runs inside an explicit transaction — both for the same reason.
//
// Chosen over /test/vision-ocr and the transcribe-audio route, which are shorter but
// reach the Vision framework, the Speech framework, the file system and the storage
// directory. This route is pure SQL with nothing threaded through.
//
// WHY IT IS STATUS-ONLY, AND WHY THAT IS ENFORCED BY REJECTION
//   Standards are append-only in every other respect: what a standard expects can never
//   be edited, only superseded by a new standard. Status is the single exception,
//   because pausing a standard is not rewriting history — it is recording that the
//   expectation no longer applies from now on.
//
//   The request type carries the other fields as optionals purely so their presence can
//   be DETECTED and refused. A caller that sends laneKey or requiredCount is answered
//   400 with an explicit reason rather than having the field quietly ignored, which
//   would leave them believing an edit had been applied.
//
// WHY THE TRANSACTION IS LOAD-BEARING
//   Two statements must both happen or neither: the row's status changes, and a row is
//   appended to standard_status_updates recording the transition. If only the first
//   succeeded, the standard's history would show a state it never transitioned into,
//   and isStandardActive — which resolves historical status from that very table —
//   would answer from an incomplete record. Splitting these into two independent
//   statements would compile and would corrupt the timeline only under failure.
//
// THE READ-BACK IS DELIBERATE
//   The response is built from a fresh SELECT rather than from the request, so what the
//   caller receives is what the database actually holds.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `PATCH /api/v1/standards/:standardID/status` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerOperationalStandardStatusRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.on(.PATCH, "standards", ":standardID", "status") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        guard let standardIDString = req.parameters.get("standardID"),
              let standardID = UUID(uuidString: standardIDString) else {
            print("Operational Standard status update failed: invalid standardID")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "invalid operational standard id"
            ])
            return response
        }

        let payload: OperationalStandardStatusUpdateRequest

        do {
            payload = try req.content.decode(OperationalStandardStatusUpdateRequest.self)
        } catch {
            print("Operational Standard status update failed: payload decode error \(error)")
            return Response(status: .badRequest)
        }

        if payload.standardKey != nil
            || payload.laneKey != nil
            || payload.trackType != nil
            || payload.expectedWindowStart != nil
            || payload.expectedWindowEnd != nil
            || payload.requiredCount != nil
            || payload.createdAt != nil {
            print("Operational Standard status update blocked: core metadata mutation attempted")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "Mutation of core metadata is not allowed."
            ])
            return response
        }

        guard payload.status == "ACTIVE" || payload.status == "PAUSED" else {
            print("Operational Standard status update failed: invalid status \(payload.status)")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "status must be ACTIVE or PAUSED"
            ])
            return response
        }

        let existingRows = try await sql.raw("""
            SELECT id
            FROM operational_standards
            WHERE id = \(bind: standardID)
        """).all()

        guard existingRows.count == 1 else {
            print("Operational Standard status update failed: standard not found \(standardID.uuidString)")
            return Response(status: .notFound)
        }

        let statusUpdateID = UUID()
        let changedAt = ISO8601DateFormatter().string(from: Date())
        let statusSourceTag = "[M]"

        do {
            try await req.db.transaction { database in
                guard let transactionSQL = database as? SQLDatabase else {
                    throw Abort(.internalServerError, reason: "SQL database unavailable inside status update transaction")
                }

                try await transactionSQL.raw("""
                    UPDATE operational_standards
                    SET status = \(bind: payload.status)
                    WHERE id = \(bind: standardID)
                """).run()

                try await transactionSQL.raw("""
                    INSERT INTO standard_status_updates
                    (id, standard_id, status, source_tag, changed_at)
                    VALUES
                    (\(bind: statusUpdateID), \(bind: standardID), \(bind: payload.status), \(bind: statusSourceTag), \(bind: changedAt));
                """).run()
            }
        } catch {
            print("Operational Standard status update failed: \(error)")
            return Response(status: .internalServerError)
        }

        let updatedRows = try await sql.raw("""
            SELECT
                id,
                "standardKey",
                lane_key,
                track_type,
                expected_window_start,
                expected_window_end,
                "requiredCount",
                status,
                created_at
            FROM operational_standards
            WHERE id = \(bind: standardID)
            LIMIT 1
        """).all()

        guard updatedRows.count == 1 else {
            print("Operational Standard status update failed: updated row missing \(standardID.uuidString)")
            return Response(status: .internalServerError)
        }

        let row = updatedRows[0]
        let id = try row.decode(column: "id", as: UUID.self).uuidString
        let standardKey = try row.decode(column: "standardKey", as: String.self)
        let laneKey = try row.decode(column: "lane_key", as: String.self)
        let trackType = try row.decode(column: "track_type", as: String.self)
        let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
        let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
        let requiredCount = try row.decode(column: "requiredCount", as: Int.self)
        let status = try row.decode(column: "status", as: String.self)
        let createdAt = try row.decode(column: "created_at", as: String.self)

        print("Operational Standard status update PASS")
        print("standardID: \(standardID.uuidString)")
        print("status: \(status)")
        print("statusUpdateID: \(statusUpdateID.uuidString)")
        print("sourceTag: \(statusSourceTag)")
        print("changedAt: \(changedAt)")
        print("Governance: status-only update; core metadata unchanged")
        print("Status Timeline: transition inserted append-only")

        let response = Response(status: .ok)
        try response.content.encode(
            OperationalStandardResponse(
                id: id,
                standardKey: standardKey,
                laneKey: laneKey,
                trackType: trackType,
                expectedWindowStart: expectedWindowStart,
                expectedWindowEnd: expectedWindowEnd,
                requiredCount: requiredCount,
                status: status,
                createdAt: createdAt
            )
        )
        return response
    }
}
