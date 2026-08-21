import Foundation

// MARK: - Speech transcription adapter
//
// F-I2. The Apple Speech binding, moved out of the composition root. With this,
// AIHOSAssetServer.swift holds nothing but imports and startup.
//
// TWO IMPLEMENTATIONS, ONE DECISION POINT
//   Speech exists on Apple platforms and not on the Linux runtime the server deploys
//   to, so this file declares the same actor twice: once backed by Speech and once
//   answering that transcription is unavailable. Both expose the identical surface,
//   which is why the calling route never asks which one it got and needs no conditional
//   of its own. Same arrangement as the Vision adapter in F-I1.
//
// AUTHORISATION IS PART OF THE CONTRACT, NOT AN OBSTACLE
//   The Speech-backed implementation resolves the recogniser's authorisation status
//   before doing anything, and turns each refusal into its own distinct error rather
//   than one generic failure. An operator who sees "authorization denied" knows to grant
//   permission; one who sees "recognizer unavailable" knows the locale is the problem.
//   Collapsing them would hide which of the two it was.
//
// THE UNAVAILABLE PATH IS AN ANSWER, NOT AN ERROR
//   The #else implementation returns .null with a reason rather than throwing. A server
//   without Speech is not broken; it simply cannot transcribe, and the route records
//   that as a finding — which is why the transcription route still writes a
//   payload_text row for a null result.

#if canImport(Speech)
import Speech
#endif

#if canImport(Speech)
actor AppleSpeechTranscriber {
    enum TranscriptionOutcome {
        case text(String)
        case null(reason: String)
    }

    enum TranscriptionError: Error {
        case recognizerUnavailable
        case authorizationDenied
        case authorizationRestricted
        case authorizationNotDetermined
        case emptyResult
    }

    func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionOutcome {
        let authorizationStatus = await resolvedSpeechAuthorizationStatus()

        switch authorizationStatus {
        case .authorized:
            break
        case .denied:
            throw TranscriptionError.authorizationDenied
        case .restricted:
            throw TranscriptionError.authorizationRestricted
        case .notDetermined:
            throw TranscriptionError.authorizationNotDetermined
        @unknown default:
            throw TranscriptionError.authorizationRestricted
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let transcription = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var didResume = false

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result else { return }

                if result.isFinal {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }

        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscription.isEmpty else {
            return .null(reason: "Apple Speech returned empty transcription")
        }

        return .text(trimmedTranscription)
    }

    private func resolvedSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()

        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
    }
}
#else
actor AppleSpeechTranscriber {
    enum TranscriptionOutcome {
        case text(String)
        case null(reason: String)
    }

    func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionOutcome {
        return .null(reason: "Apple Speech is unavailable on this server runtime")
    }
}
#endif
