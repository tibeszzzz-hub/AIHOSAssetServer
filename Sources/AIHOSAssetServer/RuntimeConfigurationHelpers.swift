import Vapor
import Foundation

// MARK: - Server bind address
//
// The address Vapor binds to is configuration, not a constant, so it can be moved
// between the two operating modes without a code change. Today's production mode is
// unchanged: with the variable absent the server binds to 0.0.0.0 exactly as before.
//
// The allowed set is closed on purpose, and it is a security control rather than a
// convenience. A typo in a bind address is not a cosmetic error — falling back to a
// default on an unrecognised value could turn an intended loopback-only binding into
// a broad public one, silently. So an unrecognised value refuses startup instead
// (§9.3, R17: a failing control blocks, it never lets through).
//
// This atom adds the lever only. It does not change any deployment configuration and
// proves nothing about the operational return path, which is exercised separately.

/// Name of the environment variable selecting the bind address.
let serverHostEnvironmentKey = "AIHOS_SERVER_HOST"

/// The address used when the variable is absent — byte-identical to the previous
/// hardcoded binding, so an unconfigured deployment behaves exactly as it did before.
let defaultServerHost = "0.0.0.0"

/// Every address this server may bind to.
///
/// Deliberately two entries and no parsing: all interfaces, or loopback only. There is
/// no DNS resolution, no wildcard and no arbitrary host interpretation, because each of
/// those would turn a misconfiguration into an exposure decision made by a resolver
/// rather than by a person.
let allowedServerHosts: Set<String> = ["0.0.0.0", "127.0.0.1"]

/// Raised at boot when the configured bind address is not one of the allowed ones.
struct ServerHostError: Error, CustomStringConvertible {
    var description: String {
        "\(serverHostEnvironmentKey) must be set to exactly one of "
            + allowedServerHosts.sorted().joined(separator: " or ")
            + ", or left unset to bind \(defaultServerHost). The configured value was not accepted."
    }
}

/// Resolves the bind address from a raw configuration value.
///
/// Kept separate from the environment lookup so the fail-closed rule can be tested
/// without mutating process environment state — same shape as `MachineCredential` and
/// the operations time zone.
///
/// Absent means "unconfigured" and yields the default. Present but empty, blank or
/// unrecognised is a configuration mistake and throws: a variable someone took the
/// trouble to set, but set wrongly, must never be silently ignored.
///
/// The rejected value is deliberately not echoed. With only two valid values the error
/// is already fully actionable, and echoing whatever ended up in the variable would
/// write it to the boot log — which matters if it was pasted there by mistake.
func resolvedServerHost(fromConfiguredValue value: String?) throws -> String {
    guard let value else {
        return defaultServerHost
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

    guard allowedServerHosts.contains(trimmed) else {
        throw ServerHostError()
    }

    return trimmed
}

/// Resolves the bind address from the process environment.
func resolvedServerHost() throws -> String {
    try resolvedServerHost(fromConfiguredValue: Environment.get(serverHostEnvironmentKey))
}

func resolvedStorageDirectory() throws -> String {
    guard let rawStoragePath = Environment.get("STORAGE_PATH")?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawStoragePath.isEmpty else {
        print("STORAGE_PATH missing — server startup refused")
        throw Abort(.internalServerError, reason: "STORAGE_PATH is required")
    }

    guard rawStoragePath.hasPrefix("/") else {
        print("STORAGE_PATH invalid — absolute path required: \(rawStoragePath)")
        throw Abort(.internalServerError, reason: "STORAGE_PATH must be an absolute path")
    }

    let normalizedStoragePath = rawStoragePath.hasSuffix("/")
        ? String(rawStoragePath.dropLast())
        : rawStoragePath

    do {
        try FileManager.default.createDirectory(
            atPath: normalizedStoragePath,
            withIntermediateDirectories: true
        )

        let writeTestPath = normalizedStoragePath + "/.aihos-storage-write-test"
        try Data("ok".utf8).write(to: URL(fileURLWithPath: writeTestPath))
        try FileManager.default.removeItem(atPath: writeTestPath)
    } catch {
        print("STORAGE_PATH validation failed: \(error)")
        throw Abort(.internalServerError, reason: "STORAGE_PATH is not writable")
    }

    print("Storage configuration PASS")
    print("STORAGE_PATH: \(rawStoragePath)")
    print("storageDirectory: \(normalizedStoragePath)")

    return normalizedStoragePath
}
