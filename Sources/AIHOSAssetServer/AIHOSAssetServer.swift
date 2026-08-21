import Vapor
import Fluent
import FluentPostgresDriver
import SQLKit
import Foundation
#if canImport(Speech)
import Speech
#endif

#if canImport(Speech)
actor AppleSpeechTranscriber {
    enum TranscriptionOutcome {
        case text(String)
        case null(reason: String)
    }

    enum TranscriptionError: Error {
        case recognizerUnavailable
        case authorizationDenied
        case authorizationRestricted
        case authorizationNotDetermined
        case emptyResult
    }

    func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionOutcome {
        let authorizationStatus = await resolvedSpeechAuthorizationStatus()

        switch authorizationStatus {
        case .authorized:
            break
        case .denied:
            throw TranscriptionError.authorizationDenied
        case .restricted:
            throw TranscriptionError.authorizationRestricted
        case .notDetermined:
            throw TranscriptionError.authorizationNotDetermined
        @unknown default:
            throw TranscriptionError.authorizationRestricted
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let transcription = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var didResume = false

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result else { return }

                if result.isFinal {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }

        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscription.isEmpty else {
            return .null(reason: "Apple Speech returned empty transcription")
        }

        return .text(trimmedTranscription)
    }

    private func resolvedSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()

        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
    }
}
#else
actor AppleSpeechTranscriber {
    enum TranscriptionOutcome {
        case text(String)
        case null(reason: String)
    }

    func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionOutcome {
        return .null(reason: "Apple Speech is unavailable on this server runtime")
    }
}
#endif

