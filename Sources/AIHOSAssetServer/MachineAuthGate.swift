import Vapor

// MARK: - Module summary
//
// Responsibility
//   Central, fail-closed machine-to-machine authentication gate for every
//   production-affecting route on AIHOSAssetServer. Routes are registered through
//   `MachineGatedRoutes`, which applies `MachineAuthGate` as group middleware and
//   marks the route as gated so coverage can be verified at boot.
//
// What this is NOT
//   This is not Person Identity, not user Authentication, and not server-enforced
//   Authorization. It proves only that the caller holds the single machine
//   credential configured for this server deployment. Real identity, sessions and
//   authorization remain a later, separate Foundation gate.
//
// Ownership
//   Credential value: environment only (`AIHOS_API_V1_KEY`), injected by the
//   deployment platform. Never hardcoded, never committed, never logged, never
//   returned in a response body.
//   Route coverage: `verifyMachineGateCoverage(routes:)`, executed during boot in
//   `AIHOSAssetServer.main()` before the server starts accepting connections.
//   Exposure decisions: `unauthenticatedRouteAllowlist` below — the single place
//   where "this route may be reached without a credential" is decided.
//
// Coverage rule (default-deny)
//   Every registered route must either be gated or appear verbatim in
//   `unauthenticatedRouteAllowlist`. A new route — under /api/v1, under /test, or
//   anywhere else — is therefore never production-approved by accident: it either
//   goes through the gate, or someone classifies it explicitly and states why.
//
// Invariants that must never break
//   1. No route may reach production ungated and unclassified. Boot fails if one
//      does, so a forgotten route cannot silently ship unprotected.
//   2. Denial happens in middleware, before the route responder runs — therefore
//      before request-body collection, database access, OCR and file access.
//   3. Any uncertainty (no credential configured, unparseable header, mismatch)
//      denies the request. There is no code path that allows a request through
//      without a byte-exact credential match (KS Build Standard §9.3, R17).
//   4. The credential is compared with `secureCompare` (Vapor platform function,
//      no new dependency) so comparison time does not depend on how many leading
//      bytes matched.
//   5. Responses on denial are generic: they never reveal whether the server has a
//      credential configured, nor how the presented one differed.
//
// Client contract (used by the app client / P1-B)
//   Header: `Authorization: Bearer <credential>`
//   Config: server environment variable `AIHOS_API_V1_KEY`
//   Denied: HTTP 401 with `WWW-Authenticate: Bearer` and body {"error":"unauthorized"}
//   Surrounding whitespace is stripped from the *configured* value only; the
//   presented token is compared exactly as sent.

/// Name of the environment variable holding the single machine credential.
///
/// The value is supplied by the deployment platform (Railway variables) — see
/// `KS Permanent Build Standard §9.2 (R15)`: secrets live in the environment only.
///
/// The name is kept as-is from the P1-A client contract even though the gate now
/// also covers non-/api/v1 routes: renaming it would silently break the deployment
/// configuration handed to AKS and the P1-B client.
let machineCredentialEnvironmentKey = "AIHOS_API_V1_KEY"

/// Routes that are deliberately reachable without the machine credential.
///
/// Signatures are formatted exactly like `routeSignature(_:)` produces them. Adding
/// an entry is an explicit production-exposure decision: it belongs to whoever owns
/// the atom that adds it, and the comment must state why the route exposes no
/// product data, credentials or configuration.
let unauthenticatedRouteAllowlist: Set<String> = [
    // Liveness probe. Reports only whether `SELECT 1` succeeded; returns no product
    // data, no credential and no configuration.
    "GET /health/db"
]

/// The machine credential this server accepts, as resolved from configuration.
///
/// `missing` covers both "variable not set" and "variable set to an empty/whitespace
/// value" — a misconfigured server denies every request rather than accepting any.
enum MachineCredential: Equatable {
    case configured(String)
    case missing

    /// Resolves a credential from a raw configuration value.
    ///
    /// Kept separate from the environment lookup so the rule can be tested without
    /// mutating process environment state.
    static func resolve(fromConfiguredValue value: String?) -> MachineCredential {
        guard let value else {
            return .missing
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .missing
        }

        return .configured(trimmed)
    }

    /// Resolves the credential from the process environment.
    static func resolveFromEnvironment() -> MachineCredential {
        resolve(fromConfiguredValue: Environment.get(machineCredentialEnvironmentKey))
    }

    /// Boot log line. States configuration status without ever revealing the value.
    var configurationStatusDescription: String {
        switch self {
        case .configured:
            return "Machine auth gate: credential configured"
        case .missing:
            return "Machine auth gate: NO credential configured - every gated request will be denied"
        }
    }
}

