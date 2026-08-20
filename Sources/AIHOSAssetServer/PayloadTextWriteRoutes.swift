import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Payload text write route
//
// F-G4. `POST /api/v1/assets/:assetID/payload-text` stores a text representation of an
// existing observation — a transcription, a reading, an interpretation — alongside the
// original media without altering it.
//
// This is the write half of the resource whose read half moved in F-F2. They live in
// two files rather than one because they were extracted under separate orders and the
// read file is named for exactly what it holds; merging them would be a rename and a
// broader change than either atom asked for.
//
// WHAT IT DEPENDS ON
//   Nothing from main()'s local scope. The database handle comes from the request, and
//   PayloadTextRequest and PayloadTextResponse already live in APIContentDTOs.swift.
//
// FOUR THINGS THAT ARE CONTRACT
//   Three refusals, each with its own status and its own reason: a malformed asset id
//   is 400, an undecodable body is 400, and an asset that does not exist is 404. The
//   existence check runs before the insert, so a payload can never be attached to an
//   asset that is not there — collapsing it would leave orphan rows behind.
//
//   The original asset is never touched. This route only inserts into
//   asset_payload_texts, and the log says so explicitly: the payload text is a
//   subordinate representation, not an edit of the observation.
//
//   The response echoes the row that was written, including the server-generated id and
//   timestamp, so the caller need not read it back.
//
//   `createdAt` is generated here, not taken from the request. A caller-supplied
//   timestamp would let the record claim a time it did not happen at.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/assets/:assetID/payload-text` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerPayloadTextWriteRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.post("assets", ":assetID", "payload-text") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        guard let assetIDString = req.parameters.get("assetID"),
              let assetID = UUID(uuidString: assetIDString) else {
            print("Payload Text INSERT failed: invalid assetID")
            return Response(status: .badRequest)
        }

        let payload: PayloadTextRequest

        do {
            payload = try req.content.decode(PayloadTextRequest.self)
        } catch {
            print("Payload Text decode failed: \(error)")
            return Response(status: .badRequest)
        }

        let assetRows = try await sql.raw("""
            SELECT id
            FROM asset_records
            WHERE id = \(bind: assetID)
        """).all()

        guard assetRows.count == 1 else {
            print("Payload Text INSERT failed: asset not found \(assetID.uuidString)")
            return Response(status: .notFound)
        }

        let payloadTextID = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())

        do {
            try await sql.raw("""
                INSERT INTO asset_payload_texts
                (id, "assetRecordID", payload_text, source_tag, created_at)
                VALUES
                (\(bind: payloadTextID), \(bind: assetID), \(bind: payload.payloadText), \(bind: payload.sourceTag), \(bind: createdAt));
            """).run()
        } catch {
            print("Payload Text INSERT failed: \(error)")
            return Response(status: .internalServerError)
        }

        print("Payload Text INSERT PASS")
        print("assetRecordID: \(assetID.uuidString)")
        print("payloadTextID: \(payloadTextID.uuidString)")
        print("sourceTag: \(payload.sourceTag)")
        print("createdAt: \(createdAt)")
        print("Source Awareness: original asset unchanged; payload_text stored as subordinate representation")

        let response = Response(status: .ok)
        try response.content.encode(
            PayloadTextResponse(
                id: payloadTextID.uuidString,
                assetRecordID: assetID.uuidString,
                payloadText: payload.payloadText,
                sourceTag: payload.sourceTag,
                createdAt: createdAt
            )
        )
        return response
    }
}