/// The server itself: configuration, migrations, routes and startup.
///
/// This type carries no program entry point. The entry point lives in the separate
/// `AIHOSAssetServerRun` target, as top-level code in its `main.swift`, so that this
/// module can be built as a library and imported by the test bundle — an entry point
/// in the tested module is what previously stopped the suite from running in release
/// configuration.
///
/// `public` reaches exactly as far as the runner needs and no further: the type and
/// its start access only. Migrations, DTOs, `Content` types and every other symbol
/// stay internal, so the module's surface has not widened.
public struct AIHOSAssetServer {
    /// Starts the server. Called by the runner target's entry point.
    public static func main() async throws {
        let app = try await Application.make(.detect())
        defer {
            Task {
                try? await app.asyncShutdown()
            }
        }

        // Fail-closed before anything else starts: an unrecognised bind address refuses
        // startup rather than falling back to a default that might expose more than
        // intended. Absent variable keeps today's 0.0.0.0 binding unchanged.
        let serverHost = try resolvedServerHost()
        app.http.server.configuration.hostname = serverHost
        if let portString = Environment.get("PORT"), let port = Int(portString) {
            app.http.server.configuration.port = port
            print("HTTP Server Port from Render PORT: \(port)")
        } else {
            app.http.server.configuration.port = 8080
            print("HTTP Server Port default: 8080")
        }
        print("HTTP Server Host: \(serverHost)")

        if let databaseURL = Environment.get("DATABASE_URL") {
            var configuration = try SQLPostgresConfiguration(url: databaseURL)

            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none

            configuration.coreConfiguration.tls = try .require(.init(configuration: tlsConfiguration))

            app.databases.use(
                .postgres(configuration: configuration),
                as: .psql
            )

            print("PostgreSQL configuration registered from DATABASE_URL with explicit TLS override")
        } else {
            app.databases.use(
                .postgres(
                    configuration: .init(
                        hostname: "localhost",
                        port: 5432,
                        username: "tibi",
                        password: nil,
                        database: "tibi",
                        tls: .disable
                    )
                ),
                as: .psql
            )
            print("PostgreSQL local configuration registered")
        }

        app.migrations.add(CreateAssetRecords())
        app.migrations.add(CreateSubordinateTracks())
        app.migrations.add(CreateOperationalStandards())
        app.migrations.add(AddOperationalStandardsGovernanceFields())
        app.migrations.add(CreateDecisionTraces())
        app.migrations.add(AddObservationDecisionTraceTarget())
        app.migrations.add(ActivateDecisionTraceGovernanceTriggers())
        app.migrations.add(CreatePayloadTextStorage())
        app.migrations.add(CreateLaneMetadataFoundation())
        app.migrations.add(CreateGovernanceTriggers())
        app.migrations.add(ActivateOperationalStandardsGovernanceTriggers())
        app.migrations.add(CreateStandardStatusUpdates())

        print("Migration registered: CreateAssetRecords")
        print("Migration registered: CreateSubordinateTracks")
        print("Migration registered: CreateOperationalStandards")
        print("Migration registered: AddOperationalStandardsGovernanceFields")
        print("Migration registered: CreateDecisionTraces")
        print("Migration registered: AddObservationDecisionTraceTarget")
        print("Migration registered: ActivateDecisionTraceGovernanceTriggers")
        print("Migration registered: CreatePayloadTextStorage")
        print("Migration registered: CreateLaneMetadataFoundation")
        print("Migration registered: CreateGovernanceTriggers")
        print("Migration registered: ActivateOperationalStandardsGovernanceTriggers")
        print("Migration registered: CreateStandardStatusUpdates")

        try await app.autoMigrate()
        print("Database migrations executed")
        let storageDirectory = try resolvedStorageDirectory()
        print("workingDirectory: \(app.directory.workingDirectory)")

        // Fail-closed: a missing or non-IANA OPERATIONS_TIMEZONE refuses startup rather
        // than defaulting, because a guessed zone would compute every hotel day
        // boundary wrong while the server looked healthy. Interim value is supplied per
        // deployment; no zone name is hardcoded anywhere in this source.
        let operationsTimeZone = try resolvedOperationsTimeZone()
        print("Operations time zone configured: \(operationsTimeZone.identifier)")

        // Central machine-to-machine auth gate. Every production-affecting route below is
        // registered on `apiV1` or `gated`, never on `app` — see MachineAuthGate.swift.
        // The only route allowed on `app` is the liveness probe, which is classified in
        // `unauthenticatedRouteAllowlist`; boot fails if anything else escapes the gate.
        let machineCredential = MachineCredential.resolveFromEnvironment()
        print(machineCredential.configurationStatusDescription)
        let apiV1 = MachineGatedRoutes(application: app, pathPrefix: ["api", "v1"], credential: machineCredential)
        let gated = MachineGatedRoutes(application: app, credential: machineCredential)

        // Deliberately outside the gate: liveness probe only. Reports whether
        // `SELECT 1` succeeded and exposes no product data, credentials or configuration.
        registerDatabaseHealthRoutes(on: app)

        registerImmutabilityDiagnosticRoutes(on: gated)

        registerVisionOCRDiagnosticRoutes(on: gated, storageDirectory: storageDirectory)

        registerImageSyncIngestionRoutes(on: apiV1, storageDirectory: storageDirectory)

        registerAudioIngestionRoutes(on: apiV1, storageDirectory: storageDirectory)

        registerObservationRecordReadRoutes(on: apiV1, storageDirectory: storageDirectory)

        registerOperationalStandardReadRoutes(on: apiV1)

        registerOperationalStandardCreateRoutes(on: apiV1)

        registerOperationalStandardStatusRoutes(on: apiV1)

        registerStandardStatusTimelineReadRoutes(on: apiV1)

        registerShiftHandoverReadRoutes(on: apiV1)

        registerObservationDecisionTraceWriteRoutes(on: apiV1)

        registerObservationDecisionTraceReadRoutes(on: apiV1)

        registerFileDeliveryRoutes(on: apiV1, storageDirectory: storageDirectory)

        registerPayloadTextWriteRoutes(on: apiV1)

        registerPayloadTextReadRoutes(on: apiV1)

        registerVoiceTranscriptionRoutes(on: apiV1, storageDirectory: storageDirectory)

        registerNightPhotoStandardRoutes(on: apiV1)

        registerDecisionTraceFixationRoutes(on: apiV1)

        registerMechanicalGapReadRoutes(on: apiV1, operationsTimeZone: operationsTimeZone)

        registerOperationalPulseReadRoutes(on: apiV1, operationsTimeZone: operationsTimeZone)

        // Fail-closed coverage check: refuse to start if any route was registered
        // outside the central gate without an explicit unauthenticated classification.
        try verifyMachineGateCoverage(routes: app.routes.all)
        print("Machine auth gate coverage verified for \(app.routes.all.count) registered routes")

        print("AIHOS Asset Server starting")

        try await app.execute()
    }
}
