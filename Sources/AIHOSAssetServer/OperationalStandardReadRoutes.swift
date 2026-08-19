import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Operational standards read route
//
// F-F4, the fourth route group lifted out of the composition root. Same selection rule
// as F-F1 through F-F3: the smallest remaining read-only group with nothing needed from
// main()'s local scope. The database handle comes from the request (`req.db`),
// OperationalStandardResponse already lives in APIContentDTOs.swift, and the registrar
// takes a single parameter.
//
// Only the read side moved. `POST /api/v1/standards` creates a standard and
// `PATCH /api/v1/standards/:standardID/status` changes it; both are writes and stay in
// the composition root, which is why the file name says "read".
//
// The projection is the lane contract as clients see it: standardKey, lane_key,
// track_type and the expected window are what a caller uses to decide which standard a
// reading belongs to. Dropping or renaming a column here would compile and silently
// change the API, so the nine columns are pinned in the tests.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name, so that name
// keeps the signature spelled GET /api/v1/standards.

/// Registers `GET /api/v1/standards` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerOperationalStandardReadRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.get("standards") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        let rows = try await sql.raw("""
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
            ORDER BY created_at ASC
        """).all()

        let standards = try rows.map { row -> OperationalStandardResponse in
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let standardKey = try row.decode(column: "standardKey", as: String.self)
            let laneKey = try row.decode(column: "lane_key", as: String.self)
            let trackType = try row.decode(column: "track_type", as: String.self)
            let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
            let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
            let requiredCount = try row.decode(column: "requiredCount", as: Int.self)
            let status = try row.decode(column: "status", as: String.self)
            let createdAt = try row.decode(column: "created_at", as: String.self)

            return OperationalStandardResponse(
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
        }

        print("Operational Standards retrieval PASS: \(standards.count) standards")
        print("Operational Standards sort: createdAt ASC")
        print("Operational Standards source: server-side operational_standards")

        let response = Response(status: .ok)
        try response.content.encode(standards)
        return response
    }
}
