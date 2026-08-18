// MARK: - Lane and track validation
//
// The closed vocabularies an upload or an operational standard may use, and the
// validators that enforce them. Extracted verbatim from AIHOSAssetServer.swift by
// F-C2 — no value, signature, access level or behaviour changed.
//
// The two lane allowlists are deliberately different sets and must stay separate:
// asset lanes include finance and economy, standard lanes include maintenance. They
// answer different questions and merging them would silently widen both.
//
// Pure value rules with no dependencies, which is why this file imports nothing.

// Lane key allowlist and helper
let allowedLaneKeys: Set<String> = ["kitchen", "service", "finance", "unassigned", "bar", "cleaning", "economy"]
func validatedLaneKey(_ laneKey: String?) -> String? {
    guard let laneKey else { return "unassigned" }
    guard allowedLaneKeys.contains(laneKey) else { return nil }
    return laneKey
}

let allowedOperationalStandardLaneKeys: Set<String> = ["kitchen", "service", "bar", "cleaning", "maintenance", "unassigned"]
let allowedOperationalStandardTrackTypes: Set<String> = ["observation", "photo", "audio", "ocr"]

func validatedOperationalStandardLaneKey(_ laneKey: String) -> String? {
    guard allowedOperationalStandardLaneKeys.contains(laneKey) else { return nil }
    return laneKey
}

func validatedOperationalStandardTrackType(_ trackType: String) -> String? {
    guard allowedOperationalStandardTrackTypes.contains(trackType) else { return nil }
    return trackType
}
