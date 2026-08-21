import Foundation

// MARK: - Vision text recognition adapter
//
// F-I1. The Apple Vision binding, moved out of the composition root so that
// AIHOSAssetServer.swift holds nothing but startup.
//
// TWO IMPLEMENTATIONS, ONE DECISION POINT
//   Vision exists on Apple platforms and not on the Linux runtime the server actually
//   deploys to, so this file declares the same actor twice: once backed by Vision and
//   once answering that recognition is unavailable. Both expose the identical surface,
//   which is why the calling route never asks which one it got and needs no conditional
//   of its own.
//
//   This is the single place the platform is chosen. Moving it here did not add a
//   decision point — it relocated the only one, and the tests that used to assert it
//   lived in the composition root now assert it lives here.
//
// THE UNAVAILABLE PATH IS AN ANSWER, NOT AN ERROR
//   The #else implementation returns .null with a reason rather than throwing. A server
//   without Vision is not broken; it simply cannot read text from an image, and the
//   route reports that as a successful reading of nothing. Turning it into a thrown
//   error would make every deployment without Vision look like a fault.

#if canImport(Vision)
import Vision
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
