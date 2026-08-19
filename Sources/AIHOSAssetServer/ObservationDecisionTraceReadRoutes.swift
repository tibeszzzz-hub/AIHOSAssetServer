import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Observation decision trace read route
//
// F-F5, the fifth route group lifted out of the composition root. Same selection rule
// as F-F1 through F-F4: the smallest remaining read-only group needing nothing from
// main()'s local scope. The database handle comes from the request (`req.db`),
// ObservationDecisionTraceResponse already lives in APIContentDTOs.swift, and the
// registrar takes a single parameter.
//
// Only the read side moved. `POST /api/v1/assets/:assetID/decision-traces` writes and
// stays in the composition root, which is why the file name says "read".
//
// This route issues TWO queries, and the order between them is the contract. It first
// checks that the asset record exists and answers 404 if it does not; only then does it
// read the traces. Collapsing that into a single query would turn "unknown asset" into
// an empty list, which is a different answer to a different question. The existence
// check and the 404 are pinned in the tests for that reason.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name, so that name
// keeps the signature spelled GET /api/v1/assets/:assetID/decision-traces.

/// Registers `GET /api/v1/assets/:assetID/decision-traces` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerObservationDecisionTraceReadRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.get("assets", ":assetID", "decision-traces") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        guard let assetIDString = req.parameters.get("assetID"),
              let assetID = UUID(uuidString: assetIDString) else {
            print("Observation Decision Trace retrieval failed: invalid assetID")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "invalid asset id"
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
            print("Observation Decision Trace retrieval failed: asset not found \(assetID.uuidString)")
            return Response(status: .notFound)
        }

        let rows = try await sql.raw("""
            SELECT
                id,
                target_asset_record_id,
                "decision_type",
                "source_tag",
                "created_at"
            FROM decision_traces
            WHERE target_asset_record_id = \(bind: assetID)
            ORDER BY "created_at" ASC
        """).all()

        let decisionTraces = try rows.map { row -> ObservationDecisionTraceResponse in
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let targetAssetRecordID = try row.decode(column: "target_asset_record_id", as: UUID.self).uuidString
            let decisionType = try row.decode(column: "decision_type", as: String.self)
            let sourceTag = try row.decode(column: "source_tag", as: String.self)
            let createdAt = try row.decode(column: "created_at", as: String.self)

            return ObservationDecisionTraceResponse(
                id: id,
                targetAssetRecordID: targetAssetRecordID,
                decisionType: decisionType,
                sourceTag: sourceTag,
                createdAt: createdAt
            )
        }

        print("Observation Decision Trace retrieval PASS: \(decisionTraces.count) traces")
        print("targetAssetRecordID: \(assetID.uuidString)")
        print("Observation Decision Trace sort: created_at ASC")

        let response = Response(status: .ok)
        try response.content.encode(decisionTraces)
        return response
    }
}
