import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Operational standard status timeline read route
//
// F-F3, the third route group lifted out of the composition root. Same selection rule
// as F-F1 and F-F2: the smallest remaining read-only group, and one that needs nothing
// from main()'s local scope. Its database handle comes from the request (`req.db`),
// its response type already lives in APIContentDTOs.swift, and its only parameter is
// the route group itself.
//
// Only the read side moved. `POST /api/v1/standards` and
// `PATCH /api/v1/standards/:standardID/status` write, and writes remain in the
// composition root, so the file name says "read".
//
// The ascending sort is the contract this route exists to serve: a status timeline
// read newest-first would reverse the history a reader is trying to follow. It is
// pinned in the tests rather than left to be inferred from the SQL.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name, so that name
// keeps the signature spelled GET /api/v1/standards/:standardID/status-updates.

/// Registers `GET /api/v1/standards/:standardID/status-updates` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerStandardStatusTimelineReadRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.get("standards", ":standardID", "status-updates") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        guard let standardIDString = req.parameters.get("standardID"),
              let standardID = UUID(uuidString: standardIDString) else {
            print("Standard Status Timeline retrieval failed: invalid standardID")
            let response = Response(status: .badRequest)
            try response.content.encode([
                "reason": "invalid operational standard id"
            ])
            return response
        }

        let rows = try await sql.raw("""
            SELECT
                id,
                standard_id,
                status,
                source_tag,
                changed_at
            FROM standard_status_updates
            WHERE standard_id = \(bind: standardID)
            ORDER BY changed_at ASC
        """).all()

        let updates = try rows.map { row -> StandardStatusUpdateResponse in
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let standardID = try row.decode(column: "standard_id", as: UUID.self).uuidString
            let status = try row.decode(column: "status", as: String.self)
            let sourceTag = try row.decode(column: "source_tag", as: String.self)
            let changedAt = try row.decode(column: "changed_at", as: String.self)

            return StandardStatusUpdateResponse(
                id: id,
                standardID: standardID,
                status: status,
                sourceTag: sourceTag,
                changedAt: changedAt
            )
        }

        print("Standard Status Timeline retrieval PASS: \(updates.count) updates")
        print("standardID: \(standardID.uuidString)")
        print("Status Timeline sort: changed_at ASC")

        let response = Response(status: .ok)
        try response.content.encode(updates)
        return response
    }
}