/// Fail-closed machine authentication for every gated route.
///
/// Applied once per gated route group, never per endpoint. Because Vapor runs
/// middleware around the route responder, and body collection happens inside that
/// responder, a denied request never reaches body collection, the database, OCR or
/// the file system.
struct MachineAuthGate: AsyncMiddleware {
    /// Why the gate refused a request. Used for server-side logging only — the
    /// client always receives the same generic response.
    enum DenialReason: String {
        case credentialNotConfigured = "credential_not_configured"
        case credentialNotPresented = "credential_not_presented"
        case credentialMismatch = "credential_mismatch"
    }

    let credential: MachineCredential

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if let denial = Self.denialReason(for: request.headers, credential: credential) {
            // Never log the header or any part of the presented credential.
            request.logger.warning(
                "Machine auth gate denied request",
                metadata: [
                    "reason": .string(denial.rawValue),
                    "method": .string(request.method.rawValue),
                    "path": .string(request.url.path)
                ]
            )

            return Self.deniedResponse()
        }

        return try await next.respond(to: request)
    }

    /// Pure decision function: returns `nil` when the request may pass.
    ///
    /// Separated from `respond(to:chainingTo:)` so the fail-closed rules can be
    /// tested directly, including the misconfigured-server case.
    static func denialReason(
        for headers: HTTPHeaders,
        credential: MachineCredential
    ) -> DenialReason? {
        guard case .configured(let expected) = credential else {
            return .credentialNotConfigured
        }

        guard let presented = headers.bearerAuthorization?.token, !presented.isEmpty else {
            return .credentialNotPresented
        }

        guard Array(presented.utf8).secureCompare(to: Array(expected.utf8)) else {
            return .credentialMismatch
        }

        return nil
    }

    /// The single generic denial response. Identical for every denial reason.
    static func deniedResponse() -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        headers.add(name: .wwwAuthenticate, value: "Bearer")

        return Response(
            status: .unauthorized,
            headers: headers,
            body: .init(string: #"{"error":"unauthorized"}"#)
        )
    }
}

/// Routes builder that applies the machine auth gate and records that it did.
///
/// Registration through this builder is the only supported way to add a
/// production-affecting route. The recorded marker is what
/// `verifyMachineGateCoverage(routes:)` reads, so a route added directly on the
/// application can be detected at boot instead of silently shipping unprotected.
struct MachineGatedRoutes: RoutesBuilder {
    /// Key under which the gate marks a route in `Route.userInfo`.
    static let gateMarkerKey = "aihos.machine.gated"

    private let base: RoutesBuilder

    /// Builds a gated routes group on top of the application's root router.
    ///
    /// - Parameter pathPrefix: Optional shared path prefix, e.g. `["api", "v1"]`.
    ///   Pass an empty prefix for routes that carry their own full path.
    init(application: Application, pathPrefix: [PathComponent] = [], credential: MachineCredential) {
        let root: RoutesBuilder = pathPrefix.isEmpty ? application : application.grouped(pathPrefix)
        self.base = root.grouped(MachineAuthGate(credential: credential))
    }

    func add(_ route: Route) {
        route.userInfo[Self.gateMarkerKey] = true
        base.add(route)
    }
}

/// Raised at boot when a route is neither gated nor explicitly classified as
/// reachable without a credential.
struct MachineGateCoverageError: Error, CustomStringConvertible {
    let ungatedRoutes: [String]

    var description: String {
        "Routes registered outside the central machine auth gate and not in the unauthenticated allowlist: "
            + ungatedRoutes.joined(separator: ", ")
    }
}

/// Stable, human-readable route signature, e.g. `GET /api/v1/records`.
///
/// Used both for allowlist matching and for reporting violations, so the two can
/// never drift apart.
func routeSignature(_ route: Route) -> String {
    let path = route.path.map(\.description).joined(separator: "/")
    return "\(route.method.rawValue) /\(path)"
}

/// Returns every route that is neither gated nor explicitly allowlisted.
func routesMissingGate(in routes: [Route]) -> [String] {
    routes
        .filter { !isGatedRoute($0) && !unauthenticatedRouteAllowlist.contains(routeSignature($0)) }
        .map(routeSignature)
}

/// Boot-time coverage check. Throws — and therefore prevents the server from
/// starting — if any route bypasses the gate without an explicit classification
/// (fail-closed, §9.3 R17).
func verifyMachineGateCoverage(routes: [Route]) throws {
    let ungated = routesMissingGate(in: routes)

    guard ungated.isEmpty else {
        throw MachineGateCoverageError(ungatedRoutes: ungated)
    }
}

/// True when the route carries the marker set by `MachineGatedRoutes`.
private func isGatedRoute(_ route: Route) -> Bool {
    (route.userInfo[MachineGatedRoutes.gateMarkerKey] as? Bool) == true
}
