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
        registerDatabaseHealthRoutes(on: app)

        registerImmutabilityDiagnosticRoutes(on: gated)

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
