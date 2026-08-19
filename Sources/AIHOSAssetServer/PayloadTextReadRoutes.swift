import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Payload text read route
//
// F-F2, the second route group lifted out of the composition root. Chosen for the
// same reason as F-F1: it is the smallest remaining read-only group and it needs
// nothing at all from main()'s local scope. Its database handle comes from the
// request (`req.db`), its response type already lives in APIContentDTOs.swift, and
// its only parameter is the route group itself.
//
// Only the read side moved. `POST /api/v1/assets/:assetID/payload-text` writes, and
// writes are out of scope for this extraction, so the resource is deliberately split
// across two files for now. The file name says "read" so that split is stated rather
// than discovered.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name, so that name
// keeps the signature spelled GET /api/v1/assets/:assetID/payload-text.

/// Registers `GET /api/v1/assets/:assetID/payload-text` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerPayloadTextReadRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.get("assets", ":assetID", "payload-text") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        guard let assetIDString = req.parameters.get("assetID"),
              let assetID = UUID(uuidString: assetIDString) else {
            print("Payload Text retrieval failed: invalid assetID")
            return Response(status: .badRequest)
        }

        let rows = try await sql.raw("""
            SELECT
                id,
                "assetRecordID",
                payload_text,
                source_tag,
                created_at
            FROM asset_payload_texts
            WHERE "assetRecordID" = \(bind: assetID)
            ORDER BY created_at ASC
        """).all()

        let payloadTexts = try rows.map { row -> PayloadTextResponse in
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let assetRecordID = try row.decode(column: "assetRecordID", as: UUID.self).uuidString
            let payloadText = try row.decode(column: "payload_text", as: String?.self)
            let sourceTag = try row.decode(column: "source_tag", as: String.self)
            let createdAt = try row.decode(column: "created_at", as: String.self)

            return PayloadTextResponse(
                id: id,
                assetRecordID: assetRecordID,
                payloadText: payloadText,
                sourceTag: sourceTag,
                createdAt: createdAt
            )
        }

        print("Payload Text retrieval PASS: \(payloadTexts.count) entries")
        print("Source Awareness: payload_text returned separately from original asset media")

        let response = Response(status: .ok)
        try response.content.encode(payloadTexts)
        return response
    }
}
