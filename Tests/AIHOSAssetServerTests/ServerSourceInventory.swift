import Foundation

// MARK: - Test-only inventory helpers for the characterization safety net
//
// Atom: SERVER-MOD-A0 (WFOS-20260817-PSKS-020), baseline WFOS-20260817-KSPS-021,
// binding corrections GS-C1/GS-C2/GS-C7 (WFOS-20260817-GSPS-006).
//
// WHY THIS READS SOURCE TEXT RATHER THAN A RUNNING APPLICATION
//   Every route registration, migration registration and transport type lives inside
//   `AIHOSAssetServer.main()`, a 1783-line function that ends in `app.execute()` and
//   therefore starts a live server. It cannot be invoked from a test, and A0 is
//   explicitly forbidden from changing any production code to make it invocable
//   (PSKS-020, UTANFÖR SCOPE). Reading the real source file is consequently the only
//   way to characterize the real baseline in this atom.
//
// WHAT THESE HELPERS DO AND DO NOT GUARANTEE
//   They protect against LOSS AND DRIFT: a route that disappears or changes path, a
//   migration that is renamed or reordered, a transport type that stops conforming.
//   They are NOT an authorization check. Runtime protection is `MachineAuthGate` and
//   `verifyMachineGateCoverage`, which refuse to boot when a route is registered
//   UNGATED — that mechanism can never notice a route that is MISSING. The two
//   protections are complementary and neither substitutes for the other
//   (PSKS-020 AC-1, final bullet).
//
// WHY EVERY PARSER HERE IS A PURE FUNCTION OF ITS INPUT TEXT
//   So the identical parser can be aimed at a deliberately mutated fixture. A scanner
//   that silently matches nothing looks exactly like a clean result; making the parser
//   pure is what lets each test prove it can actually fail (GS-C7).

/// Absolute path to the production server source, resolved from this test file.
///
/// Three `deletingLastPathComponent()` calls walk `AIHOSAssetServerTests` → `Tests` →
/// package root. Same technique the pre-existing gate inventory test already uses.
let serverSourceURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/AIHOSAssetServerTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
    .appendingPathComponent("Sources/AIHOSAssetServer/AIHOSAssetServer.swift")

/// Reads the production server source. Throws rather than returning "" so a broken
/// path can never be mistaken for a file with no violations in it.
func serverSourceText() throws -> String {
    try String(contentsOf: serverSourceURL, encoding: .utf8)
}

