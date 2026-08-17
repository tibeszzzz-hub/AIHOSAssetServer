import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - AC-1: exact route manifest for the current server
//
// Atom SERVER-MOD-A0 (WFOS-20260817-PSKS-020).
//
// This is ROUTE-LOSS protection and nothing else. The runtime gate coverage check
// (`verifyMachineGateCoverage`) refuses to boot when a route is registered UNGATED;
// it is structurally incapable of noticing a route that has been DELETED, because a
// deleted route is simply absent from `app.routes.all`. Nothing in this file may be
// read as a claim that a missing route is caught at runtime (PSKS-020 AC-1).
//
// The assertions below are exact-set, never counts and never lower bounds.

/// The complete route table as verified in the source at 0db192f: 21 routes, of which
/// 20 pass through the central machine auth gate and exactly one — the liveness probe
/// — is explicitly classified as reachable without a credential.
private let expectedGatedRouteSignatures: Set<String> = [
    // Root-level gated diagnostics (gated by WFOS-20260817-PSKS-008).
    "GET /test/immutable",
    "POST /test/vision-ocr",

    // Ingestion.
    "POST /api/v1/sync",
    "POST /api/v1/audio",

    // Reads.
    "GET /api/v1/records",
    "GET /api/v1/shift-handover/log",
    "GET /api/v1/files/:fileName",

    // Operational standards.
    "GET /api/v1/standards",
    "POST /api/v1/standards",
    "PATCH /api/v1/standards/:standardID/status",
    "GET /api/v1/standards/:standardID/status-updates",
    "POST /api/v1/standards/night-photo",

    // Decision traces.
    "POST /api/v1/assets/:assetID/decision-traces",
    "GET /api/v1/assets/:assetID/decision-traces",
    "POST /api/v1/decisions",

    // Payload text and transcription.
    "POST /api/v1/assets/:assetID/payload-text",
    "GET /api/v1/assets/:assetID/payload-text",
    "POST /api/v1/assets/:assetID/transcribe-audio",

    // Derived state.
    "GET /api/v1/gaps/mechanical",
    "GET /api/v1/state/pulse"
]

/// The single route deliberately registered outside the gate.
private let expectedUngatedRouteSignature = "GET /health/db"

