import Vapor
import Fluent
import FluentPostgresDriver
import SQLKit
import Foundation
#if canImport(Speech)
import Speech
#endif

#if canImport(Vision)
import Vision
#endif

// MARK: - Server bind address
//
// The address Vapor binds to is configuration, not a constant, so it can be moved
// between the two operating modes without a code change. Today's production mode is
// unchanged: with the variable absent the server binds to 0.0.0.0 exactly as before.
//
// The allowed set is closed on purpose, and it is a security control rather than a
// convenience. A typo in a bind address is not a cosmetic error — falling back to a
// default on an unrecognised value could turn an intended loopback-only binding into
// a broad public one, silently. So an unrecognised value refuses startup instead
// (§9.3, R17: a failing control blocks, it never lets through).
//
// This atom adds the lever only. It does not change any deployment configuration and
// proves nothing about the operational return path, which is exercised separately.

/// Name of the environment variable selecting the bind address.
let serverHostEnvironmentKey = "AIHOS_SERVER_HOST"

/// The address used when the variable is absent — byte-identical to the previous
/// hardcoded binding, so an unconfigured deployment behaves exactly as it did before.
let defaultServerHost = "0.0.0.0"

/// Every address this server may bind to.
///
/// Deliberately two entries and no parsing: all interfaces, or loopback only. There is
/// no DNS resolution, no wildcard and no arbitrary host interpretation, because each of
/// those would turn a misconfiguration into an exposure decision made by a resolver
/// rather than by a person.
let allowedServerHosts: Set<String> = ["0.0.0.0", "127.0.0.1"]

/// Raised at boot when the configured bind address is not one of the allowed ones.
struct ServerHostError: Error, CustomStringConvertible {
    var description: String {
        "\(serverHostEnvironmentKey) must be set to exactly one of "
            + allowedServerHosts.sorted().joined(separator: " or ")
            + ", or left unset to bind \(defaultServerHost). The configured value was not accepted."
    }
}

