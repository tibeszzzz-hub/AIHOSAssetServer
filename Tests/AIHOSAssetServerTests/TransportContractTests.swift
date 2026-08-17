import Testing
import Vapor
import Foundation
@testable import AIHOSAssetServer

// MARK: - AC-3: transport (DTO) contracts
//
// Atom SERVER-MOD-A0 (WFOS-20260817-PSKS-020), binding correction GS-C1.
//
// BASELINE, STATED EXACTLY: the transport block is 16 types — 15 Vapor `Content`
// types plus `SyncMetadata`, which is plain `Codable` and is NOT a wire type. It is
// the metadata JSON embedded as a string field inside a multipart upload and is
// decoded with a bare `JSONDecoder` (AIHOSAssetServer.swift line 1339). The earlier
// figure of 17 in WFOS-20260817-KSPS-021 was a miscount; 16 is verified here and is
// asserted mechanically below so the number cannot drift again.
//
// The assertions use the real production encoding path — `Response.content.encode`
// and `ContentConfiguration.global`'s JSON coders — rather than a freshly configured
// `JSONEncoder`, so what is pinned is the bytes a client actually receives.

private enum TransportContractError: Error {
    case bodyMissing
    case notAJSONObject
}

/// Encodes through the real Vapor response path and returns the top-level JSON object.
private func encodedJSONObject<T: Content>(_ value: T) throws -> [String: Any] {
    let response = Response(status: .ok)
    try response.content.encode(value)

    guard let bytes = response.body.data else { throw TransportContractError.bodyMissing }
    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw TransportContractError.notAJSONObject
    }

    return object
}

/// Exact set of top-level JSON keys a response DTO produces.
private func encodedJSONKeys<T: Content>(_ value: T) throws -> Set<String> {
    Set(try encodedJSONObject(value).keys)
}

/// Decodes through the real Vapor content path used by `req.content.decode`.
private func decodeContent<T: Content>(_ type: T.Type, from json: String) throws -> T {
    let decoder = try ContentConfiguration.global.requireDecoder(for: .json)

    var buffer = ByteBufferAllocator().buffer(capacity: json.utf8.count)
    buffer.writeString(json)

    var headers = HTTPHeaders()
    headers.contentType = .json

    return try decoder.decode(T.self, from: buffer, headers: headers)
}

// MARK: - Baseline size

@Suite("Transport baseline — 15 Content types plus SyncMetadata")
struct TransportBaselineTests {

    @Test("The transport block is exactly 15 Content types plus SyncMetadata, never 17")
    func transportTypeCountIsSixteen() throws {
        let source = try serverSourceText()

        let contentTypes = declaredStructNames(conformingTo: "Content", inSource: source)
        let codableTypes = declaredStructNames(conformingTo: "Codable", inSource: source)

        #expect(contentTypes.count == 15, "Content types: \(contentTypes.count) — \(contentTypes)")
        #expect(codableTypes == ["SyncMetadata"], "Plain Codable types: \(codableTypes)")
        #expect(contentTypes.count + codableTypes.count == 16)

        // SyncMetadata is deliberately not a wire type and must not drift into one.
        #expect(contentTypes.contains("SyncMetadata") == false)
    }

    @Test("Every expected Content type is present under its exact name")
    func contentTypeNamesAreStable() throws {
        let source = try serverSourceText()
        let contentTypes = Set(declaredStructNames(conformingTo: "Content", inSource: source))

        #expect(contentTypes == [
            "MultipartSyncPayload",
            "MultipartAudioPayload",
            "DecisionPayload",
            "ObservationDecisionPayload",
            "ObservationDecisionTraceResponse",
            "GroupedObservationResponse",
            "PayloadTextRequest",
            "PayloadTextResponse",
            "MechanicalTranscriptionResponse",
            "VisionOCRTestResponse",
            "ShiftHandoverLogEntry",
            "OperationalStandardResponse",
            "OperationalStandardCreateRequest",
            "OperationalStandardStatusUpdateRequest",
            "StandardStatusUpdateResponse"
        ])
    }

    @Test("Negative control: the declaration scanner reports a changed conformance")
    func conformanceScannerDetectsDrift() {
        let fixture = """
        struct KeptResponse: Content {
        struct DriftedResponse: Codable {
        """

        #expect(declaredStructNames(conformingTo: "Content", inSource: fixture) == ["KeptResponse"])
        #expect(declaredStructNames(conformingTo: "Codable", inSource: fixture) == ["DriftedResponse"])
    }
}

// MARK: - The snake_case key that has no other home

@Suite("GroupedObservationResponse wire contract")
struct GroupedObservationResponseTests {

