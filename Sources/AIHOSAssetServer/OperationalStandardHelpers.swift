import Vapor
import SQLKit
import Foundation

func isStandardActive(
    standardID: UUID,
    at evaluationTimestamp: String,
    createdAt: String,
    sql: SQLDatabase
) async throws -> Bool {
    let statusRows = try await sql.raw("""
        SELECT status
        FROM standard_status_updates
        WHERE standard_id = \(bind: standardID)
          AND changed_at <= \(bind: evaluationTimestamp)
        ORDER BY changed_at DESC
        LIMIT 1
    """).all()

    if let statusRow = statusRows.first {
        let historicalStatus = try statusRow.decode(column: "status", as: String.self)
        return historicalStatus == "ACTIVE"
    }

    return createdAt <= evaluationTimestamp
}
