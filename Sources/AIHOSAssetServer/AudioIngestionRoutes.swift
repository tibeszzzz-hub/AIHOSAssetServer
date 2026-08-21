import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Audio ingestion route
//
// F-H1, the first of the two ingestion routes to leave the composition root.
// `POST /api/v1/audio` accepts a recording with its metadata, writes the file to
// storage and fixes the observation in the database.
//
// Chosen over /sync as the safer single atom: it is one linear path, while /sync
// carries an extra branch inside its transaction — a deliberate failure triggered by a
// reserved file name, used to prove rollback. /sync is also the older and more heavily
// used ingest path, so leaving it last is the cautious order.
//
// THE ORDER OF OPERATIONS IS THE CONTRACT
//   Everything that can reject the upload runs before the file is written: multipart
//   decode, metadata decode, the canonical timestamp check, lane validation and the
//   observation id parse. A rejected upload therefore leaves nothing behind — no file,
//   no row, no partial state.
//
//   The timestamp check refuses a 13-digit millisecond value rather than normalising
//   it. Guessing the client's unit is how silent data corruption starts.
//
// TWO SEPARATE PROTECTIONS AGAINST DUPLICATES
//   An existing file of the same name answers 409 before anything is written — the
//   recording already on disk is never overwritten. Inside the transaction,
//   ON CONFLICT (id) DO NOTHING lets a second upload join an observation that already
//   exists instead of failing, which is what makes a photo and a recording share one
//   observation identity when the client supplies the same observationID.
//
// THE ROLLBACK IS TWO-SIDED
//   The database work runs in a transaction, and if it throws, the file already written
//   to storage is deleted. Without that the two halves would drift: a file on disk with
//   no row pointing at it. The cleanup reports its own outcome separately, including
//   when it fails, so a half-rolled-back state is never silently swallowed.
//
// WHAT IS THREADED IN
//   `storageDirectory` only. main() resolves it once, fail-closed.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/audio` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerAudioIngestionRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {
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
}
