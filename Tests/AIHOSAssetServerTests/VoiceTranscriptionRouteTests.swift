import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G10: the mechanical voice transcription route
//
// Order WFOS-20260821-PSKS-001. `POST /api/v1/assets/:assetID/transcribe-audio` moved
// from main() into Sources/AIHOSAssetServer/VoiceTranscriptionRoutes.swift. With this,
// the composition root registers nothing but ingestion.
//
// WHY THESE TESTS
//   Like the Vision diagnostic, this route's platform behaviour is decided once, with
//   the actor, not here — a #if added to this file would compile and create a second
//   place for the two platforms to drift.
//
//   Its own contract has two parts worth protecting. Four checks run before any
//   transcription, and the third and fourth are separate on purpose: a file recorded in
//   the database and a file present on disk are different facts, and they can disagree.
//   And a null result is still written to the database, because "we listened and heard
//   nothing" is a finding — dropping the row would make it indistinguishable from
//   "nobody has listened yet".

private let routeFileName = "VoiceTranscriptionRoutes.swift"

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

@Suite("F-G10 voice transcription route extraction")
struct VoiceTranscriptionRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.post("assets", ":assetID", "transcribe-audio")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the transcription route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerVoiceTranscriptionRoutes(on: apiV1, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    // MARK: The platform decision stays with the actor

    @Test("The route file carries no Speech conditional and no copy of the transcriber")
    func platformDecisionIsNotDuplicated() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("#if") == false, "A compile-time conditional was added to \(routeFileName)")
        #expect(code.contains("#else") == false)
        #expect(code.contains("import Speech") == false)
        #expect(code.contains("SFSpeech") == false)
        #expect(code.contains("actor AppleSpeechTranscriber") == false,
                "The transcriber was duplicated into \(routeFileName)")

        #expect(code.contains("let transcriber = AppleSpeechTranscriber()"))
        #expect(code.contains("outcome = try await transcriber.transcribeAudioFile(at: fileURL)"))

        // The decision is still made exactly once — in SpeechTranscription.swift since
        // F-I2, and no longer in the composition root. The demand is unchanged: one file
        // declares the conditional and both implementations, and no other file may.
        let adapter = try #require(
            try serverModuleSourceTexts().first { $0.name == "SpeechTranscription.swift" }?.text,
            "SpeechTranscription.swift is missing from the library"
        )
        #expect(adapter.contains("#if canImport(Speech)"))
        #expect(adapter.components(separatedBy: "actor AppleSpeechTranscriber").count - 1 == 2,
                "The two platform implementations of the transcriber are no longer both present")

        let othersWithSpeechConditional = try serverModuleSourceTexts()
            .filter { $0.name != "SpeechTranscription.swift" }
            .filter { file in
                file.text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#if canImport(Speech)") }
            }
            .map(\.name)
        #expect(othersWithSpeechConditional.isEmpty,
                "Speech is decided in more than one place: \(othersWithSpeechConditional)")
    }

    // MARK: Dependencies

    @Test("storageDirectory is a parameter and nothing else is looked up")
    func storageIsThreadedIn() throws {
        #expect(try routeFileText().contains(
            "func registerVoiceTranscriptionRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "resolvedStorageDirectory",
                       "OPERATIONS_TIMEZONE", "operationsTimeZone", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }
        #expect(code.contains(#"let filePath = storageDirectory + "/" + fileName"#))

        for declaration in ["var ", "let ", "struct ", "actor "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: Four checks before any transcription

    @Test("Database presence and disk presence are checked separately")
    func assetAndFileChecksStayDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // 400: malformed id.
        #expect(code.contains(#"print("Mechanical transcription failed: invalid assetID")"#))
        #expect(code.contains("return Response(status: .badRequest)"))

        // Three separate 404s with three separate reasons.
        for reason in [
            #"print("Mechanical transcription failed: asset not found \(assetID.uuidString)")"#,
            #"print("Mechanical transcription failed: no audio asset file found \(assetID.uuidString)")"#,
            #"print("Mechanical transcription failed: missing audio file \(fileName)")"#
        ] {
            #expect(code.contains(reason), "404 reason changed or missing: \(reason)")
        }
        #expect(code.components(separatedBy: "return Response(status: .notFound)").count - 1 == 3)

        // The row-exists check and the file-exists check are different facts and can
        // disagree; collapsing them would push the failure deep into Speech instead of
        // catching it at the boundary.
        #expect(code.contains("guard fileRows.count == 1 else {"))
        #expect(code.contains("guard FileManager.default.fileExists(atPath: filePath) else {"))
        let rowCheck = try #require(code.range(of: "guard fileRows.count == 1 else {")?.lowerBound)
        let diskCheck = try #require(code.range(of: "guard FileManager.default.fileExists")?.lowerBound)
        let transcribe = try #require(code.range(of: "transcriber.transcribeAudioFile(at: fileURL)")?.lowerBound)
        #expect(rowCheck < diskCheck)
        #expect(diskCheck < transcribe, "Transcription starts before the file is known to exist")

        // Deterministic file selection: the first file by name, not an arbitrary one.
        #expect(code.contains(#"ORDER BY "fileName" ASC"#))
        #expect(code.contains("LIMIT 1"))
    }

    // MARK: A null result is a finding, not an absence

    @Test("Both text and null are written to the database; only an error skips the write")
    func nullOutcomeIsStillRecorded() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("case .text(let text):"))
        #expect(code.contains("case .null(let nullReason):"))
        #expect(code.contains(#"transcriptionStatus = "text""#))
        #expect(code.contains(#"transcriptionStatus = "null""#))

        // One insert, reached by both outcomes — the switch sets payloadText to the text
        // or to nil, and the row is written either way.
        #expect(code.contains("INSERT INTO asset_payload_texts"))
        #expect(code.components(separatedBy: "INSERT INTO").count - 1 == 1)
        #expect(code.contains(#"(\(bind: payloadTextID), \(bind: assetID), \(bind: payloadText), \(bind: sourceTag), \(bind: createdAt));"#))

        let switchEnd = try #require(code.range(of: #"transcriptionStatus = "null""#)?.upperBound)
        let insertIndex = try #require(code.range(of: "INSERT INTO asset_payload_texts")?.lowerBound)
        #expect(switchEnd < insertIndex, "The insert no longer follows both outcomes")

        // A thrown error is the only path that skips the write, and it answers 500.
        #expect(code.contains(#"print("Mechanical transcription honest error: \(error)")"#))
        #expect(code.contains(#"transcriptionStatus: "error","#))
        #expect(code.contains("reason: String(describing: error)"))
    }

    @Test("The original audio is untouched and the output is tagged [S]")
    func originalAudioIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Machine-produced, so [S] rather than [M]: the system heard this, not a person.
        #expect(code.contains(#"let sourceTag = "[S]""#))
        #expect(code.contains(
            #"print("Source Awareness: original audio unchanged; Apple Speech output stored as subordinate payload_text")"#
        ))

        for forbidden in ["UPDATE asset_records", "DELETE FROM asset_records",
                          "INSERT INTO asset_records", "UPDATE asset_files", "DELETE FROM asset_files"] {
            #expect(code.contains(forbidden) == false, "\(forbidden) appeared in \(routeFileName)")
        }

        // The server decides the payload id and the timestamp.
        #expect(code.contains("let payloadTextID = UUID()"))
        #expect(code.contains("let createdAt = ISO8601DateFormatter().string(from: Date())"))
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains(#"print("Mechanical Voice Transcription PASS")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"let sourceTag = "[S]""#, with: #"let sourceTag = "[M]""#)

        #expect(mutated.contains(#"let sourceTag = "[S]""#) == false)
        #expect(try routeFileText().contains(#"let sourceTag = "[S]""#))
    }
}
