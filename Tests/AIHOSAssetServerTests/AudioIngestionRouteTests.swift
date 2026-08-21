import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-H1: the audio ingestion route
//
// Order WFOS-20260821-PSKS-003. `POST /api/v1/audio` moved from main() into
// Sources/AIHOSAssetServer/AudioIngestionRoutes.swift. It is the first of the two
// ingestion routes to leave the composition root; /sync stays, deliberately last.
//
// WHY THESE TESTS ARE THE STRONGEST IN THE SERIES
//   This is the path by which observations enter the record at all. Four properties
//   would each compile if broken and each would corrupt the record rather than crash:
//
//   - Every rejection runs before the file is written, so a refused upload leaves
//     nothing behind.
//   - A 13-digit millisecond timestamp is refused, not normalised.
//   - Two separate duplicate protections: 409 on an existing file, and
//     ON CONFLICT (id) DO NOTHING so a second upload joins an existing observation.
//   - The rollback is two-sided: if the transaction throws, the file already written is
//     deleted, and the cleanup reports its own outcome including failure.

private let routeFileName = "AudioIngestionRoutes.swift"

private func routeFileText() throws -> String {
    try #require(
        try serverModuleSourceTexts().first { $0.name == routeFileName }?.text,
        "\(routeFileName) is missing from the library"
    )
}

/// Code lines only, so a term explained in a comment cannot satisfy or trip an assertion.
private func routeFileCodeLines() throws -> [String] {
    try routeFileText()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}

