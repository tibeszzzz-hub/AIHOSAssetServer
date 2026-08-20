import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Shift handover log read route
//
// F-F7. The handover log is the one read that merges two unrelated tables into a
// single chronological stream: observation records and decision traces. Neither query
// orders in SQL, because ordering across two result sets can only happen after they
// are merged — the Swift comparator at the end is the entire ordering contract for
// this route, not a refinement of a database sort.
//
// WHAT IT DEPENDS ON
//   Nothing from main()'s local scope. The database handle comes from the request,
//   `parsedTimestampDate` is a module-level helper (F-C2), and ShiftHandoverLogEntry
//   already lives in APIContentDTOs.swift (F-C1). The registrar therefore takes only
//   the route group.
//
// THREE THINGS THAT ARE CONTRACT, NOT STYLE
//   The lane fallback: a decision trace with no lane of its own borrows the lane of the
//   asset it targets, and failing that reads "unassigned". Losing the COALESCE would
//   make the column nullable and break the non-optional decode below it.
//
//   The three message shapes: a trace bound to an asset, a trace bound to a standard
//   and window, and an unresolved one. They are what an operator reads at handover, and
//   the order of the branches decides which one wins when both are present.
//
//   The nullable decodes: standard_key, the two window bounds and the target id are all
//   optional in the projection. Decoding any of them non-optionally would compile and
//   fail at runtime against rows that legitimately lack them.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name, so that name
// keeps the signature spelled GET /api/v1/shift-handover/log.

/// Registers `GET /api/v1/shift-handover/log` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerShiftHandoverReadRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.get("shift-handover", "log") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        let observationRows = try await sql.raw("""
            SELECT
                asset_records.id,
                asset_records."captureTimestamp",
                asset_records."sourceTag",
                asset_records.lane_key,
                asset_files."fileName"
            FROM asset_records
            INNER JOIN asset_files
                ON asset_files."assetRecordID" = asset_records.id
        """).all()

        var logEntries: [ShiftHandoverLogEntry] = []

        for row in observationRows {
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let captureTimestamp = try row.decode(column: "captureTimestamp", as: String.self)
            let sourceTag = try row.decode(column: "sourceTag", as: String.self)
            let laneKey = try row.decode(column: "lane_key", as: String.self)
            let fileName = try row.decode(column: "fileName", as: String.self)

            logEntries.append(
                ShiftHandoverLogEntry(
                    id: id,
                    sourceTag: sourceTag,
                    eventTimestamp: captureTimestamp,
                    entryType: "Observation Record",
                    message: "Observation record: \(fileName)",
                    laneKey: laneKey
                )
            )
        }

        let decisionRows = try await sql.raw("""
            SELECT
                decision_traces.id,
                decision_traces."standard_key",
                decision_traces."expected_window_start",
                decision_traces."expected_window_end",
                decision_traces.target_asset_record_id,
                decision_traces."decision_type",
                decision_traces."source_tag",
                decision_traces."created_at",
                COALESCE(decision_traces.lane_key, asset_records.lane_key, 'unassigned') AS lane_key
            FROM decision_traces
            LEFT JOIN asset_records
                ON asset_records.id = decision_traces.target_asset_record_id
        """).all()

        for row in decisionRows {
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let standardKey = try row.decode(column: "standard_key", as: String?.self)
            let expectedWindowStart = try row.decode(column: "expected_window_start", as: String?.self)
            let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String?.self)
            let targetAssetRecordID = try row.decode(column: "target_asset_record_id", as: UUID?.self)
            let decisionType = try row.decode(column: "decision_type", as: String.self)
            let sourceTag = try row.decode(column: "source_tag", as: String.self)
            let createdAt = try row.decode(column: "created_at", as: String.self)
            let laneKey = try row.decode(column: "lane_key", as: String.self)

            let message: String
            if let targetAssetRecordID {
                message = "Observation decision trace: \(decisionType) — asset \(targetAssetRecordID.uuidString)"
            } else if let standardKey, let expectedWindowStart, let expectedWindowEnd {
                message = "Decision trace: \(decisionType) — \(standardKey) — \(expectedWindowStart) to \(expectedWindowEnd)"
            } else {
                message = "Decision trace: \(decisionType) — unresolved target"
            }

            logEntries.append(
                ShiftHandoverLogEntry(
                    id: id,
                    sourceTag: sourceTag,
                    eventTimestamp: createdAt,
                    entryType: "Decision Trace",
                    message: message,
                    laneKey: laneKey
                )
            )
        }

        logEntries.sort { first, second in
            let firstDate = parsedTimestampDate(first.eventTimestamp) ?? Date.distantPast
            let secondDate = parsedTimestampDate(second.eventTimestamp) ?? Date.distantPast
            return firstDate > secondDate
        }

        let response = Response(status: .ok)
        try response.content.encode(logEntries)
        return response
    }
}
