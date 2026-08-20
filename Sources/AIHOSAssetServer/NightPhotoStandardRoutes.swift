import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Night photo standard fixation route
//
// F-G1, the first write route lifted out of the composition root. It seeds the
// night-photo operational standard so a fresh environment has the standard the rest of
// the system is built around, without anyone typing it in by hand.
//
// It was chosen as the first write to move because it is the smallest and the only one
// with nothing to thread: no value from main()'s local scope, no request body to
// decode, no path parameter, no transaction to preserve and no storage access. That
// makes it a write extraction that proves the pattern without carrying risk.
//
// WHAT MAKES IT SAFE TO CALL TWICE
//   The INSERT ... SELECT ... WHERE NOT EXISTS is the whole point. This route is a
//   fixation, not a create: calling it again after the standard exists inserts nothing
//   and still answers .ok. Rewriting it as a plain INSERT would compile, pass a first
//   call, and then start failing or duplicating on every call after that.
//
// WHY THE SOURCE TAG IS "[?]"
//   The seeded standard is machine-fixated rather than attributable to an operator or
//   to the system's own reasoning, and it carries that unknown provenance honestly. It
//   is a governance value, not a placeholder to be tidied.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/standards/night-photo` on the machine-gated group.
///
/// - Parameter apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
func registerNightPhotoStandardRoutes(on apiV1: MachineGatedRoutes) {
    apiV1.post("standards", "night-photo") { req async throws -> HTTPStatus in
        guard let sql = req.db as? SQLDatabase else {
            return .internalServerError
        }

        try await sql.raw("""
            INSERT INTO operational_standards (id, "standardKey", "description", "sourceTag", "startHour", "endHour", "requiredCount")
            SELECT
                \(bind: UUID()),
                \(bind: "night-photo-22-23"),
                \(bind: "At least one photo between 22:00 and 23:00"),
                \(bind: "[?]"),
                \(bind: 22),
                \(bind: 23),
                \(bind: 1)
            WHERE NOT EXISTS (
                SELECT 1 FROM operational_standards
                WHERE "standardKey" = \(bind: "night-photo-22-23")
            );
        """).run()

        print("Operational standard fixation PASS: night-photo-22-23")
        return .ok
    }
}
