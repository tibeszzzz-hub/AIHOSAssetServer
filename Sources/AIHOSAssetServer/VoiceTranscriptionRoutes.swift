import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Mechanical voice transcription route
//
// F-G10. `POST /api/v1/assets/:assetID/transcribe-audio` runs Apple Speech over an
// observation's audio file and stores what it heard as a subordinate payload text. The
// original recording is never altered — the transcription is an interpretation stored
// alongside it, tagged [S] because the system produced it rather than a person.
//
// WHY THIS FILE CARRIES NO #if canImport(Speech)
//   The conditional lives with `AppleSpeechTranscriber` in SpeechTranscription.swift,
//   which declares two implementations of the same actor — one backed by Speech and one
//   that answers "unavailable on this server runtime". This route calls the actor by
//   name and never asks which it got, so it behaves identically on both platforms
//   without a conditional of its own. Duplicating the #if here would create a second
//   place for the two platforms to drift apart. Same arrangement as the Vision
//   diagnostic in F-G9.
//
// FOUR CHECKS BEFORE ANY TRANSCRIPTION
//   A malformed asset id is 400. Then three separate 404s, each with its own reason:
//   the observation must exist, it must have a file recorded, and that file must
//   actually be present on disk. The last one matters because the database and the
//   storage directory can disagree — a row can outlive its file — and transcribing a
//   path that is not there would fail deep inside Speech instead of at the boundary.
//
// A NULL RESULT IS STILL RECORDED
//   Whether Speech returns text or nothing, a payload_text row is written: with the
//   text, or with NULL and the reason. That is deliberate. "We listened and heard
//   nothing" is a finding, and dropping the row would make it indistinguishable from
//   "nobody has listened yet". Only a thrown error skips the write, and that answers
//   500 with transcriptionStatus "error".
//
// WHAT IS THREADED IN
//   `storageDirectory`, to locate the audio file. main() resolves it once, fail-closed.
//
// The parameter is named `apiV1` on purpose: the route manifest resolves a
// registration's gate and its /api/v1 prefix from the receiver's name.

/// Registers `POST /api/v1/assets/:assetID/transcribe-audio` on the machine-gated group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerVoiceTranscriptionRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {
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
}
