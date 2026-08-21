import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-I2: the Speech adapter left the composition root
//
// Order WFOS-20260821-PSKS-011. The conditional Speech import and both implementations
// of AppleSpeechTranscriber moved from AIHOSAssetServer.swift into
// Sources/AIHOSAssetServer/SpeechTranscription.swift.
//
// WHAT THIS SUITE ADDS
//   VoiceTranscriptionRouteTests asserts from the route's side that the adapter file
//   holds the conditional and both implementations and that no other file does. This
//   suite states the rest: that the composition root is now free of Speech entirely,
//   that the adapter carries the whole binding and nothing else, and — the end of the
//   whole series — that main() is now imports and startup, with no conditional
//   compilation and no actor left in it at all.

private func mainFileCodeLines() throws -> [String] {
    try serverSourceText()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}

@Suite("F-I2 Speech adapter extraction")
struct SpeechTranscriptionTests {

    @Test("The composition root contains no Speech symbol of any kind")
    func compositionRootIsFreeOfSpeech() throws {
        let code = try mainFileCodeLines().joined(separator: "\n")

        for symbol in [
            "canImport(Speech)",
            "import Speech",
            "AppleSpeechTranscriber",
            "SFSpeechRecognizer",
            "SFSpeechURLRecognitionRequest"
        ] {
            #expect(code.contains(symbol) == false, "\(symbol) is still in the composition root")
        }
    }

    @Test("The composition root now holds only imports and startup")
    func compositionRootIsPureComposition() throws {
        // The end position of the whole extraction series, asserted rather than assumed.
        let codeLines = try mainFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        #expect(code.contains("#if") == false, "A compile-time conditional remains in the composition root")
        #expect(codeLines.contains { $0.hasPrefix("actor ") } == false,
                "An actor remains in the composition root")
        #expect(codeLines.contains { $0.hasPrefix("struct ") || $0.hasPrefix("enum ") } == false,
                "A type declaration other than the server itself remains in the composition root")

        // Exactly one file-scope declaration: the server type.
        let topLevel = codeLines.filter { $0.hasPrefix("public struct ") || $0.hasPrefix("func ") || $0.hasPrefix("let ") || $0.hasPrefix("var ") }
        #expect(topLevel == ["public struct AIHOSAssetServer {"],
                "Unexpected file-scope declarations in the composition root: \(topLevel)")

        // And it still registers no routes.
        #expect(parseRouteRegistrations(inSource: try serverSourceText()).isEmpty)
    }

    @Test("The adapter file holds the whole binding and nothing else")
    func adapterFileIsSelfContained() throws {
        let adapter = try #require(
            try serverModuleSourceTexts().first { $0.name == "SpeechTranscription.swift" }?.text,
            "SpeechTranscription.swift is missing from the library"
        )
        let code = adapter
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("#if canImport(Speech)\nimport Speech\n#endif"))
        #expect(code.components(separatedBy: "actor AppleSpeechTranscriber").count - 1 == 2)
        #expect(code.components(separatedBy: "enum TranscriptionOutcome {").count - 1 == 2)
        #expect(code.components(separatedBy: "func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = \"en-US\") async throws -> TranscriptionOutcome").count - 1 == 2)
        #expect(code.contains(#"return .null(reason: "Apple Speech is unavailable on this server runtime")"#))

        // Each authorisation refusal keeps its own case, so an operator can tell a
        // permissions problem from a locale problem.
        for errorCase in [
            "case recognizerUnavailable",
            "case authorizationDenied",
            "case authorizationRestricted",
            "case authorizationNotDetermined",
            "case emptyResult"
        ] {
            #expect(code.contains(errorCase), "Error case changed or missing: \(errorCase)")
        }

        // Nothing but the adapter lives here.
        for foreign in ["apiV1.", "gated.", "app.", "sql.raw", "req.db", "Environment.get", "storageDirectory"] {
            #expect(code.contains(foreign) == false, "\(foreign) appeared in SpeechTranscription.swift")
        }
    }

    @Test("Neither route file's documentation still points at the composition root")
    func routeDocumentationIsCurrent() throws {
        // The two route files explain where the platform decision lives. After F-I1 and
        // F-I2 that is no longer AIHOSAssetServer.swift, and a comment left pointing
        // there would send the next reader to the wrong file.
        for (routeFile, adapterFile) in [
            ("VisionOCRDiagnosticRoutes.swift", "VisionTextRecognition.swift"),
            ("VoiceTranscriptionRoutes.swift", "SpeechTranscription.swift")
        ] {
            let text = try #require(
                try serverModuleSourceTexts().first { $0.name == routeFile }?.text,
                "\(routeFile) is missing from the library"
            )
            #expect(text.contains("in AIHOSAssetServer.swift") == false,
                    "\(routeFile) still points the reader at the composition root")
            #expect(text.contains(adapterFile), "\(routeFile) does not name \(adapterFile)")
        }
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let adapter = try #require(
            try serverModuleSourceTexts().first { $0.name == "SpeechTranscription.swift" }?.text,
            "SpeechTranscription.swift is missing from the library"
        )
        let mutated = adapter.replacingOccurrences(
            of: "case authorizationDenied",
            with: "case authorizationProblem"
        )

        #expect(mutated.contains("case authorizationDenied") == false)
        #expect(adapter.contains("case authorizationDenied"))
    }
}