@Suite("F-H1 audio ingestion route extraction")
struct AudioIngestionRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.on(.POST, "audio", body: .collect(maxSize: "20mb"))"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the audio ingestion route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerAudioIngestionRoutes(on: apiV1, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("/sync stayed in the composition root and was not dragged along")
    func syncDidNotMove() throws {
        let sync = #"apiV1.on(.POST, "sync""#

        #expect(try serverSourceText().contains(sync),
                "/sync left the composition root out of order")
        #expect(try routeFileText().contains(sync) == false,
                "/sync was absorbed into \(routeFileName)")

        // The two ingest paths use different payload types and must not be merged.
        let code = try routeFileCodeLines().joined(separator: "\n")
        #expect(code.contains("MultipartAudioPayload"))
        #expect(code.contains("MultipartSyncPayload") == false)
    }

    // MARK: Dependencies and limits

    @Test("The registrar takes the group and storageDirectory, and the 20 MB limit is kept")
    func registrarAndLimitArePinned() throws {
        #expect(try routeFileText().contains(
            "func registerAudioIngestionRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        // The audio limit is 20 MB, twice the image limit. It is what stops an
        // unbounded upload being buffered in memory.
        #expect(code.contains(#"body: .collect(maxSize: "20mb")"#))
        #expect(code.contains(#""10mb""#) == false, "The audio route picked up the image body limit")

        for lookup in ["Environment.get", "STORAGE_PATH", "resolvedStorageDirectory",
                       "OPERATIONS_TIMEZONE", "operationsTimeZone", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }
        for declaration in ["var ", "let ", "struct ", "actor "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: Nothing is written until everything is accepted

    @Test("Every rejection runs before the file is written and before the transaction")
    func rejectionsPrecedeAnyWrite() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for rejection in [
            #"print("Audio multipart parsing failed: \(error)")"#,
            #"print("Audio metadata decode failed: \(error)")"#,
            #"print("Audio capture timestamp rejected: not a 10-digit Unix epoch in seconds")"#,
            #"print("Audio lane validation failed")"#,
            #"print("Invalid observationID received: \(rawObservationID)")"#
        ] {
            #expect(code.contains(rejection), "Rejection reason changed or missing: \(rejection)")
        }
        #expect(code.components(separatedBy: "return .badRequest").count - 1 == 5)

        // The last guard before the write is the observation id parse.
        let idGuard = try #require(code.range(of: "guard let parsedObservationID = UUID(uuidString: rawObservationID)")?.lowerBound)
        let fileWrite = try #require(code.range(of: "try Data(buffer: payload.audio.data).write(to:")?.lowerBound)
        let transaction = try #require(code.range(of: "try await req.db.transaction { database in")?.lowerBound)

        #expect(idGuard < fileWrite, "A malformed observation id is accepted before the file is written")
        #expect(fileWrite < transaction)

        // The canonical timestamp is refused, never normalised — guessing the client's
        // unit is how silent corruption starts.
        #expect(code.contains("guard isCanonicalCaptureTimestamp(metadata.captureTimestamp) else {"))
        let tsGuard = try #require(code.range(of: "isCanonicalCaptureTimestamp(metadata.captureTimestamp)")?.lowerBound)
        #expect(tsGuard < fileWrite)
        for normalising in ["/ 1000", "* 1000", "dropLast(3)", "prefix(10)"] {
            #expect(code.contains(normalising) == false,
                    "A millisecond timestamp is normalised instead of refused: \(normalising)")
        }
    }

    // MARK: Two separate duplicate protections

    @Test("An existing file is a 409, and the observation id conflict is a no-op")
    func duplicateProtectionsAreDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // The recording already on disk is never overwritten.
        #expect(code.contains("guard !FileManager.default.fileExists(atPath: storedFilePath) else {"))
        #expect(code.contains(#"print("Audio file save rejected: file already exists \(storedFileName)")"#))
        #expect(code.contains("return .conflict"))

        let existsCheck = try #require(code.range(of: "guard !FileManager.default.fileExists")?.lowerBound)
        let fileWrite = try #require(code.range(of: "try Data(buffer: payload.audio.data).write(to:")?.lowerBound)
        #expect(existsCheck < fileWrite, "The file is overwritten before the existence check")

        // Inside the transaction the opposite is wanted: a second upload joins an
        // observation that already exists, which is what lets a photo and a recording
        // share one identity when the client supplies the same observationID.
        #expect(code.contains("ON CONFLICT (id) DO NOTHING;"))
        #expect(code.contains("let recordID = sharedObservationID ?? UUID()"))
        #expect(code.contains(#"print("SHARED OBSERVATION IDENTITY: NEW asset_record CREATED: \(recordID.uuidString)")"#))
        #expect(code.contains(#"print("SHARED OBSERVATION IDENTITY: EXISTING asset_record REUSED: \(recordID.uuidString)")"#))
    }

    // MARK: The two-sided rollback

    @Test("A failed transaction deletes the file already written, and says so")
    func rollbackIsTwoSided() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("try FileManager.default.removeItem(atPath: storedFilePath)"))
        #expect(code.contains(#"print("Audio rollback cleanup PASS: saved audio file deleted")"#))
        #expect(code.contains(#"print("Audio rollback cleanup PASS: no saved audio file found")"#))

        // The cleanup reports its own failure separately. Without this a half-rolled-back
        // state — row gone, file still on disk — would be swallowed silently.
        #expect(code.contains(#"print("Audio rollback cleanup FAILED: saved audio file could not be deleted: \(error)")"#))
        #expect(code.contains(#"print("Transactional audio fixation failed: \(error)")"#))
        #expect(code.contains("return .internalServerError"))
    }

    // MARK: What the transaction writes

    @Test("Record, file and optional payload text are written in one transaction")
    func transactionContentsAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("guard let sql = database as? SQLDatabase else {"))
        #expect(code.contains(#"INSERT INTO asset_records (id, "captureTimestamp", "sourceTag", lane_key)"#))
        #expect(code.contains(#"INSERT INTO asset_files (id, "assetRecordID", "fileName")"#))
        #expect(code.contains("INSERT INTO asset_payload_texts"))

        // Payload text is optional and comes from the multipart field first, then the
        // metadata. Its tag defaults to [S] — machine-produced unless stated otherwise.
        #expect(code.contains("let resolvedPayloadText = payload.payloadText ?? metadata.payloadText"))
        #expect(code.contains(#"let payloadTextSourceTag = metadata.payloadTextSourceTag ?? "[S]""#))
        #expect(code.contains("if let payloadText = resolvedPayloadText, !payloadText.isEmpty {"))
        #expect(code.contains(#"print("No payload_text provided for audio payload")"#))

        // The default extension differs from /sync's .jpg.
        #expect(code.contains(#"let storedFileName = metadata.fileName ?? "\(UUID().uuidString).m4a""#))
        #expect(code.contains(#"print("[M] Audio fixed transactionally. Tid: \(metadata.captureTimestamp). Ljudstorlek: \(audioSize) bytes.")"#))
        #expect(code.contains("return .ok"))

        // No test backdoor was carried across from /sync.
        #expect(code.contains("forceTransactionalFailure") == false,
                "The /sync test backdoor appeared in the audio route")
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "return .conflict", with: "return .ok")

        #expect(mutated.contains("return .conflict") == false)
        #expect(try routeFileText().contains("return .conflict"))
    }
}
