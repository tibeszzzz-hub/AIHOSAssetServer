import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Operational standard creation route
//
// F-G7. `POST /api/v1/standards` creates an operational standard: a statement that a
// particular lane and track are expected to produce a given number of observations
// within a given window. Everything the gap and pulse calculations report is measured
// against rows this route writes.
//
// Chosen over /test/vision-ocr, which is 28 lines shorter but reaches the Vision
// framework, the file system and the storage directory. This route is pure SQL and
// needs nothing threaded through — lower risk despite being larger, per the order.
//
// FIVE VALIDATIONS BEFORE ANY WRITE, EACH WITH ITS OWN REASON
//   The body must decode; the lane key and track type must each pass their allowlist;
//   the window must parse to two hours with the end after the start; and requiredCount
//   must be positive. All five answer 400 and all five run before the database is
//   touched. A standard that got past any of them would be measured against forever
//   after, because standards are append-only and cannot be corrected in place.
//
// THE DUPLICATE GUARD IS 409, NOT 400
//   An identical ACTIVE standard already existing is not a malformed request — it is a
//   conflict with existing state, and the caller is told so with its own status and
//   reason. The check considers five columns together plus status = 'ACTIVE', so a
//   superseded standard does not block re-creation.
//
// WHAT THE SERVER DECIDES
//   The id, the timestamp, the ACTIVE status, the "[?]" source tag, and both the
//   standardKey and the description, which are derived from the validated inputs rather
//   than accepted from the caller. Two callers describing the same expectation
//   therefore produce the same key.
//
//   The "[?]" tag records that provenance is unknown at creation: the standard is
//   neither an operator's attributed judgement nor the system's own reasoning.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/standards` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerOperationalStandardCreateRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.post("standards") { req async throws -> Response in
        guard let sql = req.db as? SQLDatabase else {
            return Response(status: .internalServerError)
        }

        let payload: OperationalStandardCreateRequest

        do {
            payload = try req.content.decode(OperationalStandardCreateRequest.self)
        } catch {
            print("Operational Standard create failed: payload decode error \(error)")
            return Response(status: .badRequest)
        }

        guard let laneKey = validatedOperationalStandardLaneKey(payload.laneKey) else {
            print("Operational Standard create failed: invalid laneKey \(payload.laneKey)")
            return Response(status: .badRequest)
        }

        guard let trackType = validatedOperationalStandardTrackType(payload.trackType) else {
            print("Operational Standard create failed: invalid trackType \(payload.trackType)")
            return Response(status: .badRequest)
        }

        guard let startHour = hourFromExpectedWindow(payload.expectedWindowStart),
              let endHour = hourFromExpectedWindow(payload.expectedWindowEnd),
              endHour > startHour else {
            print("Operational Standard create failed: invalid expected window")
            return Response(status: .badRequest)
        }

        guard payload.requiredCount > 0 else {
            print("Operational Standard create failed: requiredCount must be greater than zero")
            return Response(status: .badRequest)
        }

        let duplicateRows = try await sql.raw("""
            SELECT COUNT(*) AS duplicate_count
            FROM operational_standards
            WHERE lane_key = \(bind: laneKey)
              AND track_type = \(bind: trackType)
              AND expected_window_start = \(bind: payload.expectedWindowStart)
              AND expected_window_end = \(bind: payload.expectedWindowEnd)
              AND "requiredCount" = \(bind: payload.requiredCount)
              AND status = 'ACTIVE'
        """).all()

        let duplicateCount = try duplicateRows[0].decode(column: "duplicate_count", as: Int.self)

        guard duplicateCount == 0 else {
            print("Operational Standard create blocked: duplicate active standard")
            let response = Response(status: .conflict)
            try response.content.encode([
                "reason": "duplicate active operational standard"
            ])
            return response
        }

        let standardID = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let status = "ACTIVE"
        let sourceTag = "[?]"
        let standardKey = "\(laneKey)-\(trackType)-\(payload.expectedWindowStart)-\(payload.expectedWindowEnd)"
        let description = "Expected \(trackType) information for \(laneKey) between \(payload.expectedWindowStart) and \(payload.expectedWindowEnd)"

        do {
            try await sql.raw("""
                INSERT INTO operational_standards
                (id, "standardKey", description, "sourceTag", "startHour", "endHour", "requiredCount", lane_key, track_type, expected_window_start, expected_window_end, status, created_at)
                VALUES
                (\(bind: standardID), \(bind: standardKey), \(bind: description), \(bind: sourceTag), \(bind: startHour), \(bind: endHour), \(bind: payload.requiredCount), \(bind: laneKey), \(bind: trackType), \(bind: payload.expectedWindowStart), \(bind: payload.expectedWindowEnd), \(bind: status), \(bind: createdAt));
            """).run()
        } catch {
            print("Operational Standard create failed: \(error)")
            return Response(status: .internalServerError)
        }

        print("Operational Standard create PASS")
        print("standardID: \(standardID.uuidString)")
        print("laneKey: \(laneKey)")
        print("trackType: \(trackType)")
        print("expectedWindowStart: \(payload.expectedWindowStart)")
        print("expectedWindowEnd: \(payload.expectedWindowEnd)")
        print("requiredCount: \(payload.requiredCount)")
        print("status: \(status)")
        print("createdAt: \(createdAt)")
        print("Governance: standard created append-only; no historical standard mutated")

        let response = Response(status: .ok)
        try response.content.encode(
            OperationalStandardResponse(
                id: standardID.uuidString,
                standardKey: standardKey,
                laneKey: laneKey,
                trackType: trackType,
                expectedWindowStart: payload.expectedWindowStart,
                expectedWindowEnd: payload.expectedWindowEnd,
                requiredCount: payload.requiredCount,
                status: status,
                createdAt: createdAt
            )
        )
        return response
    }
}
