import Testing
import Vapor
import VaporTesting
@testable import AIHOSAssetServer

// Tests for the central machine auth gate (MachineAuthGate.swift).
//
// Structure follows KS Build Standard §9.3 (R17): every negative test has a positive
// control, so a broken test setup can never be reported as a passing security test.
// The credential used here is an obvious, non-secret test literal — never a real key.

private let testCredential = "ks-test-machine-credential-not-a-real-secret"

/// Records whether a route handler behind the gate was actually reached.
private actor HandlerProbe {
    private(set) var reached = false

    func markReached() {
        reached = true
    }
}

/// Registers probe routes through the real gated builders:
/// - `api/v1/probe`: prefixed group, plain GET.
/// - `api/v1/probe-body`: prefixed group, POST that collects a body.
/// - `test/probe-body`: root-level gated group, POST that collects a body — mirrors
///   how `/test/immutable` and `/test/vision-ocr` are registered in the server.
private func registerProbeRoutes(
    on app: Application,
    credential: MachineCredential,
    probe: HandlerProbe
) {
    let apiV1 = MachineGatedRoutes(application: app, pathPrefix: ["api", "v1"], credential: credential)
    let gated = MachineGatedRoutes(application: app, credential: credential)

    apiV1.get("probe") { _ async -> String in
        await probe.markReached()
        return "handler-reached"
    }

    apiV1.on(.POST, "probe-body", body: .collect(maxSize: "1mb")) { req async -> String in
        await probe.markReached()
        return "handler-reached-with-\(req.body.data?.readableBytes ?? 0)-bytes"
    }

    gated.on(.POST, "test", "probe-body", body: .collect(maxSize: "1mb")) { req async -> String in
        await probe.markReached()
        return "test-handler-reached-with-\(req.body.data?.readableBytes ?? 0)-bytes"
    }
}

private func bearerHeaders(_ token: String) -> HTTPHeaders {
    HTTPHeaders([("Authorization", "Bearer \(token)")])
}

// MARK: - Credential configuration (AC-3, fail-closed on misconfiguration)

@Suite("Machine credential configuration")
struct MachineCredentialTests {
    @Test("A configured value is accepted and surrounding whitespace is stripped")
    func configuredValueIsResolved() {
        #expect(MachineCredential.resolve(fromConfiguredValue: testCredential) == .configured(testCredential))
        #expect(MachineCredential.resolve(fromConfiguredValue: "  \(testCredential)\n") == .configured(testCredential))
    }

    @Test("Unset, empty and whitespace-only configuration all resolve to missing")
    func misconfiguredValuesResolveToMissing() {
        #expect(MachineCredential.resolve(fromConfiguredValue: nil) == .missing)
        #expect(MachineCredential.resolve(fromConfiguredValue: "") == .missing)
        #expect(MachineCredential.resolve(fromConfiguredValue: "   \n\t ") == .missing)
    }

    @Test("Status logging never contains the credential value")
    func statusDescriptionNeverLeaksCredential() {
        let configured = MachineCredential.configured(testCredential)
        #expect(!configured.configurationStatusDescription.contains(testCredential))
        #expect(MachineCredential.missing.configurationStatusDescription.contains("NO credential configured"))
    }
}

// MARK: - Gate decision rules (AC-2, AC-4)

@Suite("Machine auth gate decision rules")
struct MachineAuthGateDecisionTests {
    @Test("Positive control: a byte-exact credential is allowed through")
    func exactCredentialIsAllowed() {
        let reason = MachineAuthGate.denialReason(
            for: bearerHeaders(testCredential),
            credential: .configured(testCredential)
        )

        #expect(reason == nil)
    }

    @Test("A server without configured credential denies even a well-formed request")
    func missingServerCredentialDenies() {
        let reason = MachineAuthGate.denialReason(
            for: bearerHeaders(testCredential),
            credential: .missing
        )

        #expect(reason == .credentialNotConfigured)
    }

    @Test("Missing, empty and non-bearer authorization headers are denied")
    func missingOrMalformedHeaderDenies() {
        let credential = MachineCredential.configured(testCredential)

        #expect(MachineAuthGate.denialReason(for: HTTPHeaders(), credential: credential) == .credentialNotPresented)
        #expect(MachineAuthGate.denialReason(for: bearerHeaders(""), credential: credential) == .credentialNotPresented)
        #expect(MachineAuthGate.denialReason(
            for: HTTPHeaders([("Authorization", "Basic \(testCredential)")]),
            credential: credential
        ) == .credentialNotPresented)
        #expect(MachineAuthGate.denialReason(
            for: HTTPHeaders([("Authorization", testCredential)]),
            credential: credential
        ) == .credentialNotPresented)
    }

    @Test("Wrong, truncated, extended and differently-cased credentials are denied")
    func mismatchedCredentialDenies() {
        let credential = MachineCredential.configured(testCredential)

        #expect(MachineAuthGate.denialReason(for: bearerHeaders("wrong-credential"), credential: credential) == .credentialMismatch)
        #expect(MachineAuthGate.denialReason(for: bearerHeaders(String(testCredential.dropLast())), credential: credential) == .credentialMismatch)
        #expect(MachineAuthGate.denialReason(for: bearerHeaders(testCredential + "x"), credential: credential) == .credentialMismatch)
        #expect(MachineAuthGate.denialReason(for: bearerHeaders(testCredential.uppercased()), credential: credential) == .credentialMismatch)
    }

    @Test("The denial response is generic and never echoes the credential")
    func denialResponseIsGeneric() {
        let response = MachineAuthGate.deniedResponse()

        #expect(response.status == .unauthorized)
        #expect(response.headers.first(name: .wwwAuthenticate) == "Bearer")
        #expect(response.body.string == #"{"error":"unauthorized"}"#)
        #expect(response.body.string?.contains(testCredential) != true)
    }
}

