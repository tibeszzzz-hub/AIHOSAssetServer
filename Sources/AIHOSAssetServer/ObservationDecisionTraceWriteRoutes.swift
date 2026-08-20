import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Observation decision trace write route
//
// F-G6. `POST /api/v1/assets/:assetID/decision-traces` records that a human handled a
// specific observation. It is the write half of the resource whose read half moved in
// F-F5, and the observation-scoped sibling of the standard-scoped decision written by
// POST /api/v1/decisions (F-G5).
//
// WHY THIS ROUTE AND NOT THE SMALLER ONE
//   /test/vision-ocr is five lines shorter but reaches the Vision framework and the
//   storage directory, and is compiled conditionally. This one is pure SQL with nothing
//   threaded through, so it is the lower-risk move even though it is slightly larger.
//
// TWO DECISION TYPES, ONE TABLE, AND THE COLUMN THAT TELLS THEM APART
//   Both this route and the standard-scoped one insert into `decision_traces`. They are
//   distinguished by which columns they fill: this one sets target_asset_record_id and
//   writes NULL into standard_key and both window bounds; the other does the reverse. A
//   database check constraint enforces that exactly one target is present, so filling
//   in both — or neither — is rejected by the database rather than silently stored.
//
//   The explicit NULLs are therefore contract, not noise. They are what make this row
//   an observation decision, and the handover log reads that same column to choose
//   which message shape to render.
//
// THREE REFUSALS, EACH WITH ITS OWN BODY
//   A malformed asset id and an unsupported decision type both answer 400 but with
//   different `reason` values a client can act on; an unknown asset answers 404. The
//   asset existence check runs before the insert, so a decision can never point at an
//   observation that is not there.
//
//   `decisionType` is an allowlist of exactly one — "handled" — and the source tag and
//   timestamp are decided here, not by the caller.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/assets/:assetID/decision-traces` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerObservationDecisionTraceWriteRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.post("assets", ":assetID", "decision-traces") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        guard let assetIDString = req.parameters.get("assetID"),
              let assetID = UUID(uuidString: assetIDString) else {
            print("Observation Decision Trace INSERT failed: invalid assetID")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "invalid asset id"
            ])
            return response
        }

        let payload: ObservationDecisionPayload

        do {
            payload = try req.content.decode(ObservationDecisionPayload.self)
        } catch {
            print("Observation Decision Trace decode failed: \(error)")
            return Response(status: .badRequest)
        }

        guard payload.decisionType == "handled" else {
            print("Observation Decision Trace rejected: invalid decisionType \(payload.decisionType)")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "decisionType must be handled"
            ])
            return response
        }

        let assetRows = try await sql.raw("""
            SELECT id
            FROM asset_records
            WHERE id = \(bind: assetID)
            LIMIT 1
        """).all()

        guard assetRows.count == 1 else {
            print("Observation Decision Trace INSERT failed: asset not found \(assetID.uuidString)")
            return Response(status: .notFound)
        }

        let decisionTraceID = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let sourceTag = "[M]"

        do {
            try await sql.raw("""
                INSERT INTO decision_traces
                (id, "standard_key", "expected_window_start", "expected_window_end", target_asset_record_id, "decision_type", "source_tag", "created_at")
                VALUES
                (\(bind: decisionTraceID), NULL, NULL, NULL, \(bind: assetID), \(bind: payload.decisionType), \(bind: sourceTag), \(bind: createdAt));
            """).run()
        } catch {
            print("Observation Decision Trace INSERT failed: \(error)")
            return Response(status: .internalServerError)
        }

        print("Observation Decision Trace INSERT PASS")
        print("decisionTraceID: \(decisionTraceID.uuidString)")
        print("targetAssetRecordID: \(assetID.uuidString)")
        print("decisionType: \(payload.decisionType)")
        print("sourceTag: \(sourceTag)")
        print("createdAt: \(createdAt)")
        print("Governance: observation decision trace inserted append-only; standard_key remains NULL")

        let response = Response(status: .ok)
        try response.content.encode(
            ObservationDecisionTraceResponse(
                id: decisionTraceID.uuidString,
                targetAssetRecordID: assetID.uuidString,
                decisionType: payload.decisionType,
                sourceTag: sourceTag,
                createdAt: createdAt
            )
        )
        return response
    }
}
