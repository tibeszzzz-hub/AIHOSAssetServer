import Vapor
import SQLKit

// MARK: - Timestamp read-expectation diagnostic
//
// `asset_records."captureTimestamp"` is stored in the canonical AIHOS format: a
// 10-digit Unix epoch in seconds, UTC (WFOS-20260817-NBPS-001). Those rows are
// correct, current data — they are neither legacy nor invalid, and nothing here
// describes them as such.
//
// The gap and pulse calculations read those rows directly as epoch since A1b, so the
// mismatch this diagnostic was created for is gone. It is kept, repointed at the
// ingest contract: it now reports rows that are NOT canonical and that the window
// comparison therefore cannot count. With the ingest guard in place no new such row
// can be created, so in a healthy server the count is zero and nothing is logged at
// all — a line here means something wrote outside the contract and needs attention.
//
// Bounded on purpose: one aggregated row, at most one log line per request, at most
// `timestampDiagnosticExampleLimit` example record IDs, and no timestamp, payload,
// credential or hotel data of any kind. The previous per-row form emitted three log
// lines for every matching row; at the measured 301 rows that was 1806 log lines per
// gaps+pulse pair, enough to push real machine-auth denials out of the platform's
// log budget (WFOS-20260817-AKSPS-004, WFOS-20260817-KSPS-026).

/// Upper bound on example record IDs carried by the diagnostic.
///
/// Keeps the emitted log line a fixed size no matter how large `asset_records` grows.
let timestampDiagnosticExampleLimit = 5

/// Aggregated, bounded diagnostic result.
///
/// Deliberately carries no timestamp value: the count and a few record IDs are enough
/// to act on, and stored timestamps are operational data that does not belong in logs.
struct TimestampReadExpectationDiagnostic {
    let totalCount: Int
    let exampleRecordIDs: [String]
}

/// Read-only aggregate: one row, one exact count, at most five example IDs.
///
/// The predicate is the ingest contract, negated: it identifies rows the window
/// comparison cannot count because they are not canonical fixed-width epoch values.
func timestampReadExpectationDiagnosticQuery() -> SQLQueryString {
    """
        SELECT
            COUNT(*) AS "totalCount",
            COALESCE((
                SELECT STRING_AGG(sample.id::text, ',')
                FROM (
                    SELECT id
                    FROM asset_records
                    WHERE "captureTimestamp" !~ '^[0-9]{10}$'
                    ORDER BY id
                    LIMIT \(bind: timestampDiagnosticExampleLimit)
                ) AS sample
            ), '') AS "exampleRecordIDs"
        FROM asset_records
        WHERE "captureTimestamp" !~ '^[0-9]{10}$'
    """
}

/// Decodes the single aggregated row.
///
/// Returns `nil` when the query produced no row at all, so a broken or empty
/// measurement can never be silently reported as a clean one.
func timestampReadExpectationDiagnostic(
    from rows: [any SQLRow]
) throws -> TimestampReadExpectationDiagnostic? {
    guard let row = rows.first else { return nil }

    let totalCount = try row.decode(column: "totalCount", as: Int.self)
    let joinedExampleIDs = try row.decode(column: "exampleRecordIDs", as: String.self)

    return TimestampReadExpectationDiagnostic(
        totalCount: totalCount,
        exampleRecordIDs: joinedExampleIDs.split(separator: ",").map(String.init)
    )
}

/// Emits at most one structured line, and none at all when nothing matched.
///
/// Cost is O(1) in the number of matching rows. The message names what is actually
/// wrong without overstating it: these rows fall outside the ingest contract, which
/// is why the window comparison cannot see them.
func logTimestampReadExpectationDiagnostic(
    _ diagnostic: TimestampReadExpectationDiagnostic?,
    calculation: String,
    logger: Logger
) {
    guard let diagnostic, diagnostic.totalCount > 0 else { return }

    logger.warning(
        "captureTimestamp read-expectation mismatch: rows do not match the canonical 10-digit epoch contract and cannot be counted by this calculation",
        metadata: [
            "calculation": .string(calculation),
            "totalCount": .string(String(diagnostic.totalCount)),
            "exampleRecordIDs": .string(diagnostic.exampleRecordIDs.joined(separator: ","))
        ]
    )
}
