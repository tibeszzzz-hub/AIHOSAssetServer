import Vapor
import Fluent
import SQLKit
import Foundation

// MARK: - Vision OCR diagnostic route
//
// F-G9. `POST /test/vision-ocr` verifies that server-side text recognition actually
// works on this deployment, by accepting an image and reporting what Vision read from
// it. It is a technical verification, not an operational feature: nothing it produces
// enters the observation record.
//
// WHY THIS FILE CARRIES NO #if canImport(Vision)
//   The conditional lives with `AppleVisionOCRVerifier` in AIHOSAssetServer.swift,
//   which declares two implementations of the same actor — one backed by Vision and one
//   that always answers "unavailable on this server runtime". The route calls the actor
//   by name and never asks which it got, so it compiles and behaves identically on both
//   platforms without a conditional of its own. Adding one here would duplicate the
//   decision and create a second place for the two platforms to drift apart.
//
//   Concretely: on a runtime without Vision the route still answers 200 with
//   ocrStatus "null" and the unavailability reason, exactly as before this move.
//
// THREE OUTCOMES, THREE STATUS CODES
//   A thrown recognition error is 500 with ocrStatus "error" and the reason — an honest
//   failure rather than an empty success. Text found and no text found are both 200,
//   distinguished by ocrStatus "text" versus "null". Collapsing "null" into "error"
//   would report a blank image as a broken server.
//
// WHAT IS THREADED IN
//   `storageDirectory`, because the uploaded image is written to an OCRTest subfolder
//   before recognition runs. main() resolves it once, fail-closed, and passes it in.
//
// WHY IT IS GATED
//   It accepts a 10 MB upload and writes it to disk (PSKS-008), so it is registered on
//   the gated group. The parameter is named `gated` because the route manifest resolves
//   a registration's gate and prefix from the receiver's name.
//
// The written test image is not cleaned up, matching the behaviour before this move.

/// Registers the gated `POST /test/vision-ocr` recognition diagnostic.
///
/// - Parameters:
///   - gated: the machine-gated route group without the `/api/v1` prefix.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerVisionOCRDiagnosticRoutes(on gated: MachineGatedRoutes, storageDirectory: String) {
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
}
