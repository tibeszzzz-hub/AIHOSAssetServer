import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Image sync ingestion route
//
// F-H2, the last route to leave the composition root. `POST /api/v1/sync` is the
// primary ingest path: it accepts a photo with its metadata, writes the file to storage
// and fixes the observation in the database. After this atom main() registers no routes
// at all — it resolves configuration, runs migrations and calls the registrars.
//
// THE ORDER OF OPERATIONS IS THE CONTRACT
//   Everything that can reject the upload runs before the file is written: multipart
//   decode, metadata decode, the canonical timestamp check, lane validation and the
//   observation id parse. A rejected upload leaves nothing behind — no file, no row, no
//   partial state.
//
//   The timestamp check refuses a 13-digit millisecond value rather than normalising
//   it. Guessing the client's unit is how silent data corruption starts.
//
// ON CONFLICT (id) DO NOTHING IS SHARED IDENTITY, NOT LENIENCE
//   A second upload carrying an observationID that already exists joins that
//   observation rather than failing, which is what lets a photo and a recording belong
//   to the same observation. The log distinguishes the two cases explicitly so an
//   operator can see which happened.
//
// THE FORCED-FAILURE BRANCH IS A DELIBERATE, NARROW TEST DOOR
//   A single reserved file name — "test-force-transaction-failure.jpg" — makes the
//   transaction insert an asset_files row pointing at a record id that was never
//   created, so the foreign key fails and the whole transaction rolls back. It exists
//   to prove, against a real database, that a failed transaction leaves no row AND that
//   the file already written to storage is deleted.
//
//   It is deliberately narrow: an exact, full equality against one literal name, and
//   nothing about it is configurable. Widening it to a prefix, a suffix or an
//   environment flag would turn a test door into a way to corrupt real ingestion, so it
//   is pinned exactly as written.
//
// THE ROLLBACK IS TWO-SIDED
//   If the transaction throws, the file already written is deleted, and the cleanup
//   reports its own outcome separately — including its own failure, so a half-rolled-
//   back state is never silently swallowed.
//
// WHAT IS THREADED IN
//   `storageDirectory` only. main() resolves it once, fail-closed.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/sync` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerImageSyncIngestionRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {
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
}