/// Splits source into trimmed lines. Registrations in this codebase are single-line,
/// which every parser below relies on; `assertRegistrationsAreSingleLine` guards it.
func trimmedSourceLines(_ source: String) -> [String] {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

// MARK: - Route registrations

/// The three routes-builder identifiers used in `main()`.
///
/// `apiV1` and `gated` are `MachineGatedRoutes` values (gated). `app` is the raw
/// application (ungated) and is only allowed to carry the classified liveness probe.
let routeBuilderIdentifiers = ["app", "apiV1", "gated"]

/// Every routing verb that can put a route into the table, including the grouping
/// verbs — a route hidden behind `app.grouped(...)` must not slip past this parser.
let routeRegistrationVerbs = ["get", "post", "put", "patch", "delete", "on", "webSocket", "group", "grouped"]

/// One parsed route registration from the server source.
struct RouteRegistration: Equatable, Hashable {
    /// Builder it was registered on: `app`, `apiV1` or `gated`.
    let builder: String
    /// Verb exactly as written in the source.
    let verb: String
    /// Resolved HTTP method, or `nil` for verbs that carry no method of their own
    /// (`group`, `grouped`, `webSocket`). A `nil` here is itself a finding.
    let method: String?
    /// Path components as written, excluding any builder prefix.
    let path: [String]

    /// Whether the registration goes through the central machine auth gate.
    var isGated: Bool { builder == "apiV1" || builder == "gated" }

    /// Stable signature, e.g. `GET /api/v1/records`. Formatted exactly like
    /// `routeSignature(_:)` in MachineAuthGate.swift so the two can be compared.
    var signature: String? {
        guard let method else { return nil }
        let prefix: [String] = builder == "apiV1" ? ["api", "v1"] : []
        return "\(method) /\((prefix + path).joined(separator: "/"))"
    }
}

/// Parses every route registration in the given source text.
///
/// Pure function of `source` — point it at a mutated fixture to prove it can fail.
func parseRouteRegistrations(inSource source: String) -> [RouteRegistration] {
    var registrations: [RouteRegistration] = []

    for line in trimmedSourceLines(source) {
        for builder in routeBuilderIdentifiers {
            for verb in routeRegistrationVerbs {
                let opening = "\(builder).\(verb)("
                guard line.hasPrefix(opening) else { continue }

                let arguments = routeArgumentText(line: line, after: opening)
                registrations.append(
                    RouteRegistration(
                        builder: builder,
                        verb: verb,
                        method: httpMethod(verb: verb, arguments: arguments),
                        path: quotedStringLiterals(in: arguments)
                    )
                )
            }
        }
    }

    return registrations
}

/// Isolates the argument list of a registration call.
///
/// Truncates at the trailing closure (`") {"`) so nothing from the handler body is
/// read, then at the first labelled argument (`body:`) so a body-size literal such as
/// `"10mb"` is never mistaken for a path component.
private func routeArgumentText(line: String, after opening: String) -> String {
    var text = String(line.dropFirst(opening.count))

    if let closure = text.range(of: ") {") {
        text = String(text[text.startIndex..<closure.lowerBound])
    }

    if let labelled = text.range(of: "body:") {
        text = String(text[text.startIndex..<labelled.lowerBound])
    }

    return text
}

/// Resolves the HTTP method for a registration.
///
/// Method-named verbs map directly. `on` carries its method as a leading `.POST`-style
/// member reference. Grouping verbs carry no method and yield `nil`.
private func httpMethod(verb: String, arguments: String) -> String? {
    switch verb {
    case "get", "post", "put", "patch", "delete":
        return verb.uppercased()
    case "on":
        let trimmed = arguments.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(".") else { return nil }
        let token = trimmed.dropFirst().prefix { $0.isLetter }
        return token.isEmpty ? nil : String(token).uppercased()
    default:
        return nil
    }
}

/// Extracts every double-quoted literal, honouring backslash escapes.
func quotedStringLiterals(in text: String) -> [String] {
    var literals: [String] = []
    var current = ""
    var insideLiteral = false
    var escaped = false

    for character in text {
        if escaped {
            if insideLiteral { current.append(character) }
            escaped = false
            continue
        }

        if character == "\\" {
            escaped = true
            continue
        }

        if character == "\"" {
            if insideLiteral {
                literals.append(current)
                current = ""
                insideLiteral = false
            } else {
                insideLiteral = true
            }
            continue
        }

        if insideLiteral { current.append(character) }
    }

    return literals
}

// MARK: - Migration registrations

/// Parses `app.migrations.add(SomeMigration())` in source order.
///
/// Order is the whole point: Fluent executes migrations in registration order, and
/// registration order in this file already differs from declaration order.
func parseMigrationRegistrations(inSource source: String) -> [String] {
    let opening = "app.migrations.add("

    return trimmedSourceLines(source).compactMap { line in
        guard line.hasPrefix(opening) else { return nil }
        let name = line.dropFirst(opening.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

// MARK: - Type declarations

/// Names of every `struct` in the source declaring the given conformance, in source
/// order. Used to pin the 12 migration types and the 15 `Content` transport types.
func declaredStructNames(conformingTo protocolName: String, inSource source: String) -> [String] {
    trimmedSourceLines(source).compactMap { line in
        guard line.hasPrefix("struct "), line.hasSuffix("{") else { return nil }

        let declaration = line.dropFirst("struct ".count).dropLast()
        let parts = declaration.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let conformances = parts[1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard conformances.contains(protocolName) else { return nil }
        return parts[0].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - SQL and sorting contracts

/// Every `ORDER BY` clause in the source, normalised to single spaces, in source order.
///
/// Result ordering is part of the client contract for the read routes, and it lives in
/// raw SQL strings that no type checker inspects.
func parseOrderByClauses(inSource source: String) -> [String] {
    trimmedSourceLines(source).compactMap { line in
        guard line.hasPrefix("ORDER BY ") else { return nil }
        return line.split(separator: " ").joined(separator: " ")
    }
}

/// Counts Swift-side descending date comparators (`return firstDate > secondDate`).
///
/// Two read routes re-sort in Swift after the SQL query, in the opposite direction to
/// the SQL clause they used. A refactor that drops one would silently reverse a list.
func countDescendingDateComparators(inSource source: String) -> Int {
    trimmedSourceLines(source).filter { $0 == "return firstDate > secondDate" }.count
}

/// Body of a top-level declaration, from the line starting with `prefix` up to the
/// first line that is exactly `}`.
///
/// Used to scope an assertion to one function instead of the whole 2954-line file —
/// checking "the source contains no LIMIT" would be meaningless at file scope.
/// Returns `nil` when the declaration is not found, so a moved declaration fails the
/// test rather than silently matching an empty body.
func declarationBody(startingWithLinePrefix prefix: String, inSource source: String) -> [String]? {
    let lines = trimmedSourceLines(source)
    guard let start = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }

    var body: [String] = []
    for line in lines[(start + 1)...] {
        if line == "}" { return body }
        body.append(line)
    }

    return nil
}

// MARK: - Difference reporting

/// Difference between an observed inventory and the pinned baseline.
struct InventoryDifference: Equatable {
    let missing: [String]
    let unexpected: [String]

    var isClean: Bool { missing.isEmpty && unexpected.isEmpty }
}

/// Compares an observed set of signatures against the pinned baseline.
func inventoryDifference(observed: [String], expected: Set<String>) -> InventoryDifference {
    let observedSet = Set(observed)

    return InventoryDifference(
        missing: expected.subtracting(observedSet).sorted(),
        unexpected: observedSet.subtracting(expected).sorted()
    )
}

/// Signatures appearing more than once. A duplicate is drift even when the set matches.
func duplicatedSignatures(in signatures: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for signature in signatures { counts[signature, default: 0] += 1 }
    return counts.filter { $0.value > 1 }.keys.sorted()
}