    private func sample() -> GroupedObservationResponse {
        GroupedObservationResponse(
            id: "11111111-2222-3333-4444-555555555555",
            captureTimestamp: "2026-08-17T22:15:00Z",
            displayTimestamp: "2026-08-17 22:15",
            sourceTag: "[M]",
            laneKey: "kitchen",
            files: ["a.jpg", "b.m4a"]
        )
    }

    @Test("laneKey is emitted as lane_key and never as laneKey")
    func laneKeyIsEmittedAsSnakeCase() throws {
        let keys = try encodedJSONKeys(sample())

        #expect(keys.contains("lane_key"))
        #expect(keys.contains("laneKey") == false, "laneKey leaked into the wire form: \(keys)")
    }

    @Test("The full key set is exactly the six contracted keys")
    func keySetIsExact() throws {
        #expect(try encodedJSONKeys(sample()) == [
            "id", "captureTimestamp", "displayTimestamp", "sourceTag", "lane_key", "files"
        ])
    }

    @Test("Values survive encoding, including the files array order")
    func valuesAndOrderAreStable() throws {
        let object = try encodedJSONObject(sample())

        #expect(object["id"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(object["captureTimestamp"] as? String == "2026-08-17T22:15:00Z")
        #expect(object["displayTimestamp"] as? String == "2026-08-17 22:15")
        #expect(object["sourceTag"] as? String == "[M]")
        #expect(object["lane_key"] as? String == "kitchen")
        #expect(object["files"] as? [String] == ["a.jpg", "b.m4a"])
    }

    @Test("Round trip: a client reading lane_key maps back onto laneKey")
    func roundTripPreservesLaneKey() throws {
        let response = Response(status: .ok)
        try response.content.encode(sample())

        guard let bytes = response.body.data else { throw TransportContractError.bodyMissing }
        let decoded = try JSONDecoder().decode(GroupedObservationResponse.self, from: bytes)

        #expect(decoded.laneKey == "kitchen")
        #expect(decoded.files == ["a.jpg", "b.m4a"])
        #expect(decoded.id == "11111111-2222-3333-4444-555555555555")
    }
}

// MARK: - SyncMetadata: the embedded metadata contract

@Suite("SyncMetadata decoding contract")
struct SyncMetadataTests {

    /// Production decodes this with a bare `JSONDecoder`, not through Vapor content.
    private func decode(_ json: String) throws -> SyncMetadata {
        try JSONDecoder().decode(SyncMetadata.self, from: Data(json.utf8))
    }

