import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Observation records read route
//
// F-F6, the sixth route group lifted out of the composition root and the first one
// that needs a value threaded through from main(). It reads asset records joined to
// their files, drops rows whose payload file is missing from disk, groups the rest by
// observation, and presents them newest-first.
//
// WHAT IS THREADED IN AND WHY
//   `storageDirectory` is the validated storage root that main() resolves once,
//   fail-closed. It is passed as a parameter rather than resolved again here: a second
//   lookup could disagree with the first, and this route uses it to decide whether a
//   record is returned at all. `parsedTimestampDate` and `humanReadableTimestamp` are
//   module-level helpers and need no threading.
//
// TWO PROPERTIES THAT LOOK REDUNDANT AND ARE NOT
//   The SQL sorts ascending and the Swift comparator then re-sorts descending. That is
//   not a leftover: the ascending read makes grouping deterministic, and the descending
//   presentation is what the client sees. Removing either one changes a client-visible
//   list while still compiling.
//
//   The file integrity filter is a filter, not a diagnostic. A record whose payload
//   file is missing is skipped rather than returned with a broken reference, and the
//   skipped count is logged. Turning the `continue` into a warning would silently start
//   serving records that point at nothing.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name, so that name
// keeps the signature spelled GET /api/v1/records.

/// Registers `GET /api/v1/records` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerObservationRecordReadRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {
    apiV1.get("records") { req async throws -> Response in
        let sql = req.db as! SQLDatabase

        let rows = try await sql.raw("""
            SELECT
                asset_records.id,
                asset_records."captureTimestamp",
                asset_records."sourceTag",
                asset_records.lane_key,
                asset_files."fileName"
            FROM asset_records
            INNER JOIN asset_files
                ON asset_files."assetRecordID" = asset_records.id
            ORDER BY asset_records."captureTimestamp" ASC
        """).all()


        var groupOrder: [String] = []
        var groupsByID: [String: GroupedObservationResponse] = [:]
        var missingFileCount = 0

        for row in rows {
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let captureTimestamp = try row.decode(column: "captureTimestamp", as: String.self)
            let sourceTag = try row.decode(column: "sourceTag", as: String.self)
            let laneKey = try row.decode(column: "lane_key", as: String.self)
            let fileName = try row.decode(column: "fileName", as: String.self)
            let filePath = storageDirectory + "/" + fileName

            guard FileManager.default.fileExists(atPath: filePath) else {
                missingFileCount += 1
                print("Observation retrieval skipped missing payload file: \(fileName)")
                continue
            }

            if let existing = groupsByID[id] {
                groupsByID[id] = GroupedObservationResponse(
                    id: existing.id,
                    captureTimestamp: existing.captureTimestamp,
                    displayTimestamp: existing.displayTimestamp,
                    sourceTag: existing.sourceTag,
                    laneKey: existing.laneKey,
                    files: existing.files + [fileName]
                )
            } else {
                groupOrder.append(id)
                groupsByID[id] = GroupedObservationResponse(
                    id: id,
                    captureTimestamp: captureTimestamp,
                    displayTimestamp: humanReadableTimestamp(captureTimestamp),
                    sourceTag: sourceTag,
                    laneKey: laneKey,
                    files: [fileName]
                )
            }
        }

        var records: [GroupedObservationResponse] = groupOrder.compactMap { groupsByID[$0] }

        print("Observation retrieval file integrity filter PASS")
        print("Observation records returned: \(records.count)")
        print("Observation records skipped missing files: \(missingFileCount)")

        records.sort { first, second in
            let firstDate = parsedTimestampDate(first.captureTimestamp) ?? Date.distantPast
            let secondDate = parsedTimestampDate(second.captureTimestamp) ?? Date.distantPast
            return firstDate > secondDate
        }

        let response = Response(status: .ok)
        try response.content.encode(records)
        return response
    }
}