// MARK: - End-to-end routing behaviour (AC-1, AC-2, AC-3)

@Suite("Machine auth gate over real routing")
struct MachineAuthGateRoutingTests {
    @Test("Positive control: a valid credential reaches the handler with unchanged semantics")
    func validCredentialReachesHandler() async throws {
        try await withApp { app in
            let probe = HandlerProbe()
            registerProbeRoutes(on: app, credential: .configured(testCredential), probe: probe)

            try await app.testing().test(
                .GET,
                "api/v1/probe",
                headers: bearerHeaders(testCredential)
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "handler-reached")
            }

            #expect(await probe.reached)
        }
    }

    @Test("A request without credential is denied before the handler runs")
    func missingCredentialIsDeniedBeforeHandler() async throws {
        try await withApp { app in
            let probe = HandlerProbe()
            registerProbeRoutes(on: app, credential: .configured(testCredential), probe: probe)

            try await app.testing().test(.GET, "api/v1/probe") { res async in
                #expect(res.status == .unauthorized)
                #expect(res.headers.first(name: .wwwAuthenticate) == "Bearer")
                #expect(res.body.string == #"{"error":"unauthorized"}"#)
                #expect(!res.body.string.contains(testCredential))
            }

            #expect(await probe.reached == false)
        }
    }

    @Test("A wrong credential is denied before the handler runs")
    func wrongCredentialIsDeniedBeforeHandler() async throws {
        try await withApp { app in
            let probe = HandlerProbe()
            registerProbeRoutes(on: app, credential: .configured(testCredential), probe: probe)

            try await app.testing().test(
                .GET,
                "api/v1/probe",
                headers: bearerHeaders("wrong-credential")
            ) { res async in
                #expect(res.status == .unauthorized)
            }

            #expect(await probe.reached == false)
        }
    }

    @Test("A misconfigured server denies every request, including well-formed ones")
    func misconfiguredServerDeniesEverything() async throws {
        try await withApp { app in
            let probe = HandlerProbe()
            registerProbeRoutes(on: app, credential: .missing, probe: probe)

            try await app.testing().test(
                .GET,
                "api/v1/probe",
                headers: bearerHeaders(testCredential)
            ) { res async in
                #expect(res.status == .unauthorized)
            }

            #expect(await probe.reached == false)
        }
    }

    @Test("A denied upload never reaches body collection or the handler")
    func deniedUploadNeverReachesHandler() async throws {
        try await withApp { app in
            let probe = HandlerProbe()
            registerProbeRoutes(on: app, credential: .configured(testCredential), probe: probe)

            var payload = ByteBufferAllocator().buffer(capacity: 32)
            payload.writeString("observation-payload")

            try await app.testing().test(.POST, "api/v1/probe-body", body: payload) { res async in
                #expect(res.status == .unauthorized)
            }

            #expect(await probe.reached == false)

            // Positive control: the same upload succeeds with a valid credential, which
            // proves the negative case above was blocked by the gate and not by the setup.
            try await app.testing().test(
                .POST,
                "api/v1/probe-body",
                headers: bearerHeaders(testCredential),
                body: payload
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "handler-reached-with-19-bytes")
            }

            #expect(await probe.reached)
        }
    }

    @Test("A root-level /test upload is gated the same way as /api/v1 (PSKS-008)")
    func rootLevelTestRouteIsGated() async throws {
        try await withApp { app in
            let probe = HandlerProbe()
            registerProbeRoutes(on: app, credential: .configured(testCredential), probe: probe)

            var payload = ByteBufferAllocator().buffer(capacity: 32)
            payload.writeString("ocr-image-bytes")

            try await app.testing().test(.POST, "test/probe-body", body: payload) { res async in
                #expect(res.status == .unauthorized)
                #expect(res.body.string == #"{"error":"unauthorized"}"#)
            }

            #expect(await probe.reached == false)

            try await app.testing().test(
                .POST,
                "test/probe-body",
                headers: bearerHeaders("wrong-credential"),
                body: payload
            ) { res async in
                #expect(res.status == .unauthorized)
            }

            #expect(await probe.reached == false)

            // Positive control: valid credential reaches the handler and the body is intact.
            try await app.testing().test(
                .POST,
                "test/probe-body",
                headers: bearerHeaders(testCredential),
                body: payload
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "test-handler-reached-with-15-bytes")
            }

            #expect(await probe.reached)
        }
    }
}

