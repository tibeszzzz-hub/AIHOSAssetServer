import Vapor

// MARK: - API transport types
//
// The request and response shapes of the HTTP API: what a client sends and what it
// gets back. Extracted verbatim from AIHOSAssetServer.swift by F-C1 — no name, member,
// optionality, ordering, conformance or CodingKeys changed, and none of them is public.
//
// These types carry no behaviour. They are the wire contract, so a change here is an
// API change even when it looks like a rename: the property names are the JSON keys,
// except where a type declares its own CodingKeys.

struct SyncMetadata: Codable {
    let captureTimestamp: String
    let sourceTag: String
    let fileName: String?
    let laneKey: String?
    let payloadText: String?
    let payloadTextSourceTag: String?
    let observationID: String?
}


struct MultipartSyncPayload: Content {
    let metadata: String
    let image: File
    let payloadText: String?
}

struct MultipartAudioPayload: Content {
    let metadata: String
    let audio: File
    let payloadText: String?
}


struct DecisionPayload: Content {
    let standardKey: String
    let expectedWindowStart: String
    let expectedWindowEnd: String
    let decisionType: String
}

struct ObservationDecisionPayload: Content {
    let decisionType: String
}

struct ObservationDecisionTraceResponse: Content {
    let id: String
    let targetAssetRecordID: String
    let decisionType: String
    let sourceTag: String
    let createdAt: String
}

struct GroupedObservationResponse: Content {
    let id: String
    let captureTimestamp: String
    let displayTimestamp: String
    let sourceTag: String
    let laneKey: String
    let files: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case captureTimestamp
        case displayTimestamp
        case sourceTag
        case laneKey = "lane_key"
        case files
    }
}

struct PayloadTextRequest: Content {
    let payloadText: String?
    let sourceTag: String
}

struct PayloadTextResponse: Content {
    let id: String
    let assetRecordID: String
    let payloadText: String?
    let sourceTag: String
    let createdAt: String
}

struct MechanicalTranscriptionResponse: Content {
    let assetRecordID: String
    let payloadTextID: String?
    let payloadText: String?
    let sourceTag: String
    let transcriptionStatus: String
    let reason: String?
    let createdAt: String
}

struct VisionOCRTestResponse: Content {
    let ocrStatus: String
    let rawText: String?
    let reason: String?
}

struct ShiftHandoverLogEntry: Content {
    let id: String
    let sourceTag: String
    let eventTimestamp: String
    let entryType: String
    let message: String
    let laneKey: String
}

struct OperationalStandardResponse: Content {
    let id: String
    let standardKey: String
    let laneKey: String
    let trackType: String
    let expectedWindowStart: String
    let expectedWindowEnd: String
    let requiredCount: Int
    let status: String
    let createdAt: String
}

struct OperationalStandardCreateRequest: Content {
    let laneKey: String
    let trackType: String
    let expectedWindowStart: String
    let expectedWindowEnd: String
    let requiredCount: Int
}

struct OperationalStandardStatusUpdateRequest: Content {
    let status: String
    let standardKey: String?
    let laneKey: String?
    let trackType: String?
    let expectedWindowStart: String?
    let expectedWindowEnd: String?
    let requiredCount: Int?
    let createdAt: String?
}

struct StandardStatusUpdateResponse: Content {
    let id: String
    let standardID: String
    let status: String
    let sourceTag: String
    let changedAt: String
}
