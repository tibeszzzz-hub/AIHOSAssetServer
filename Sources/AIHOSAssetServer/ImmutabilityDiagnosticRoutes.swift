import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Immutability diagnostic route
//
// F-G3. `GET /test/immutable` proves, against the live database, that the governance
// triggers on `asset_records` actually block UPDATE and DELETE. It is a diagnostic that
// works by attempting exactly the writes that must fail.
//
// WHY ITS SUCCESS AND FAILURE ARE INVERTED
//   For the two governance checks, a successful SQL statement is the failure case. If
//   the UPDATE or the DELETE goes through, the trigger is missing or disabled and the
//   route answers 500. The `catch` branches are the PASS paths. Anyone "fixing" this
//   route by removing the do/catch inversion would turn a governance alarm into a
//   green light.
//
// WHY IT IS GATED
//   It writes a real row to `asset_records` in whatever database it is pointed at
//   (PSKS-008), so it is registered on the gated group and requires a machine
//   credential. Registering it on `app` would expose a route that writes production
//   data to anyone who can reach the host.
//
//   The parameter is named `gated` for the same reason the other route files use
//   `apiV1` and `app`: the route manifest resolves a registration's gate and prefix
//   from the receiver's name. `gated` is what keeps this route classified as gated with
//   the signature `GET /test/immutable`, unprefixed.
//
// The inserted row is left behind on purpose — it cannot be deleted, which is the very
// property being demonstrated.

/// Registers the gated `GET /test/immutable` governance diagnostic.
///
/// - Parameter gated: the machine-gated route group without the `/api/v1` prefix.
func registerImmutabilityDiagnosticRoutes(on gated: MachineGatedRoutes) {
    // Writes to asset_records in the production database - gated (PSKS-008).
    gated.get("test", "immutable") { req async throws -> HTTPStatus in
        guard let sql = req.db as? SQLDatabase else {
            return .internalServerError
        }

        let testID = UUID().uuidString

        do {
            try await sql.raw("""
            INSERT INTO asset_records (id, "captureTimestamp", "sourceTag")
            VALUES ('\(unsafeRaw: testID)', 'test-capture-timestamp', '[TEST]');
            """).run()
            print("Immutable validation INSERT PASS")
        } catch {
            print("Immutable validation INSERT failed: \(error)")
            return .internalServerError
        }

        do {
            try await sql.raw("""
            UPDATE asset_records
            SET "sourceTag" = '[TEST-UPDATED]'
            WHERE id = '\(unsafeRaw: testID)';
            """).run()
            print("Immutable validation UPDATE unexpectedly succeeded")
            return .internalServerError
        } catch {
            print("Immutable validation UPDATE blocked by governance trigger")
        }

        do {
            try await sql.raw("""
            DELETE FROM asset_records
            WHERE id = '\(unsafeRaw: testID)';
            """).run()
            print("Immutable validation DELETE unexpectedly succeeded")
            return .internalServerError
        } catch {
            print("Immutable validation DELETE blocked by governance trigger")
        }

        print("Immutable validation PASS")
        return .ok
    }
}