// MARK: - Route inventory (AC-1, AC-5, PSKS-008 krav 3)

@Suite("Machine auth gate route inventory")
struct MachineGateInventoryTests {
    @Test("Gated routes pass and the allowlisted liveness probe is not flagged")
    func gatedRoutesPassInventory() async throws {
        try await withApp { app in
            let apiV1 = MachineGatedRoutes(application: app, pathPrefix: ["api", "v1"], credential: .configured(testCredential))
            apiV1.get("records") { _ in "ok" }
            apiV1.on(.PATCH, "standards", ":standardID", "status") { _ in "ok" }

            let gated = MachineGatedRoutes(application: app, credential: .configured(testCredential))
            gated.get("test", "immutable") { _ in "ok" }
            gated.on(.POST, "test", "vision-ocr", body: .collect(maxSize: "10mb")) { _ in "ok" }

            // Explicitly classified as reachable without a credential (AC-5).
            app.get("health", "db") { _ in "ok" }

            #expect(routesMissingGate(in: app.routes.all).isEmpty)
            try verifyMachineGateCoverage(routes: app.routes.all)
        }
    }

    @Test("An /api/v1 route registered outside the gate is detected and blocks boot")
    func ungatedAPIV1RouteIsDetected() async throws {
        try await withApp { app in
            let apiV1 = MachineGatedRoutes(application: app, pathPrefix: ["api", "v1"], credential: .configured(testCredential))
            apiV1.get("records") { _ in "ok" }

            // The exact mistake the boot check exists to catch.
            app.get("api", "v1", "forgotten") { _ in "ok" }
            app.on(.POST, "api", "v1", "assets", ":assetID", "forgotten") { _ in "ok" }

            let missing = routesMissingGate(in: app.routes.all)

            #expect(missing.sorted() == ["GET /api/v1/forgotten", "POST /api/v1/assets/:assetID/forgotten"])
            #expect(throws: MachineGateCoverageError.self) {
                try verifyMachineGateCoverage(routes: app.routes.all)
            }
        }
    }

    @Test("A new /test route is never production-approved automatically")
    func ungatedTestRouteIsDetected() async throws {
        try await withApp { app in
            let gated = MachineGatedRoutes(application: app, credential: .configured(testCredential))
            gated.get("test", "immutable") { _ in "ok" }

            // A future /test route added directly on the application, the case PSKS-008
            // krav 3 requires to be caught rather than silently exposed.
            app.get("test", "new-diagnostic") { _ in "ok" }

            #expect(routesMissingGate(in: app.routes.all) == ["GET /test/new-diagnostic"])
            #expect(throws: MachineGateCoverageError.self) {
                try verifyMachineGateCoverage(routes: app.routes.all)
            }
        }
    }

    @Test("Any ungated route outside the allowlist blocks boot, whatever its path")
    func ungatedArbitraryRouteIsDetected() async throws {
        try await withApp { app in
            app.get("internal", "metrics") { _ in "ok" }

            #expect(routesMissingGate(in: app.routes.all) == ["GET /internal/metrics"])
            #expect(throws: MachineGateCoverageError.self) {
                try verifyMachineGateCoverage(routes: app.routes.all)
            }
        }
    }

    @Test("The allowlist contains only the liveness probe")
    func allowlistIsMinimal() {
        #expect(unauthenticatedRouteAllowlist == ["GET /health/db"])
    }

    @Test("The server source registers every route except the liveness probe through the gate")
    func serverSourceHasNoUngatedRegistration() throws {
        // Inventory over the real production source file. The boot check
        // (verifyMachineGateCoverage) catches an escaped route at startup; this catches
        // it at test time, before anyone deploys.
        let serverSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AIHOSAssetServerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/AIHOSAssetServer/AIHOSAssetServer.swift")

        let source = try String(contentsOf: serverSource, encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let routeVerbs = ["get", "post", "put", "patch", "delete", "on", "webSocket", "group", "grouped"]

        let appLevelRegistrations = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in routeVerbs.contains { line.hasPrefix("app.\($0)(") } }

        let gatedRegistrations = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("apiV1.") || $0.hasPrefix("gated.") }

        // Positive control: the inventory actually found the route registrations.
        #expect(gatedRegistrations.count >= 20)
        #expect(appLevelRegistrations.count >= 1)

        // The liveness probe is the only route allowed outside the gate, and it is the
        // one entry in `unauthenticatedRouteAllowlist`.
        #expect(appLevelRegistrations.filter { !$0.hasPrefix("app.get(\"health\", \"db\")") }.isEmpty,
                "Route(s) registered outside MachineGatedRoutes: \(appLevelRegistrations)")

        // The two routes PSKS-008 ordered protected are registered through the gate.
        #expect(gatedRegistrations.contains { $0.hasPrefix("gated.get(\"test\", \"immutable\")") })
        #expect(gatedRegistrations.contains { $0.hasPrefix("gated.on(.POST, \"test\", \"vision-ocr\"") })
    }
}
