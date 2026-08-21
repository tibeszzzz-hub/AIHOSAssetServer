import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-I1: the Vision adapter left the composition root
//
// Order WFOS-20260821-PSKS-009. The conditional Vision import and both implementations
// of AppleVisionOCRVerifier moved from AIHOSAssetServer.swift into
// Sources/AIHOSAssetServer/VisionTextRecognition.swift.
//
// WHAT THIS SUITE ADDS
//   VisionOCRDiagnosticRouteTests already asserts, from the route's side, that the
//   adapter file holds the conditional and both implementations and that no other file
//   does. What is added here is the other half of the same claim: that the composition
//   root is now free of Vision entirely — no import, no conditional, no symbol, no
//   actor — so a future reader cannot conclude from main() that startup has anything to
//   do with text recognition.

private func mainFileCodeLines() throws -> [String] {
    try serverSourceText()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}

@Suite("F-I1 Vision adapter extraction")
struct VisionTextRecognitionTests {

    @Test("The composition root contains no Vision symbol of any kind")
    func compositionRootIsFreeOfVision() throws {
        let code = try mainFileCodeLines().joined(separator: "\n")

        for symbol in [
            "canImport(Vision)",
            "import Vision",
            "AppleVisionOCRVerifier",
            "VNRecognizeTextRequest",
            "VNImageRequestHandler"
        ] {
            #expect(code.contains(symbol) == false,
                    "\(symbol) is still in the composition root")
        }
    }

    @Test("The adapter file holds the whole binding and nothing else")
    func adapterFileIsSelfContained() throws {
        let adapter = try #require(
            try serverModuleSourceTexts().first { $0.name == "VisionTextRecognition.swift" }?.text,
            "VisionTextRecognition.swift is missing from the library"
        )
        let codeLines = adapter
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let code = codeLines.joined(separator: "\n")

        // The import is guarded by the same condition as the implementations, so a
        // platform without Vision never imports it.
        #expect(code.contains("#if canImport(Vision)\nimport Vision\n#endif"))

        // Both implementations, same surface, and the unavailable one answers rather
        // than throws — a server without Vision is not a broken server.
        #expect(code.components(separatedBy: "actor AppleVisionOCRVerifier").count - 1 == 2)
        #expect(code.components(separatedBy: "func recognizeText(in imageURL: URL) async throws -> OCROutcome").count - 1 == 2)
        #expect(code.components(separatedBy: "enum OCROutcome {").count - 1 == 2)
        #expect(code.contains(#"return .null(reason: "Apple Vision OCR is unavailable on this server runtime")"#))

        // The Vision-backed path, unchanged.
        #expect(code.contains("let request = VNRecognizeTextRequest()"))
        #expect(code.contains("request.recognitionLevel = .accurate"))
        #expect(code.contains("request.usesLanguageCorrection = false"))
        #expect(code.contains("let requestHandler = VNImageRequestHandler(url: imageURL)"))
        #expect(code.contains("observation.topCandidates(1).first?.string"))
        #expect(code.contains(#"return .null(reason: "Apple Vision OCR returned no readable text")"#))

        // Nothing but the adapter lives here: no route, no SQL, no configuration.
        for foreign in ["apiV1.", "gated.", "app.", "sql.raw", "req.db", "Environment.get", "storageDirectory"] {
            #expect(code.contains(foreign) == false, "\(foreign) appeared in VisionTextRecognition.swift")
        }
    }

    @Test("The Speech adapter is a separate file, decided in its own single place")
    func speechAdapterIsSeparate() throws {
        // F-I1 moved Vision only; F-I2 then moved Speech into a file of its own. They
        // were split into two atoms precisely so the two platform conditionals could
        // never break together — and that separation is what this now asserts.
        let speech = try #require(
            try serverModuleSourceTexts().first { $0.name == "SpeechTranscription.swift" }?.text,
            "SpeechTranscription.swift is missing from the library"
        )
        #expect(speech.contains("#if canImport(Speech)"))
        #expect(speech.components(separatedBy: "actor AppleSpeechTranscriber").count - 1 == 2)

        let vision = try #require(
            try serverModuleSourceTexts().first { $0.name == "VisionTextRecognition.swift" }?.text,
            "VisionTextRecognition.swift is missing from the library"
        )
        // Code only: each adapter's header comment cross-references the other by name,
        // which is documentation rather than a dependency.
        func codeOf(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        #expect(codeOf(vision).contains("Speech") == false, "The two adapters were merged")
        #expect(codeOf(speech).contains("Vision") == false, "The two adapters were merged")
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let adapter = try #require(
            try serverModuleSourceTexts().first { $0.name == "VisionTextRecognition.swift" }?.text,
            "VisionTextRecognition.swift is missing from the library"
        )
        let mutated = adapter.replacingOccurrences(
            of: #"return .null(reason: "Apple Vision OCR is unavailable on this server runtime")"#,
            with: #"throw OCRError.unavailable"#
        )

        #expect(mutated.contains("Apple Vision OCR is unavailable on this server runtime") == false)
        #expect(adapter.contains("Apple Vision OCR is unavailable on this server runtime"))
    }
}