    @Test("A full metadata document decodes into every field under its literal name")
    func fullDocumentDecodes() throws {
        let metadata = try decode(#"""
        {
          "captureTimestamp": "2026-08-17T22:15:00Z",
          "sourceTag": "[M]",
          "fileName": "observation.jpg",
          "laneKey": "kitchen",
          "payloadText": "spilled coffee by the pass",
          "payloadTextSourceTag": "[S]",
          "observationID": "11111111-2222-3333-4444-555555555555"
        }
        """#)

        #expect(metadata.captureTimestamp == "2026-08-17T22:15:00Z")
        #expect(metadata.sourceTag == "[M]")
        #expect(metadata.fileName == "observation.jpg")
        #expect(metadata.laneKey == "kitchen")
        #expect(metadata.payloadText == "spilled coffee by the pass")
        #expect(metadata.payloadTextSourceTag == "[S]")
        #expect(metadata.observationID == "11111111-2222-3333-4444-555555555555")
    }

    @Test("Only captureTimestamp and sourceTag are required; the rest decode as nil")
    func optionalFieldsMayBeAbsent() throws {
        let metadata = try decode(#"{"captureTimestamp": "2026-08-17T22:15:00Z", "sourceTag": "[M]"}"#)

        #expect(metadata.fileName == nil)
        #expect(metadata.laneKey == nil)
        #expect(metadata.payloadText == nil)
        #expect(metadata.payloadTextSourceTag == nil)
        #expect(metadata.observationID == nil)
    }

    @Test("Negative control: a missing required field fails to decode")
    func missingRequiredFieldFails() {
        #expect(throws: (any Error).self) {
            _ = try decode(#"{"sourceTag": "[M]"}"#)
        }

        #expect(throws: (any Error).self) {
            _ = try decode(#"{"captureTimestamp": "2026-08-17T22:15:00Z"}"#)
        }
    }

    @Test("laneKey is camelCase on the way in, unlike lane_key on the way out")
    func laneKeyIsCamelCaseOnTheWayIn() throws {
        // The inbound metadata contract and the outbound observation contract spell the
        // same concept differently — `laneKey` in, `lane_key` out. Both are pinned here
        // so a refactor cannot quietly align them in either direction.
        let camelCase = try decode(#"{"captureTimestamp": "t", "sourceTag": "[M]", "laneKey": "kitchen"}"#)
        #expect(camelCase.laneKey == "kitchen")

        // A client sending the response spelling is silently ignored, not rejected: the
        // upload then falls back to "unassigned" via `validatedLaneKey(nil)`.
        let snakeCase = try decode(#"{"captureTimestamp": "t", "sourceTag": "[M]", "lane_key": "kitchen"}"#)
        #expect(snakeCase.laneKey == nil)
        #expect(validatedLaneKey(snakeCase.laneKey) == "unassigned")
    }
}

// MARK: - Response shapes

@Suite("Response DTO key contracts")
struct ResponseDTOContractTests {

    @Test("ObservationDecisionTraceResponse")
    func observationDecisionTraceResponse() throws {
        let value = ObservationDecisionTraceResponse(
            id: "id-1",
            targetAssetRecordID: "asset-1",
            decisionType: "handled",
            sourceTag: "[M]",
            createdAt: "2026-08-17T22:15:00Z"
        )

        #expect(try encodedJSONKeys(value) == ["id", "targetAssetRecordID", "decisionType", "sourceTag", "createdAt"])
    }

    @Test("PayloadTextResponse keeps its optional payloadText when present")
    func payloadTextResponseWithText() throws {
        let value = PayloadTextResponse(
            id: "id-1",
            assetRecordID: "asset-1",
            payloadText: "transcribed text",
            sourceTag: "[S]",
            createdAt: "2026-08-17T22:15:00Z"
        )

        #expect(try encodedJSONKeys(value) == ["id", "assetRecordID", "payloadText", "sourceTag", "createdAt"])
        #expect(try encodedJSONObject(value)["payloadText"] as? String == "transcribed text")
    }

    @Test("A nil optional is omitted from the JSON rather than emitted as null")
    func nilOptionalIsOmitted() throws {
        let value = PayloadTextResponse(
            id: "id-1",
            assetRecordID: "asset-1",
            payloadText: nil,
            sourceTag: "[S]",
            createdAt: "2026-08-17T22:15:00Z"
        )

        let keys = try encodedJSONKeys(value)

        // This is current behaviour, pinned as-is: clients must treat an absent key and
        // a null as the same thing. Changing it would be an API change, not a refactor.
        #expect(keys == ["id", "assetRecordID", "sourceTag", "createdAt"])
        #expect(keys.contains("payloadText") == false)
    }

    @Test("MechanicalTranscriptionResponse — full form")
    func mechanicalTranscriptionResponseFull() throws {
        let value = MechanicalTranscriptionResponse(
            assetRecordID: "asset-1",
            payloadTextID: "payload-1",
            payloadText: "hello",
            sourceTag: "[S]",
            transcriptionStatus: "text",
            reason: nil,
            createdAt: "2026-08-17T22:15:00Z"
        )

        #expect(try encodedJSONKeys(value) == [
            "assetRecordID", "payloadTextID", "payloadText", "sourceTag", "transcriptionStatus", "createdAt"
        ])
    }

    @Test("VisionOCRTestResponse")
    func visionOCRTestResponse() throws {
        let value = VisionOCRTestResponse(ocrStatus: "text", rawText: "TABLE 4", reason: nil)

        #expect(try encodedJSONKeys(value) == ["ocrStatus", "rawText"])
        #expect(try encodedJSONObject(value)["ocrStatus"] as? String == "text")
    }

    @Test("ShiftHandoverLogEntry")
    func shiftHandoverLogEntry() throws {
        let value = ShiftHandoverLogEntry(
            id: "id-1",
            sourceTag: "[M]",
            eventTimestamp: "2026-08-17T22:15:00Z",
            entryType: "Observation Record",
            message: "Observation record: a.jpg",
            laneKey: "kitchen"
        )

        // Note the contrast with GroupedObservationResponse: this type has no
        // CodingKeys, so its lane field stays camelCase on the wire.
        #expect(try encodedJSONKeys(value) == ["id", "sourceTag", "eventTimestamp", "entryType", "message", "laneKey"])
    }

    @Test("OperationalStandardResponse")
    func operationalStandardResponse() throws {
        let value = OperationalStandardResponse(
            id: "id-1",
            standardKey: "kitchen-photo-22:00-23:00",
            laneKey: "kitchen",
            trackType: "photo",
            expectedWindowStart: "22:00",
            expectedWindowEnd: "23:00",
            requiredCount: 1,
            status: "ACTIVE",
            createdAt: "2026-08-17T22:15:00Z"
        )

        #expect(try encodedJSONKeys(value) == [
            "id", "standardKey", "laneKey", "trackType",
            "expectedWindowStart", "expectedWindowEnd", "requiredCount", "status", "createdAt"
        ])
        #expect(try encodedJSONObject(value)["requiredCount"] as? Int == 1)
    }

    @Test("StandardStatusUpdateResponse")
    func standardStatusUpdateResponse() throws {
        let value = StandardStatusUpdateResponse(
            id: "id-1",
            standardID: "standard-1",
            status: "PAUSED",
            sourceTag: "[M]",
            changedAt: "2026-08-17T22:15:00Z"
        )

        #expect(try encodedJSONKeys(value) == ["id", "standardID", "status", "sourceTag", "changedAt"])
    }
}

// MARK: - Request shapes

@Suite("Request DTO decoding contracts")
struct RequestDTOContractTests {

    @Test("DecisionPayload decodes the four contracted keys")
    func decisionPayloadDecodes() throws {
        let value = try decodeContent(DecisionPayload.self, from: #"""
        {
          "standardKey": "night-photo-22-23",
          "expectedWindowStart": "2026-08-17T22:00:00Z",
          "expectedWindowEnd": "2026-08-17T23:00:00Z",
          "decisionType": "leave_empty"
        }
        """#)

        #expect(value.standardKey == "night-photo-22-23")
        #expect(value.expectedWindowStart == "2026-08-17T22:00:00Z")
        #expect(value.expectedWindowEnd == "2026-08-17T23:00:00Z")
        #expect(value.decisionType == "leave_empty")
    }

    @Test("ObservationDecisionPayload decodes its single key")
    func observationDecisionPayloadDecodes() throws {
        #expect(try decodeContent(ObservationDecisionPayload.self, from: #"{"decisionType": "handled"}"#).decisionType == "handled")
    }

    @Test("PayloadTextRequest accepts an explicit null payloadText")
    func payloadTextRequestDecodes() throws {
        let withText = try decodeContent(PayloadTextRequest.self, from: #"{"payloadText": "note", "sourceTag": "[S]"}"#)
        #expect(withText.payloadText == "note")
        #expect(withText.sourceTag == "[S]")

        let withoutText = try decodeContent(PayloadTextRequest.self, from: #"{"payloadText": null, "sourceTag": "[S]"}"#)
        #expect(withoutText.payloadText == nil)

        // sourceTag is required.
        #expect(throws: (any Error).self) {
            _ = try decodeContent(PayloadTextRequest.self, from: #"{"payloadText": "note"}"#)
        }
    }

    @Test("OperationalStandardCreateRequest requires all five fields")
    func operationalStandardCreateRequestDecodes() throws {
        let value = try decodeContent(OperationalStandardCreateRequest.self, from: #"""
        {
          "laneKey": "kitchen",
          "trackType": "photo",
          "expectedWindowStart": "22:00",
          "expectedWindowEnd": "23:00",
          "requiredCount": 2
        }
        """#)

        #expect(value.laneKey == "kitchen")
        #expect(value.trackType == "photo")
        #expect(value.expectedWindowStart == "22:00")
        #expect(value.expectedWindowEnd == "23:00")
        #expect(value.requiredCount == 2)

        #expect(throws: (any Error).self) {
            _ = try decodeContent(OperationalStandardCreateRequest.self, from: #"{"laneKey": "kitchen"}"#)
        }
    }

    @Test("OperationalStandardStatusUpdateRequest requires status and treats everything else as optional")
    func operationalStandardStatusUpdateRequestDecodes() throws {
        // Status-only is the sanctioned form.
        let statusOnly = try decodeContent(OperationalStandardStatusUpdateRequest.self, from: #"{"status": "PAUSED"}"#)

        #expect(statusOnly.status == "PAUSED")
        #expect(statusOnly.standardKey == nil)
        #expect(statusOnly.laneKey == nil)
        #expect(statusOnly.trackType == nil)
        #expect(statusOnly.expectedWindowStart == nil)
        #expect(statusOnly.expectedWindowEnd == nil)
        #expect(statusOnly.requiredCount == nil)
        #expect(statusOnly.createdAt == nil)

        // The optional core-metadata fields exist precisely so the handler can DETECT a
        // mutation attempt and reject it. Decoding must therefore succeed and surface
        // the offending field rather than fail — that is what makes the 400 possible.
        let mutationAttempt = try decodeContent(
            OperationalStandardStatusUpdateRequest.self,
            from: #"{"status": "ACTIVE", "requiredCount": 9, "laneKey": "bar"}"#
        )

        #expect(mutationAttempt.requiredCount == 9)
        #expect(mutationAttempt.laneKey == "bar")

        #expect(throws: (any Error).self) {
            _ = try decodeContent(OperationalStandardStatusUpdateRequest.self, from: #"{"laneKey": "bar"}"#)
        }
    }
}