/// Resolves the bind address from a raw configuration value.
///
/// Kept separate from the environment lookup so the fail-closed rule can be tested
/// without mutating process environment state — same shape as `MachineCredential` and
/// the operations time zone.
///
/// Absent means "unconfigured" and yields the default. Present but empty, blank or
/// unrecognised is a configuration mistake and throws: a variable someone took the
/// trouble to set, but set wrongly, must never be silently ignored.
///
/// The rejected value is deliberately not echoed. With only two valid values the error
/// is already fully actionable, and echoing whatever ended up in the variable would
/// write it to the boot log — which matters if it was pasted there by mistake.
func resolvedServerHost(fromConfiguredValue value: String?) throws -> String {
    guard let value else {
        return defaultServerHost
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

    guard allowedServerHosts.contains(trimmed) else {
        throw ServerHostError()
    }

    return trimmed
}

/// Resolves the bind address from the process environment.
func resolvedServerHost() throws -> String {
    try resolvedServerHost(fromConfiguredValue: Environment.get(serverHostEnvironmentKey))
}

func resolvedStorageDirectory() throws -> String {
    guard let rawStoragePath = Environment.get("STORAGE_PATH")?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawStoragePath.isEmpty else {
        print("STORAGE_PATH missing — server startup refused")
        throw Abort(.internalServerError, reason: "STORAGE_PATH is required")
    }

    guard rawStoragePath.hasPrefix("/") else {
        print("STORAGE_PATH invalid — absolute path required: \(rawStoragePath)")
        throw Abort(.internalServerError, reason: "STORAGE_PATH must be an absolute path")
    }

    let normalizedStoragePath = rawStoragePath.hasSuffix("/")
        ? String(rawStoragePath.dropLast())
        : rawStoragePath

    do {
        try FileManager.default.createDirectory(
            atPath: normalizedStoragePath,
            withIntermediateDirectories: true
        )

        let writeTestPath = normalizedStoragePath + "/.aihos-storage-write-test"
        try Data("ok".utf8).write(to: URL(fileURLWithPath: writeTestPath))
        try FileManager.default.removeItem(atPath: writeTestPath)
    } catch {
        print("STORAGE_PATH validation failed: \(error)")
        throw Abort(.internalServerError, reason: "STORAGE_PATH is not writable")
    }

    print("Storage configuration PASS")
    print("STORAGE_PATH: \(rawStoragePath)")
    print("storageDirectory: \(normalizedStoragePath)")

    return normalizedStoragePath
}
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

#if canImport(Vision)

actor AppleVisionOCRVerifier {
    enum OCROutcome {
        case text(String)
        case null(reason: String)
    }

    func recognizeText(in imageURL: URL) async throws -> OCROutcome {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let requestHandler = VNImageRequestHandler(url: imageURL)
        try requestHandler.perform([request])

        let observations = request.results ?? []
        let recognizedLines = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }

        let rawText = recognizedLines.joined(separator: "\n")
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawText.isEmpty else {
            return .null(reason: "Apple Vision OCR returned no readable text")
        }

        return .text(rawText)
    }
}
#else
actor AppleVisionOCRVerifier {
    enum OCROutcome {
        case text(String)
        case null(reason: String)
    }

    func recognizeText(in imageURL: URL) async throws -> OCROutcome {
        return .null(reason: "Apple Vision OCR is unavailable on this server runtime")
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

        // Accepts uploads up to 10 MB and runs OCR on the server - gated (PSKS-008).
        gated.on(.POST, "test", "vision-ocr", body: .collect(maxSize: "10mb")) { req async throws -> Response in
            let payload: MultipartSyncPayload

            do {
                payload = try req.content.decode(MultipartSyncPayload.self)
            } catch {
                print("Vision OCR test multipart parsing failed: \(error)")
                return Response(status: .badRequest)
            }

            let testDirectory = storageDirectory + "/OCRTest"
            let testFileName = "vision-ocr-test-\(UUID().uuidString).jpg"
            let testFilePath = testDirectory + "/" + testFileName
            let testFileURL = URL(fileURLWithPath: testFilePath)

            do {
                try FileManager.default.createDirectory(
                    atPath: testDirectory,
                    withIntermediateDirectories: true
                )

                try Data(buffer: payload.image.data).write(to: testFileURL)
                print("Vision OCR test image save PASS")
                print("testFilePath: \(testFilePath)")
            } catch {
                print("Vision OCR test image save failed: \(error)")
                return Response(status: .internalServerError)
            }

            let verifier = AppleVisionOCRVerifier()
            let outcome: AppleVisionOCRVerifier.OCROutcome

            do {
                outcome = try await verifier.recognizeText(in: testFileURL)
            } catch {
                print("Vision OCR honest error: \(error)")
                let response = Response(status: .internalServerError)
                try response.content.encode(
                    VisionOCRTestResponse(
                        ocrStatus: "error",
                        rawText: nil,
                        reason: String(describing: error)
                    )
                )
                return response
            }

            let response = Response(status: .ok)

            switch outcome {
            case .text(let rawText):
                print("Vision OCR technical verification PASS")
                print("ocrStatus: text")
                print("rawText: \(rawText)")
                try response.content.encode(
                    VisionOCRTestResponse(
                        ocrStatus: "text",
                        rawText: rawText,
                        reason: nil
                    )
                )
            case .null(let reason):
                print("Vision OCR technical verification PASS")
                print("ocrStatus: null")
                print("reason: \(reason)")
                try response.content.encode(
                    VisionOCRTestResponse(
                        ocrStatus: "null",
                        rawText: nil,
                        reason: reason
                    )
                )
            }

            return response
        }

        apiV1.on(.POST, "sync", body: .collect(maxSize: "10mb")) { req async throws -> HTTPStatus in
            let payload: MultipartSyncPayload

            do {
                payload = try req.content.decode(MultipartSyncPayload.self)
            } catch {
                print("Multipart parsing failed: \(error)")
                return .badRequest
            }

            let metadataData = Data(payload.metadata.utf8)
            let metadata: SyncMetadata

            do {
                metadata = try JSONDecoder().decode(SyncMetadata.self, from: metadataData)
            } catch {
                print("Metadata decode failed: \(error)")
                return .badRequest
            }

            // Canonical ingest contract, enforced before anything is written: no file on
            // disk, no row, no partial state. A 13-digit millisecond value is refused
            // rather than normalised — guessing the client's unit is how silent data
            // corruption starts.
            guard isCanonicalCaptureTimestamp(metadata.captureTimestamp) else {
                print("Capture timestamp rejected: not a 10-digit Unix epoch in seconds")
                return .badRequest
            }

            // Validate laneKey before any DB write
            print("Received laneKey: \(metadata.laneKey ?? "nil")")
            guard let laneKey = validatedLaneKey(metadata.laneKey) else {
                print("Lane validation failed")
                return .badRequest
            }

            // Validate observationID before any DB write (Build Atom 5B-3)
            let sharedObservationID: UUID?
            if let rawObservationID = metadata.observationID, !rawObservationID.isEmpty {
                guard let parsedObservationID = UUID(uuidString: rawObservationID) else {
                    print("Invalid observationID received: \(rawObservationID)")
                    return .badRequest
                }
                sharedObservationID = parsedObservationID
            } else {
                sharedObservationID = nil
            }

            let imageSize = payload.image.data.readableBytes
            let storedFileName = metadata.fileName ?? "\(UUID().uuidString).jpg"
            let storedFilePath = storageDirectory + "/" + storedFileName
            let forceTransactionalFailure = storedFileName == "test-force-transaction-failure.jpg"

            do {
                try FileManager.default.createDirectory(
                    atPath: storageDirectory,
                    withIntermediateDirectories: true
                )

                try Data(buffer: payload.image.data).write(to: URL(fileURLWithPath: storedFilePath))
                print("Payload file save PASS")
                print("storedFilePath: \(storedFilePath)")
            } catch {
                print("Payload file save failed: \(error)")
                return .internalServerError
            }

            do {
                try await req.db.transaction { database in
                    guard let sql = database as? SQLDatabase else {
                        throw Abort(.internalServerError, reason: "SQL database unavailable inside transaction")
                    }

                    let recordID = sharedObservationID ?? UUID()
                    let fileID = UUID()

                    let existingRecordRows = try await sql.raw("""
                    SELECT id FROM asset_records WHERE id = \(bind: recordID);
                    """).all()

                    if existingRecordRows.isEmpty {
                        print("SHARED OBSERVATION IDENTITY: NEW asset_record CREATED: \(recordID.uuidString)")
                    } else {
                        print("SHARED OBSERVATION IDENTITY: EXISTING asset_record REUSED: \(recordID.uuidString)")
                    }

                    try await sql.raw("""
                    INSERT INTO asset_records (id, "captureTimestamp", "sourceTag", lane_key)
                    VALUES (\(bind: recordID), \(bind: metadata.captureTimestamp), \(bind: metadata.sourceTag), \(bind: laneKey))
                    ON CONFLICT (id) DO NOTHING;
                    """).run()

                    if forceTransactionalFailure {
                        print("Intentional transactional failure requested")
                        let missingRecordID = UUID()

                        try await sql.raw("""
                        INSERT INTO asset_files (id, "assetRecordID", "fileName")
                        VALUES (\(bind: fileID), \(bind: missingRecordID), \(bind: storedFileName));
                        """).run()
                    } else {
                        try await sql.raw("""
                        INSERT INTO asset_files (id, "assetRecordID", "fileName")
                        VALUES (\(bind: fileID), \(bind: recordID), \(bind: storedFileName));
                        """).run()

                        let resolvedPayloadText = payload.payloadText ?? metadata.payloadText

                        if let payloadText = resolvedPayloadText, !payloadText.isEmpty {
                            let payloadTextID = UUID()
                            let createdAt = ISO8601DateFormatter().string(from: Date())
                            let payloadTextSourceTag = metadata.payloadTextSourceTag ?? "[S]"

                            try await sql.raw("""
                            INSERT INTO asset_payload_texts
                            (id, "assetRecordID", payload_text, source_tag, created_at)
                            VALUES
                            (\(bind: payloadTextID), \(bind: recordID), \(bind: payloadText), \(bind: payloadTextSourceTag), \(bind: createdAt));
                            """).run()

                            print("Transactional payload_text INSERT PASS")
                            print("payloadTextID: \(payloadTextID.uuidString)")
                            print("payloadTextSourceTag: \(payloadTextSourceTag)")
                            print("payloadTextLength: \(payloadText.count)")
                        } else {
                            print("No payload_text provided for sync payload")
                            print("multipartPayloadTextPresent: \(payload.payloadText != nil)")
                            print("metadataPayloadTextPresent: \(metadata.payloadText != nil)")
                        }
                    }

                    print("Transactional asset_record INSERT PASS")
                    print("Transactional asset_file INSERT PASS")
                    print("assetRecordID: \(recordID.uuidString)")
                    print("assetFileID: \(fileID.uuidString)")
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: storedFilePath) {
                        try FileManager.default.removeItem(atPath: storedFilePath)
                        print("Rollback cleanup PASS: saved payload file deleted")
                    } else {
                        print("Rollback cleanup PASS: no saved payload file found")
                    }
                } catch {
                    print("Rollback cleanup FAILED: saved payload file could not be deleted: \(error)")
                }

                print("Transactional payload fixation failed: \(error)")
                return .internalServerError
            }

            print("[M] Payload fixed transactionally. Tid: \(metadata.captureTimestamp). Bildstorlek: \(imageSize) bytes.")
            print("sourceTag: \(metadata.sourceTag)")
            print("fileName: \(storedFileName)")
            print("storedFilePath: \(storedFilePath)")

            return .ok
        }

        apiV1.on(.POST, "audio", body: .collect(maxSize: "20mb")) { req async throws -> HTTPStatus in
            let payload: MultipartAudioPayload

            do {
                payload = try req.content.decode(MultipartAudioPayload.self)
            } catch {
                print("Audio multipart parsing failed: \(error)")
                return .badRequest
            }

            let metadataData = Data(payload.metadata.utf8)
            let metadata: SyncMetadata

            do {
                metadata = try JSONDecoder().decode(SyncMetadata.self, from: metadataData)
            } catch {
                print("Audio metadata decode failed: \(error)")
                return .badRequest
            }

            // Same canonical ingest contract as /sync, enforced before the audio file is
            // written so a rejected upload leaves nothing behind.
            guard isCanonicalCaptureTimestamp(metadata.captureTimestamp) else {
                print("Audio capture timestamp rejected: not a 10-digit Unix epoch in seconds")
                return .badRequest
            }

            guard let laneKey = validatedLaneKey(metadata.laneKey) else {
                print("Audio lane validation failed")
                return .badRequest
            }

            // Validate observationID before any DB write (Build Atom 5B-3)
            let sharedObservationID: UUID?
            if let rawObservationID = metadata.observationID, !rawObservationID.isEmpty {
                guard let parsedObservationID = UUID(uuidString: rawObservationID) else {
                    print("Invalid observationID received: \(rawObservationID)")
                    return .badRequest
                }
                sharedObservationID = parsedObservationID
            } else {
                sharedObservationID = nil
            }

            let audioSize = payload.audio.data.readableBytes
            let storedFileName = metadata.fileName ?? "\(UUID().uuidString).m4a"
            let storedFilePath = storageDirectory + "/" + storedFileName

            do {
                try FileManager.default.createDirectory(
                    atPath: storageDirectory,
                    withIntermediateDirectories: true
                )

                guard !FileManager.default.fileExists(atPath: storedFilePath) else {
                    print("Audio file save rejected: file already exists \(storedFileName)")
                    return .conflict
                }

                try Data(buffer: payload.audio.data).write(to: URL(fileURLWithPath: storedFilePath))
                print("Audio file save PASS")
                print("storedFilePath: \(storedFilePath)")
            } catch {
                print("Audio file save failed: \(error)")
                return .internalServerError
            }

            do {
                try await req.db.transaction { database in
                    guard let sql = database as? SQLDatabase else {
                        throw Abort(.internalServerError, reason: "SQL database unavailable inside audio transaction")
                    }

                    let recordID = sharedObservationID ?? UUID()
                    let fileID = UUID()

                    let existingRecordRows = try await sql.raw("""
                    SELECT id FROM asset_records WHERE id = \(bind: recordID);
                    """).all()

                    if existingRecordRows.isEmpty {
                        print("SHARED OBSERVATION IDENTITY: NEW asset_record CREATED: \(recordID.uuidString)")
                    } else {
                        print("SHARED OBSERVATION IDENTITY: EXISTING asset_record REUSED: \(recordID.uuidString)")
                    }

                    try await sql.raw("""
                    INSERT INTO asset_records (id, "captureTimestamp", "sourceTag", lane_key)
                    VALUES (\(bind: recordID), \(bind: metadata.captureTimestamp), \(bind: metadata.sourceTag), \(bind: laneKey))
                    ON CONFLICT (id) DO NOTHING;
                    """).run()

                    try await sql.raw("""
                    INSERT INTO asset_files (id, "assetRecordID", "fileName")
                    VALUES (\(bind: fileID), \(bind: recordID), \(bind: storedFileName));
                    """).run()

                    let resolvedPayloadText = payload.payloadText ?? metadata.payloadText

                    if let payloadText = resolvedPayloadText, !payloadText.isEmpty {
                        let payloadTextID = UUID()
                        let createdAt = ISO8601DateFormatter().string(from: Date())
                        let payloadTextSourceTag = metadata.payloadTextSourceTag ?? "[S]"

                        try await sql.raw("""
                        INSERT INTO asset_payload_texts
                        (id, "assetRecordID", payload_text, source_tag, created_at)
                        VALUES
                        (\(bind: payloadTextID), \(bind: recordID), \(bind: payloadText), \(bind: payloadTextSourceTag), \(bind: createdAt));
                        """).run()

                        print("Audio transactional payload_text INSERT PASS")
                        print("payloadTextID: \(payloadTextID.uuidString)")
                        print("payloadTextSourceTag: \(payloadTextSourceTag)")
                        print("payloadTextLength: \(payloadText.count)")
                    } else {
                        print("No payload_text provided for audio payload")
                        print("multipartPayloadTextPresent: \(payload.payloadText != nil)")
                        print("metadataPayloadTextPresent: \(metadata.payloadText != nil)")
                    }

                    print("Audio asset_record INSERT PASS")
                    print("Audio asset_file INSERT PASS")
                    print("assetRecordID: \(recordID.uuidString)")
                    print("assetFileID: \(fileID.uuidString)")
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: storedFilePath) {
                        try FileManager.default.removeItem(atPath: storedFilePath)
                        print("Audio rollback cleanup PASS: saved audio file deleted")
                    } else {
                        print("Audio rollback cleanup PASS: no saved audio file found")
                    }
                } catch {
                    print("Audio rollback cleanup FAILED: saved audio file could not be deleted: \(error)")
                }

                print("Transactional audio fixation failed: \(error)")
                return .internalServerError
            }

            print("[M] Audio fixed transactionally. Tid: \(metadata.captureTimestamp). Ljudstorlek: \(audioSize) bytes.")
            print("sourceTag: \(metadata.sourceTag)")
            print("laneKey: \(laneKey)")
            print("fileName: \(storedFileName)")
            print("storedFilePath: \(storedFilePath)")

            return .ok
        }

        apiV1.get("records") { req async throws -> Response in
            let sql = req.db as! SQLDatabase

            let rows = try await sql.raw("""
                SELECT
                    asset_records.id,
                    asset_records."captureTimestamp",
                    asset_records."sourceTag",
                    asset_records.lane_key,
                    asset_files."fileName"
                FROM asset_records
                INNER JOIN asset_files
                    ON asset_files."assetRecordID" = asset_records.id
                ORDER BY asset_records."captureTimestamp" ASC
            """).all()


            var groupOrder: [String] = []
            var groupsByID: [String: GroupedObservationResponse] = [:]
            var missingFileCount = 0

            for row in rows {
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let captureTimestamp = try row.decode(column: "captureTimestamp", as: String.self)
                let sourceTag = try row.decode(column: "sourceTag", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)
                let fileName = try row.decode(column: "fileName", as: String.self)
                let filePath = storageDirectory + "/" + fileName

                guard FileManager.default.fileExists(atPath: filePath) else {
                    missingFileCount += 1
                    print("Observation retrieval skipped missing payload file: \(fileName)")
                    continue
                }

                if let existing = groupsByID[id] {
                    groupsByID[id] = GroupedObservationResponse(
                        id: existing.id,
                        captureTimestamp: existing.captureTimestamp,
                        displayTimestamp: existing.displayTimestamp,
                        sourceTag: existing.sourceTag,
                        laneKey: existing.laneKey,
                        files: existing.files + [fileName]
                    )
                } else {
                    groupOrder.append(id)
                    groupsByID[id] = GroupedObservationResponse(
                        id: id,
                        captureTimestamp: captureTimestamp,
                        displayTimestamp: humanReadableTimestamp(captureTimestamp),
                        sourceTag: sourceTag,
                        laneKey: laneKey,
                        files: [fileName]
                    )
                }
            }

            var records: [GroupedObservationResponse] = groupOrder.compactMap { groupsByID[$0] }

            print("Observation retrieval file integrity filter PASS")
            print("Observation records returned: \(records.count)")
            print("Observation records skipped missing files: \(missingFileCount)")

            records.sort { first, second in
                let firstDate = parsedTimestampDate(first.captureTimestamp) ?? Date.distantPast
                let secondDate = parsedTimestampDate(second.captureTimestamp) ?? Date.distantPast
                return firstDate > secondDate
            }

            let response = Response(status: .ok)
            try response.content.encode(records)
            return response
        }

        apiV1.get("standards") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    lane_key,
                    track_type,
                    expected_window_start,
                    expected_window_end,
                    "requiredCount",
                    status,
                    created_at
                FROM operational_standards
                ORDER BY created_at ASC
            """).all()

            let standards = try rows.map { row -> OperationalStandardResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let standardKey = try row.decode(column: "standardKey", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)
                let trackType = try row.decode(column: "track_type", as: String.self)
                let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
                let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
                let requiredCount = try row.decode(column: "requiredCount", as: Int.self)
                let status = try row.decode(column: "status", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)

                return OperationalStandardResponse(
                    id: id,
                    standardKey: standardKey,
                    laneKey: laneKey,
                    trackType: trackType,
                    expectedWindowStart: expectedWindowStart,
                    expectedWindowEnd: expectedWindowEnd,
                    requiredCount: requiredCount,
                    status: status,
                    createdAt: createdAt
                )
            }

            print("Operational Standards retrieval PASS: \(standards.count) standards")
            print("Operational Standards sort: createdAt ASC")
            print("Operational Standards source: server-side operational_standards")

            let response = Response(status: .ok)
            try response.content.encode(standards)
            return response
        }

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

        apiV1.on(.PATCH, "standards", ":standardID", "status") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let standardIDString = req.parameters.get("standardID"),
                  let standardID = UUID(uuidString: standardIDString) else {
                print("Operational Standard status update failed: invalid standardID")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "invalid operational standard id"
                ])
                return response
            }

            let payload: OperationalStandardStatusUpdateRequest

            do {
                payload = try req.content.decode(OperationalStandardStatusUpdateRequest.self)
            } catch {
                print("Operational Standard status update failed: payload decode error \(error)")
                return Response(status: .badRequest)
            }

            if payload.standardKey != nil
                || payload.laneKey != nil
                || payload.trackType != nil
                || payload.expectedWindowStart != nil
                || payload.expectedWindowEnd != nil
                || payload.requiredCount != nil
                || payload.createdAt != nil {
                print("Operational Standard status update blocked: core metadata mutation attempted")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "Mutation of core metadata is not allowed."
                ])
                return response
            }

            guard payload.status == "ACTIVE" || payload.status == "PAUSED" else {
                print("Operational Standard status update failed: invalid status \(payload.status)")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "status must be ACTIVE or PAUSED"
                ])
                return response
            }

            let existingRows = try await sql.raw("""
                SELECT id
                FROM operational_standards
                WHERE id = \(bind: standardID)
            """).all()

            guard existingRows.count == 1 else {
                print("Operational Standard status update failed: standard not found \(standardID.uuidString)")
                return Response(status: .notFound)
            }

            let statusUpdateID = UUID()
            let changedAt = ISO8601DateFormatter().string(from: Date())
            let statusSourceTag = "[M]"

            do {
                try await req.db.transaction { database in
                    guard let transactionSQL = database as? SQLDatabase else {
                        throw Abort(.internalServerError, reason: "SQL database unavailable inside status update transaction")
                    }

                    try await transactionSQL.raw("""
                        UPDATE operational_standards
                        SET status = \(bind: payload.status)
                        WHERE id = \(bind: standardID)
                    """).run()

                    try await transactionSQL.raw("""
                        INSERT INTO standard_status_updates
                        (id, standard_id, status, source_tag, changed_at)
                        VALUES
                        (\(bind: statusUpdateID), \(bind: standardID), \(bind: payload.status), \(bind: statusSourceTag), \(bind: changedAt));
                    """).run()
                }
            } catch {
                print("Operational Standard status update failed: \(error)")
                return Response(status: .internalServerError)
            }

            let updatedRows = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    lane_key,
                    track_type,
                    expected_window_start,
                    expected_window_end,
                    "requiredCount",
                    status,
                    created_at
                FROM operational_standards
                WHERE id = \(bind: standardID)
                LIMIT 1
            """).all()

            guard updatedRows.count == 1 else {
                print("Operational Standard status update failed: updated row missing \(standardID.uuidString)")
                return Response(status: .internalServerError)
            }

            let row = updatedRows[0]
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let standardKey = try row.decode(column: "standardKey", as: String.self)
            let laneKey = try row.decode(column: "lane_key", as: String.self)
            let trackType = try row.decode(column: "track_type", as: String.self)
            let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
            let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
            let requiredCount = try row.decode(column: "requiredCount", as: Int.self)
            let status = try row.decode(column: "status", as: String.self)
            let createdAt = try row.decode(column: "created_at", as: String.self)

            print("Operational Standard status update PASS")
            print("standardID: \(standardID.uuidString)")
            print("status: \(status)")
            print("statusUpdateID: \(statusUpdateID.uuidString)")
            print("sourceTag: \(statusSourceTag)")
            print("changedAt: \(changedAt)")
            print("Governance: status-only update; core metadata unchanged")
            print("Status Timeline: transition inserted append-only")

            let response = Response(status: .ok)
            try response.content.encode(
                OperationalStandardResponse(
                    id: id,
                    standardKey: standardKey,
                    laneKey: laneKey,
                    trackType: trackType,
                    expectedWindowStart: expectedWindowStart,
                    expectedWindowEnd: expectedWindowEnd,
                    requiredCount: requiredCount,
                    status: status,
                    createdAt: createdAt
                )
            )
            return response
        }

        apiV1.get("standards", ":standardID", "status-updates") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let standardIDString = req.parameters.get("standardID"),
                  let standardID = UUID(uuidString: standardIDString) else {
                print("Standard Status Timeline retrieval failed: invalid standardID")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "invalid operational standard id"
                ])
                return response
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    standard_id,
                    status,
                    source_tag,
                    changed_at
                FROM standard_status_updates
                WHERE standard_id = \(bind: standardID)
                ORDER BY changed_at ASC
            """).all()

            let updates = try rows.map { row -> StandardStatusUpdateResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let standardID = try row.decode(column: "standard_id", as: UUID.self).uuidString
                let status = try row.decode(column: "status", as: String.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let changedAt = try row.decode(column: "changed_at", as: String.self)

                return StandardStatusUpdateResponse(
                    id: id,
                    standardID: standardID,
                    status: status,
                    sourceTag: sourceTag,
                    changedAt: changedAt
                )
            }

            print("Standard Status Timeline retrieval PASS: \(updates.count) updates")
            print("standardID: \(standardID.uuidString)")
            print("Status Timeline sort: changed_at ASC")

            let response = Response(status: .ok)
            try response.content.encode(updates)
            return response
        }

        apiV1.get("shift-handover", "log") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let observationRows = try await sql.raw("""
                SELECT
                    asset_records.id,
                    asset_records."captureTimestamp",
                    asset_records."sourceTag",
                    asset_records.lane_key,
                    asset_files."fileName"
                FROM asset_records
                INNER JOIN asset_files
                    ON asset_files."assetRecordID" = asset_records.id
            """).all()

            var logEntries: [ShiftHandoverLogEntry] = []

            for row in observationRows {
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let captureTimestamp = try row.decode(column: "captureTimestamp", as: String.self)
                let sourceTag = try row.decode(column: "sourceTag", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)
                let fileName = try row.decode(column: "fileName", as: String.self)

                logEntries.append(
                    ShiftHandoverLogEntry(
                        id: id,
                        sourceTag: sourceTag,
                        eventTimestamp: captureTimestamp,
                        entryType: "Observation Record",
                        message: "Observation record: \(fileName)",
                        laneKey: laneKey
                    )
                )
            }

            let decisionRows = try await sql.raw("""
                SELECT
                    decision_traces.id,
                    decision_traces."standard_key",
                    decision_traces."expected_window_start",
                    decision_traces."expected_window_end",
                    decision_traces.target_asset_record_id,
                    decision_traces."decision_type",
                    decision_traces."source_tag",
                    decision_traces."created_at",
                    COALESCE(decision_traces.lane_key, asset_records.lane_key, 'unassigned') AS lane_key
                FROM decision_traces
                LEFT JOIN asset_records
                    ON asset_records.id = decision_traces.target_asset_record_id
            """).all()

            for row in decisionRows {
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let standardKey = try row.decode(column: "standard_key", as: String?.self)
                let expectedWindowStart = try row.decode(column: "expected_window_start", as: String?.self)
                let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String?.self)
                let targetAssetRecordID = try row.decode(column: "target_asset_record_id", as: UUID?.self)
                let decisionType = try row.decode(column: "decision_type", as: String.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)

                let message: String
                if let targetAssetRecordID {
                    message = "Observation decision trace: \(decisionType) — asset \(targetAssetRecordID.uuidString)"
                } else if let standardKey, let expectedWindowStart, let expectedWindowEnd {
                    message = "Decision trace: \(decisionType) — \(standardKey) — \(expectedWindowStart) to \(expectedWindowEnd)"
                } else {
                    message = "Decision trace: \(decisionType) — unresolved target"
                }

                logEntries.append(
                    ShiftHandoverLogEntry(
                        id: id,
                        sourceTag: sourceTag,
                        eventTimestamp: createdAt,
                        entryType: "Decision Trace",
                        message: message,
                        laneKey: laneKey
                    )
                )
            }

            logEntries.sort { first, second in
                let firstDate = parsedTimestampDate(first.eventTimestamp) ?? Date.distantPast
                let secondDate = parsedTimestampDate(second.eventTimestamp) ?? Date.distantPast
                return firstDate > secondDate
            }

            let response = Response(status: .ok)
            try response.content.encode(logEntries)
            return response
        }

        apiV1.post("assets", ":assetID", "decision-traces") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Observation Decision Trace INSERT failed: invalid assetID")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "invalid asset id"
                ])
                return response
            }

            let payload: ObservationDecisionPayload

            do {
                payload = try req.content.decode(ObservationDecisionPayload.self)
            } catch {
                print("Observation Decision Trace decode failed: \(error)")
                return Response(status: .badRequest)
            }

            guard payload.decisionType == "handled" else {
                print("Observation Decision Trace rejected: invalid decisionType \(payload.decisionType)")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "decisionType must be handled"
                ])
                return response
            }

            let assetRows = try await sql.raw("""
                SELECT id
                FROM asset_records
                WHERE id = \(bind: assetID)
                LIMIT 1
            """).all()

            guard assetRows.count == 1 else {
                print("Observation Decision Trace INSERT failed: asset not found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let decisionTraceID = UUID()
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let sourceTag = "[M]"

            do {
                try await sql.raw("""
                    INSERT INTO decision_traces
                    (id, "standard_key", "expected_window_start", "expected_window_end", target_asset_record_id, "decision_type", "source_tag", "created_at")
                    VALUES
                    (\(bind: decisionTraceID), NULL, NULL, NULL, \(bind: assetID), \(bind: payload.decisionType), \(bind: sourceTag), \(bind: createdAt));
                """).run()
            } catch {
                print("Observation Decision Trace INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Observation Decision Trace INSERT PASS")
            print("decisionTraceID: \(decisionTraceID.uuidString)")
            print("targetAssetRecordID: \(assetID.uuidString)")
            print("decisionType: \(payload.decisionType)")
            print("sourceTag: \(sourceTag)")
            print("createdAt: \(createdAt)")
            print("Governance: observation decision trace inserted append-only; standard_key remains NULL")

            let response = Response(status: .ok)
            try response.content.encode(
                ObservationDecisionTraceResponse(
                    id: decisionTraceID.uuidString,
                    targetAssetRecordID: assetID.uuidString,
                    decisionType: payload.decisionType,
                    sourceTag: sourceTag,
                    createdAt: createdAt
                )
            )
            return response
        }

        apiV1.get("assets", ":assetID", "decision-traces") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Observation Decision Trace retrieval failed: invalid assetID")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "invalid asset id"
                ])
                return response
            }

            let assetRows = try await sql.raw("""
                SELECT id
                FROM asset_records
                WHERE id = \(bind: assetID)
                LIMIT 1
            """).all()

            guard assetRows.count == 1 else {
                print("Observation Decision Trace retrieval failed: asset not found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    target_asset_record_id,
                    "decision_type",
                    "source_tag",
                    "created_at"
                FROM decision_traces
                WHERE target_asset_record_id = \(bind: assetID)
                ORDER BY "created_at" ASC
            """).all()

            let decisionTraces = try rows.map { row -> ObservationDecisionTraceResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let targetAssetRecordID = try row.decode(column: "target_asset_record_id", as: UUID.self).uuidString
                let decisionType = try row.decode(column: "decision_type", as: String.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)

                return ObservationDecisionTraceResponse(
                    id: id,
                    targetAssetRecordID: targetAssetRecordID,
                    decisionType: decisionType,
                    sourceTag: sourceTag,
                    createdAt: createdAt
                )
            }

            print("Observation Decision Trace retrieval PASS: \(decisionTraces.count) traces")
            print("targetAssetRecordID: \(assetID.uuidString)")
            print("Observation Decision Trace sort: created_at ASC")

            let response = Response(status: .ok)
            try response.content.encode(decisionTraces)
            return response
        }

        apiV1.get("files", ":fileName") { req async throws -> Response in
            guard let fileName = req.parameters.get("fileName") else {
                return Response(status: .badRequest)
            }

            let filePath = storageDirectory + "/" + fileName

            guard FileManager.default.fileExists(atPath: filePath) else {
                print("File delivery failed: missing file \(fileName)")
                return Response(status: .notFound)
            }

            print("File delivery PASS: \(fileName)")
            print("File delivery path: \(filePath)")
            return req.fileio.streamFile(at: filePath)
        }

        apiV1.post("assets", ":assetID", "payload-text") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Payload Text INSERT failed: invalid assetID")
                return Response(status: .badRequest)
            }

            let payload: PayloadTextRequest

            do {
                payload = try req.content.decode(PayloadTextRequest.self)
            } catch {
                print("Payload Text decode failed: \(error)")
                return Response(status: .badRequest)
            }

            let assetRows = try await sql.raw("""
                SELECT id
                FROM asset_records
                WHERE id = \(bind: assetID)
            """).all()

            guard assetRows.count == 1 else {
                print("Payload Text INSERT failed: asset not found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let payloadTextID = UUID()
            let createdAt = ISO8601DateFormatter().string(from: Date())

            do {
                try await sql.raw("""
                    INSERT INTO asset_payload_texts
                    (id, "assetRecordID", payload_text, source_tag, created_at)
                    VALUES
                    (\(bind: payloadTextID), \(bind: assetID), \(bind: payload.payloadText), \(bind: payload.sourceTag), \(bind: createdAt));
                """).run()
            } catch {
                print("Payload Text INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Payload Text INSERT PASS")
            print("assetRecordID: \(assetID.uuidString)")
            print("payloadTextID: \(payloadTextID.uuidString)")
            print("sourceTag: \(payload.sourceTag)")
            print("createdAt: \(createdAt)")
            print("Source Awareness: original asset unchanged; payload_text stored as subordinate representation")

            let response = Response(status: .ok)
            try response.content.encode(
                PayloadTextResponse(
                    id: payloadTextID.uuidString,
                    assetRecordID: assetID.uuidString,
                    payloadText: payload.payloadText,
                    sourceTag: payload.sourceTag,
                    createdAt: createdAt
                )
            )
            return response
        }

        apiV1.get("assets", ":assetID", "payload-text") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Payload Text retrieval failed: invalid assetID")
                return Response(status: .badRequest)
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    "assetRecordID",
                    payload_text,
                    source_tag,
                    created_at
                FROM asset_payload_texts
                WHERE "assetRecordID" = \(bind: assetID)
                ORDER BY created_at ASC
            """).all()

            let payloadTexts = try rows.map { row -> PayloadTextResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let assetRecordID = try row.decode(column: "assetRecordID", as: UUID.self).uuidString
                let payloadText = try row.decode(column: "payload_text", as: String?.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)

                return PayloadTextResponse(
                    id: id,
                    assetRecordID: assetRecordID,
                    payloadText: payloadText,
                    sourceTag: sourceTag,
                    createdAt: createdAt
                )
            }

            print("Payload Text retrieval PASS: \(payloadTexts.count) entries")
            print("Source Awareness: payload_text returned separately from original asset media")

            let response = Response(status: .ok)
            try response.content.encode(payloadTexts)
            return response
        }

        apiV1.post("assets", ":assetID", "transcribe-audio") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Mechanical transcription failed: invalid assetID")
                return Response(status: .badRequest)
            }

            let assetRows = try await sql.raw("""
                SELECT id
                FROM asset_records
                WHERE id = \(bind: assetID)
            """).all()

            guard assetRows.count == 1 else {
                print("Mechanical transcription failed: asset not found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let fileRows = try await sql.raw("""
                SELECT "fileName"
                FROM asset_files
                WHERE "assetRecordID" = \(bind: assetID)
                ORDER BY "fileName" ASC
                LIMIT 1
            """).all()

            guard fileRows.count == 1 else {
                print("Mechanical transcription failed: no audio asset file found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let fileName = try fileRows[0].decode(column: "fileName", as: String.self)
            let filePath = storageDirectory + "/" + fileName
            let fileURL = URL(fileURLWithPath: filePath)

            guard FileManager.default.fileExists(atPath: filePath) else {
                print("Mechanical transcription failed: missing audio file \(fileName)")
                return Response(status: .notFound)
            }

            let sourceTag = "[S]"
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let transcriber = AppleSpeechTranscriber()
            let outcome: AppleSpeechTranscriber.TranscriptionOutcome

            do {
                outcome = try await transcriber.transcribeAudioFile(at: fileURL)
            } catch {
                print("Mechanical transcription honest error: \(error)")
                let response = Response(status: .internalServerError)
                try response.content.encode(
                    MechanicalTranscriptionResponse(
                        assetRecordID: assetID.uuidString,
                        payloadTextID: nil,
                        payloadText: nil,
                        sourceTag: sourceTag,
                        transcriptionStatus: "error",
                        reason: String(describing: error),
                        createdAt: createdAt
                    )
                )
                return response
            }

            let payloadTextID = UUID()
            let payloadText: String?
            let transcriptionStatus: String
            let reason: String?

            switch outcome {
            case .text(let text):
                payloadText = text
                transcriptionStatus = "text"
                reason = nil
            case .null(let nullReason):
                payloadText = nil
                transcriptionStatus = "null"
                reason = nullReason
            }

            do {
                try await sql.raw("""
                    INSERT INTO asset_payload_texts
                    (id, "assetRecordID", payload_text, source_tag, created_at)
                    VALUES
                    (\(bind: payloadTextID), \(bind: assetID), \(bind: payloadText), \(bind: sourceTag), \(bind: createdAt));
                """).run()
            } catch {
                print("Mechanical transcription payload_text INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Mechanical Voice Transcription PASS")
            print("assetRecordID: \(assetID.uuidString)")
            print("fileName: \(fileName)")
            print("payloadTextID: \(payloadTextID.uuidString)")
            print("transcriptionStatus: \(transcriptionStatus)")
            print("sourceTag: \(sourceTag)")
            print("createdAt: \(createdAt)")
            print("Source Awareness: original audio unchanged; Apple Speech output stored as subordinate payload_text")

            let response = Response(status: .ok)
            try response.content.encode(
                MechanicalTranscriptionResponse(
                    assetRecordID: assetID.uuidString,
                    payloadTextID: payloadTextID.uuidString,
                    payloadText: payloadText,
                    sourceTag: sourceTag,
                    transcriptionStatus: transcriptionStatus,
                    reason: reason,
                    createdAt: createdAt
                )
            )
            return response
        }

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

        apiV1.post("decisions") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let payload: DecisionPayload

            do {
                payload = try req.content.decode(DecisionPayload.self)
            } catch {
                print("Decision payload decode failed: \(error)")
                return Response(status: .badRequest)
            }

            guard payload.decisionType == "leave_empty" else {
                print("Decision rejected: unsupported decisionType \(payload.decisionType)")
                return Response(status: .badRequest)
            }

            let decisionID = UUID()
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let sourceTag = "[M]"
            let inheritedLaneKey = "unassigned"

            do {
                try await sql.raw("""
                    INSERT INTO decision_traces
                    (id, "standard_key", "expected_window_start", "expected_window_end", "decision_type", "source_tag", "created_at", lane_key)
                    VALUES
                    (\(bind: decisionID), \(bind: payload.standardKey), \(bind: payload.expectedWindowStart), \(bind: payload.expectedWindowEnd), \(bind: payload.decisionType), \(bind: sourceTag), \(bind: createdAt), \(bind: inheritedLaneKey));
                """).run()
            } catch {
                print("Decision Trace INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Decision Trace fixation PASS")
            print("decisionID: \(decisionID.uuidString)")
            print("standardKey: \(payload.standardKey)")
            print("expectedWindowStart: \(payload.expectedWindowStart)")
            print("expectedWindowEnd: \(payload.expectedWindowEnd)")
            print("decisionType: \(payload.decisionType)")
            print("sourceTag: \(sourceTag)")
            print("createdAt: \(createdAt)")
            print("laneKey: \(inheritedLaneKey)")

            let response = Response(status: .ok)
            try response.content.encode([
                "id": decisionID.uuidString,
                "sourceTag": sourceTag,
                "decisionType": payload.decisionType,
                "standardKey": payload.standardKey,
                "expectedWindowStart": payload.expectedWindowStart,
                "expectedWindowEnd": payload.expectedWindowEnd,
                "createdAt": createdAt,
                "laneKey": inheritedLaneKey
            ])
            return response
        }

        apiV1.get("gaps", "mechanical") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }
            // The default is today in the operations zone, not in UTC: a hotel working
            // at 00:30 local is still asking about its own day.
            let requestedDate = req.query[String.self, at: "date"]
                ?? operationsDateString(for: Date(), in: operationsTimeZone)

            guard isValidISO8601DateString(requestedDate) else {
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "date must use YYYY-MM-DD format"
                ])
                return response
            }
            let standards = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    "description",
                    "sourceTag",
                    "startHour",
                    "endHour",
                    "requiredCount",
                    created_at
                FROM operational_standards
                ORDER BY "standardKey" ASC
            """).all()

            var gaps: [[String: String]] = []

            let timestampDiagnosticRows = try await sql.raw(timestampReadExpectationDiagnosticQuery()).all()
            logTimestampReadExpectationDiagnostic(
                try timestampReadExpectationDiagnostic(from: timestampDiagnosticRows),
                calculation: "gaps/mechanical",
                logger: req.logger
            )

            for standard in standards {
                let standardID = try standard.decode(column: "id", as: UUID.self)
                let standardKey = try standard.decode(column: "standardKey", as: String.self)
                let description = try standard.decode(column: "description", as: String.self)
                let sourceTag = try standard.decode(column: "sourceTag", as: String.self)
                let startHour = try standard.decode(column: "startHour", as: Int.self)
                let endHour = try standard.decode(column: "endHour", as: Int.self)
                let requiredCount = try standard.decode(column: "requiredCount", as: Int.self)
                let createdAt = try standard.decode(column: "created_at", as: String.self)
                let evaluationTimestamp = iso8601Timestamp(dateString: requestedDate, hour: endHour)
                let standardWasActive = try await isStandardActive(
                    standardID: standardID,
                    at: evaluationTimestamp,
                    createdAt: createdAt,
                    sql: sql
                )

                guard standardWasActive else {
                    print("Historical status resolution: standard inactive at gap evaluation time — skipping \(standardKey)")
                    continue
                }

                // Fail closed: a standard whose window cannot be resolved is skipped and
                // reported rather than evaluated against a half-built range.
                guard let windowBounds = observationWindowBounds(
                    localDate: requestedDate,
                    startHour: startHour,
                    endHour: endHour,
                    timeZone: operationsTimeZone
                ) else {
                    req.logger.warning(
                        "Unresolvable observation window, standard skipped",
                        metadata: [
                            "calculation": .string("gaps/mechanical"),
                            "standardKey": .string(standardKey),
                            "localDate": .string(requestedDate)
                        ]
                    )
                    continue
                }

                let countRows = try await sql.raw(observationCountInWindowQuery(bounds: windowBounds)).all()

                let observedCount = try countRows[0].decode(column: "recordCount", as: Int.self)

                if observedCount < requiredCount {
                    let decisionRows = try await sql.raw(
                        leaveEmptyDecisionCountQuery(
                            standardKey: standardKey,
                            localDate: requestedDate,
                            startHour: startHour,
                            endHour: endHour
                        )
                    ).all()

                    let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)

                    if decisionCount == 0 {
                        gaps.append([
                            "sourceTag": sourceTag,
                            "standardKey": standardKey,
                            "description": description,
                            "expectedDate": requestedDate,
                            "evaluationTimestamp": evaluationTimestamp,
                            "expectedWindow": String(format: "%02d:00-%02d:00", startHour, endHour),
                            "requiredCount": String(requiredCount),
                            "observedCount": String(observedCount),
                            "gapStatus": "Missing expected observation"
                        ])
                    }
                }
            }

            print("Mechanical gap detection PASS: \(gaps.count) gaps")

            let response = Response(status: .ok)
            try response.content.encode(gaps)
            return response
        }

        apiV1.get("state", "pulse") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let gapsRows = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    "description",
                    "sourceTag",
                    "startHour",
                    "endHour",
                    "requiredCount",
                    created_at
                FROM operational_standards
                ORDER BY "standardKey" ASC
            """).all()

            // Pulse reports the current operations day. Before A1b it compared only the
            // hour of day and therefore counted observations from any date (SF-A).
            let pulseDate = operationsDateString(for: Date(), in: operationsTimeZone)

            var activeStandardsCount = 0
            var informationGapsCount = 0

            let timestampDiagnosticRows = try await sql.raw(timestampReadExpectationDiagnosticQuery()).all()
            logTimestampReadExpectationDiagnostic(
                try timestampReadExpectationDiagnostic(from: timestampDiagnosticRows),
                calculation: "state/pulse",
                logger: req.logger
            )

            for standard in gapsRows {
                let standardID = try standard.decode(column: "id", as: UUID.self)
                let standardKey = try standard.decode(column: "standardKey", as: String.self)
                let startHour = try standard.decode(column: "startHour", as: Int.self)
                let endHour = try standard.decode(column: "endHour", as: Int.self)
                let requiredCount = try standard.decode(column: "requiredCount", as: Int.self)
                let createdAt = try standard.decode(column: "created_at", as: String.self)
                let evaluationTimestamp = iso8601Timestamp(dateString: pulseDate, hour: endHour)
                let standardWasActive = try await isStandardActive(
                    standardID: standardID,
                    at: evaluationTimestamp,
                    createdAt: createdAt,
                    sql: sql
                )

                guard standardWasActive else {
                    print("Historical status resolution: standard inactive at pulse evaluation time — skipping \(standardKey)")
                    continue
                }

                activeStandardsCount += 1

                // Same fail-closed rule and the same single window helper as gaps.
                guard let windowBounds = observationWindowBounds(
                    localDate: pulseDate,
                    startHour: startHour,
                    endHour: endHour,
                    timeZone: operationsTimeZone
                ) else {
                    req.logger.warning(
                        "Unresolvable observation window, standard skipped",
                        metadata: [
                            "calculation": .string("state/pulse"),
                            "standardKey": .string(standardKey),
                            "localDate": .string(pulseDate)
                        ]
                    )
                    continue
                }

                let countRows = try await sql.raw(observationCountInWindowQuery(bounds: windowBounds)).all()

                let observedCount = try countRows[0].decode(column: "recordCount", as: Int.self)

                if observedCount < requiredCount {
                    let decisionRows = try await sql.raw(
                        leaveEmptyDecisionCountQuery(
                            standardKey: standardKey,
                            localDate: pulseDate,
                            startHour: startHour,
                            endHour: endHour
                        )
                    ).all()

                    let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)

                    if decisionCount == 0 {
                        informationGapsCount += 1
                        print("Open gap without Decision Trace: \(standardKey)")
                    } else {
                        print("Gap has Decision Trace and remains historically intact: \(standardKey)")
                    }
                }
            }

            let pulseState: String

            if activeStandardsCount == 0 {
                pulseState = "blue"
            } else if informationGapsCount > 0 {
                pulseState = "yellow"
            } else {
                pulseState = "green"
            }

            print("Mechanical pulse generation PASS")
            print("activeStandardsCount: \(activeStandardsCount)")
            print("informationGapsCount: \(informationGapsCount)")
            print("pulseState: \(pulseState)")
            print("sourceTag: [S]")

            let response = Response(status: .ok)
            try response.content.encode([
                "pulseState": pulseState,
                "sourceTag": "[S]"
            ])
            return response
        }

        // Fail-closed coverage check: refuse to start if any route was registered
        // outside the central gate without an explicit unauthenticated classification.
        try verifyMachineGateCoverage(routes: app.routes.all)
        print("Machine auth gate coverage verified for \(app.routes.all.count) registered routes")

        print("AIHOS Asset Server starting")

        try await app.execute()
    }
}