/// Miniature of the real registration block, covering every syntactic form that
/// appears in the server: a plain app-level route, a root-level gated route, a gated
/// `.on` with a collected body, a prefixed `.on` with a collected body, a plain
/// prefixed route, and a prefixed `.on` with path parameters.
private let registrationFixture = #"""
        app.get("health", "db") { req async -> Response in
        gated.get("test", "immutable") { req async throws -> HTTPStatus in
        gated.on(.POST, "test", "vision-ocr", body: .collect(maxSize: "10mb")) { req async throws -> Response in
        apiV1.on(.POST, "sync", body: .collect(maxSize: "10mb")) { req async throws -> HTTPStatus in
        apiV1.get("records") { req async throws -> Response in
        apiV1.on(.PATCH, "standards", ":standardID", "status") { req async throws -> Response in
"""#

private let fixtureSignatures: Set<String> = [
    "GET /health/db",
    "GET /test/immutable",
    "POST /test/vision-ocr",
    "POST /api/v1/sync",
    "GET /api/v1/records",
    "PATCH /api/v1/standards/:standardID/status"
]

@Suite("Route manifest — exact current server route table")
struct RouteManifestTests {

    // MARK: Positive control on the real source

    @Test("The server source registers exactly the 21 expected routes, no more and no fewer")
    func serverSourceMatchesExpectedRouteManifest() throws {
        let source = try serverSourceText()
        let registrations = parseRouteRegistrations(inSource: source)

        // Positive control that the parser found something at all — a scanner that
        // matches nothing would otherwise report a perfectly clean manifest.
        #expect(registrations.count == 21, "Parsed \(registrations.count) registrations, expected exactly 21")

        // Every registration must resolve to a real HTTP method. A `nil` here means a
        // grouping verb (`group`/`grouped`/`webSocket`) introduced a registration path
        // this manifest cannot see through.
        let methodless = registrations.filter { $0.method == nil }
        #expect(methodless.isEmpty, "Registrations without a resolvable HTTP method: \(methodless)")

        let signatures = registrations.compactMap(\.signature)
        #expect(signatures.count == 21)

        let expected = expectedGatedRouteSignatures.union([expectedUngatedRouteSignature])
        let difference = inventoryDifference(observed: signatures, expected: expected)

        #expect(difference.missing.isEmpty, "Routes missing from the server source: \(difference.missing)")
        #expect(difference.unexpected.isEmpty, "Routes present but not in the pinned manifest: \(difference.unexpected)")
        #expect(duplicatedSignatures(in: signatures).isEmpty, "Duplicate route signatures: \(duplicatedSignatures(in: signatures))")
    }

    @Test("Exactly 20 routes are gated and exactly one is the classified liveness probe")
    func gatedAndUngatedSplitIsExact() throws {
        let source = try serverSourceText()
        let registrations = parseRouteRegistrations(inSource: source)

        let gated = registrations.filter(\.isGated).compactMap(\.signature)
        let ungated = registrations.filter { !$0.isGated }.compactMap(\.signature)

        #expect(gated.count == 20, "Expected exactly 20 gated routes, found \(gated.count)")
        #expect(Set(gated) == expectedGatedRouteSignatures)

        #expect(ungated == [expectedUngatedRouteSignature], "Ungated routes: \(ungated)")
    }

    @Test("The one ungated route is exactly the one entry in the runtime allowlist")
    func ungatedRouteMatchesRuntimeAllowlist() throws {
        let source = try serverSourceText()
        let ungated = parseRouteRegistrations(inSource: source)
            .filter { !$0.isGated }
            .compactMap(\.signature)

        // Ties the source-level manifest to the runtime exposure decision: the route
        // registered outside the gate and the route classified as safe without a
        // credential must be the same single route, spelled identically.
        #expect(Set(ungated) == unauthenticatedRouteAllowlist)
        #expect(unauthenticatedRouteAllowlist.count == 1)
    }

    // MARK: Negative controls — the manifest must be able to fail

    @Test("Positive control: the parser reads every registration form used in the server")
    func parserHandlesEveryRegistrationForm() {
        let signatures = parseRouteRegistrations(inSource: registrationFixture).compactMap(\.signature)

        #expect(Set(signatures) == fixtureSignatures)
        #expect(signatures.count == 6)
        #expect(inventoryDifference(observed: signatures, expected: fixtureSignatures).isClean)
    }

    @Test("Negative control: a deleted route is reported as missing")
    func deletedRouteIsDetected() {
        let mutated = registrationFixture.replacingOccurrences(
            of: #"        apiV1.get("records") { req async throws -> Response in"#,
            with: ""
        )

        let signatures = parseRouteRegistrations(inSource: mutated).compactMap(\.signature)
        let difference = inventoryDifference(observed: signatures, expected: fixtureSignatures)

        #expect(signatures.count == 5)
        #expect(difference.isClean == false)
        #expect(difference.missing == ["GET /api/v1/records"])
        #expect(difference.unexpected.isEmpty)
    }

    @Test("Negative control: a renamed path is reported as both missing and unexpected")
    func renamedRouteIsDetected() {
        let mutated = registrationFixture.replacingOccurrences(of: #""records""#, with: #""observations""#)

        let signatures = parseRouteRegistrations(inSource: mutated).compactMap(\.signature)
        let difference = inventoryDifference(observed: signatures, expected: fixtureSignatures)

        #expect(difference.isClean == false)
        #expect(difference.missing == ["GET /api/v1/records"])
        #expect(difference.unexpected == ["GET /api/v1/observations"])
    }

    @Test("Negative control: a changed HTTP method is reported")
    func changedMethodIsDetected() {
        let mutated = registrationFixture.replacingOccurrences(of: ".PATCH,", with: ".PUT,")

        let signatures = parseRouteRegistrations(inSource: mutated).compactMap(\.signature)
        let difference = inventoryDifference(observed: signatures, expected: fixtureSignatures)

        #expect(difference.missing == ["PATCH /api/v1/standards/:standardID/status"])
        #expect(difference.unexpected == ["PUT /api/v1/standards/:standardID/status"])
    }

    @Test("Negative control: a route moved off the gate onto the application is seen as ungated")
    func routeMovedOffTheGateIsDetected() {
        let mutated = registrationFixture.replacingOccurrences(
            of: #"apiV1.get("records")"#,
            with: #"app.get("api", "v1", "records")"#
        )

        let registrations = parseRouteRegistrations(inSource: mutated)
        let ungated = registrations.filter { !$0.isGated }.compactMap(\.signature)

        // The signature is unchanged, so a set comparison alone would stay green — the
        // gated/ungated split is what catches this, which is why it is asserted
        // separately in `gatedAndUngatedSplitIsExact`.
        #expect(Set(registrations.compactMap(\.signature)) == fixtureSignatures)
        #expect(ungated.sorted() == ["GET /api/v1/records", "GET /health/db"])
        #expect(ungated.count != 1)
    }

    @Test("Negative control: a grouping verb yields no HTTP method and is therefore flagged")
    func groupingVerbIsFlagged() {
        let mutated = registrationFixture + "\n        app.grouped(\"internal\") { builder in"

        let registrations = parseRouteRegistrations(inSource: mutated)
        let methodless = registrations.filter { $0.method == nil }

        #expect(methodless.count == 1)
        #expect(methodless.first?.verb == "grouped")
        #expect(methodless.first?.builder == "app")
    }
}
