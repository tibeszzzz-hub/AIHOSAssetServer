import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G9: the Vision OCR diagnostic route
//
// Order WFOS-20260820-PSKS-025. `POST /test/vision-ocr` moved from main() into
// Sources/AIHOSAssetServer/VisionOCRDiagnosticRoutes.swift.
//
// WHY THESE TESTS
//   This is the first extracted route whose behaviour differs by platform, and the
//   thing worth protecting is that the difference is decided in exactly one place. The
//   conditional lives with AppleVisionOCRVerifier in the composition root, which
//   declares two implementations of the same actor; the route calls it by name and
//   never asks which it got. A #if canImport(Vision) added to the route file would
//   compile and would create a second place for the two platforms to drift.
//
//   Its three outcomes also carry meaning that a simplification would erase: a thrown
//   error is 500, while both "text found" and "no text found" are 200 distinguished by
//   ocrStatus. Folding "null" into "error" would report a blank image as a broken
//   server.

private let routeFileName = "VisionOCRDiagnosticRoutes.swift"

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

@Suite("F-G9 Vision OCR diagnostic route extraction")
struct VisionOCRDiagnosticRouteTests {

    // MARK: Placement and classification

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"gated.on(.POST, "test", "vision-ocr", body: .collect(maxSize: "10mb"))"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the Vision OCR diagnostic")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerVisionOCRDiagnosticRoutes(on: gated, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("It stays gated and keeps its 10 MB body limit")
    func routeRemainsGatedAndBounded() throws {
        #expect(try routeFileText().contains(
            "func registerVisionOCRDiagnosticRoutes(on gated: MachineGatedRoutes, storageDirectory: String) {"
        ))

        let code = try routeFileCodeLines().joined(separator: "\n")
        #expect(code.contains("app.") == false, "The diagnostic was registered outside the machine gate")
        #expect(code.contains("apiV1.") == false, "The diagnostic gained the /api/v1 prefix")

        // The collect limit is what stops an unbounded upload being buffered in memory.
        #expect(code.contains(#"body: .collect(maxSize: "10mb")"#))

        #expect(unauthenticatedRouteAllowlist.contains("POST /test/vision-ocr") == false,
                "An upload-accepting diagnostic was allowlisted for unauthenticated access")
    }

    // MARK: The platform conditional lives in exactly one place

    @Test("The route file carries no Vision conditional and no Vision import")
    func platformDecisionIsNotDuplicated() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // The two actor implementations, and the #if that chooses between them, stay in
        // the composition root. This file names the actor and never asks which it got.
        #expect(code.contains("#if") == false, "A compile-time conditional was added to \(routeFileName)")
        #expect(code.contains("#else") == false)
        #expect(code.contains("import Vision") == false)
        #expect(code.contains("VNRecognizeTextRequest") == false)
        #expect(code.contains("actor AppleVisionOCRVerifier") == false,
                "The verifier was duplicated into \(routeFileName)")

        #expect(code.contains("let verifier = AppleVisionOCRVerifier()"))
        #expect(code.contains("outcome = try await verifier.recognizeText(in: testFileURL)"))

        // And the decision is still made once, in the composition root.
        let main = try serverSourceText()
        #expect(main.contains("#if canImport(Vision)"))
        #expect(main.components(separatedBy: "actor AppleVisionOCRVerifier").count - 1 == 2,
                "The two platform implementations of the verifier are no longer both present")
    }

    // MARK: The threaded dependency and the file it writes

    @Test("storageDirectory is a parameter, and the image is written under OCRTest")
    func storageIsThreadedIn() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "resolvedStorageDirectory", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        #expect(code.contains(#"let testDirectory = storageDirectory + "/OCRTest""#))
        #expect(code.contains(#"let testFileName = "vision-ocr-test-\(UUID().uuidString).jpg""#))
        #expect(code.contains(#"let testFilePath = testDirectory + "/" + testFileName"#))
        #expect(code.contains("try FileManager.default.createDirectory("))
        #expect(code.contains("withIntermediateDirectories: true"))
        #expect(code.contains("try Data(buffer: payload.image.data).write(to: testFileURL)"))

        // A failure to save is 500, not a silent continue into recognition.
        #expect(code.contains(#"print("Vision OCR test image save failed: \(error)")"#))
        #expect(code.contains(#"print("Vision OCR test image save PASS")"#))

        for declaration in ["var ", "let ", "struct ", "actor "] {
            #expect(try routeFileCodeLines().contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Three outcomes

    @Test("Error is 500; text and null are both 200 and stay distinguishable")
    func threeOutcomesAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Thrown recognition error: 500 carrying the reason, not an empty success.
        #expect(code.contains(#"print("Vision OCR honest error: \(error)")"#))
        #expect(code.contains("let response = Response(status: .internalServerError)"))
        #expect(code.contains(#"ocrStatus: "error","#))
        #expect(code.contains("reason: String(describing: error)"))

        // Both recognition outcomes are 200, told apart by ocrStatus only.
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains("case .text(let rawText):"))
        #expect(code.contains("case .null(let reason):"))
        #expect(code.contains(#"ocrStatus: "text","#))
        #expect(code.contains(#"ocrStatus: "null","#))

        // A blank image is a successful reading of nothing, not a server fault.
        #expect(code.components(separatedBy: "Response(status: .ok)").count - 1 == 1)
        #expect(code.components(separatedBy: "Response(status: .internalServerError)").count - 1 == 2)

        // Malformed multipart is 400, before anything is written to disk.
        #expect(code.contains("payload = try req.content.decode(MultipartSyncPayload.self)"))
        #expect(code.contains(#"print("Vision OCR test multipart parsing failed: \(error)")"#))
        let decodeIndex = try #require(code.range(of: "req.content.decode(MultipartSyncPayload.self)")?.lowerBound)
        let writeIndex = try #require(code.range(of: "createDirectory(")?.lowerBound)
        #expect(decodeIndex < writeIndex, "The upload is written to disk before it is known to be valid")
    }

    @Test("Nothing it produces enters the observation record")
    func diagnosticWritesNoDatabaseRow() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // It is a technical verification. It must not touch any table.
        for forbidden in ["sql.raw", "req.db", "SQLDatabase", "INSERT", "UPDATE ", "DELETE"] {
            #expect(code.contains(forbidden) == false, "\(forbidden) appeared in \(routeFileName)")
        }
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"ocrStatus: "null","#, with: #"ocrStatus: "error","#)

        #expect(mutated.contains(#"ocrStatus: "null","#) == false)
        #expect(try routeFileText().contains(#"ocrStatus: "null","#))
    }
}
