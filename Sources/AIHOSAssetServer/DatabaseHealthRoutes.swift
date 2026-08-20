import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Database liveness probe
//
// F-G2. `GET /health/db` is the platform's liveness probe and the ONLY route in the
// server that answers without a machine credential.
//
// WHY MOVING IT DOES NOT MOVE THE EXPOSURE DECISION
//   The decision that this route may answer unauthenticated lives in
//   `unauthenticatedRouteAllowlist` in MachineAuthGate.swift, and it did not move. Nor
//   did `verifyMachineGateCoverage`, which refuses to boot if any registered route is
//   outside the gate without a matching allowlist entry. Only the registration itself
//   moved here.
//
//   The parameter is named `app` for the same reason the route files use `apiV1`: the
//   route manifest resolves a registration's gate and prefix from the receiver's name.
//   Registering on `app` is what keeps this route ungated with the signature
//   `GET /health/db`, exactly as when it sat in the composition root. Registering it on
//   `apiV1` or `gated` instead would silently change both.
//
// WHAT THE PROBE ACTUALLY ASSERTS
//   It reports two stages separately: whether the database handle can be obtained at
//   all (`sql_cast`) and whether a trivial query round-trips (`select_1`). Collapsing
//   them into one boolean would hide which half failed, which is the only thing the
//   probe exists to tell the platform apart.
//
//   It deliberately carries no operational data, no counts and no configuration — it is
//   the one route reachable without a credential, so its body is a fixed shape.

/// Registers the ungated `GET /health/db` liveness probe.
///
/// - Parameter app: the application, registered on directly so the route stays outside
///   the machine gate — the single exposure the allowlist accounts for.
func registerDatabaseHealthRoutes(on app: Application) {
    app.get("health", "db") { req async -> Response in
        req.logger.info("DB HEALTH ROUTE ENTERED")

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        guard let sql = req.db as? SQLDatabase else {
            req.logger.error("DB HEALTH SQL CAST FAIL")
            return Response(
                status: .internalServerError,
                headers: headers,
                body: .init(string: #"{"status":"fail","stage":"sql_cast"}"#)
            )
        }

        req.logger.info("DB HEALTH SQL CAST PASS")

        do {
            try await sql.raw("SELECT 1").run()
            req.logger.info("DB HEALTH SELECT 1 PASS")

            return Response(
                status: .ok,
                headers: headers,
                body: .init(string: #"{"status":"ok","stage":"select_1"}"#)
            )
        } catch {
            req.logger.error("DB HEALTH SELECT 1 FAIL: \(String(reflecting: error))")

            return Response(
                status: .internalServerError,
                headers: headers,
                body: .init(string: #"{"status":"fail","stage":"select_1"}"#)
            )
        }
    }
}
