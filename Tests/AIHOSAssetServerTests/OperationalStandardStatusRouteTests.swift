import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G8: the operational standard status update route
//
// Order WFOS-20260820-PSKS-023. `PATCH /api/v1/standards/:standardID/status` moved from
// main() into Sources/AIHOSAssetServer/OperationalStandardStatusRoutes.swift.
//
// WHY THESE TESTS
//   This is the only route in the server that updates an existing row and the only one
//   that runs inside an explicit transaction. Both facts are the subject here:
//
//   - Status is the single mutable property of a standard. Every other field is
//     append-only, and a request carrying one is refused with an explicit reason rather
//     than silently ignored — which would leave a caller believing an edit applied.
//   - The status change and the timeline row must both happen or neither. If only the
//     update landed, isStandardActive would resolve historical status from an
//     incomplete record. Splitting the transaction would compile and would corrupt the
//     timeline only under failure.

private let routeFileName = "OperationalStandardStatusRoutes.swift"

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

@Suite("F-G8 operational standard status route extraction")
struct OperationalStandardStatusRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.on(.PATCH, "standards", ":standardID", "status")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the status update route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerOperationalStandardStatusRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("Exactly three registrations remain in the composition root")
    func remainingRegistrationsArePinned() throws {
        // Uses the manifest parser rather than a hand-rolled scan, so migration
        // registrations and other lines that merely resemble route calls cannot be
        // miscounted. Pinned so the remaining set is a stated position, not an accident.
        let remaining = parseRouteRegistrations(inSource: try serverSourceText())
            .compactMap(\.signature)
            .sorted()

        #expect(remaining == [
            "POST /api/v1/assets/:assetID/transcribe-audio",
            "POST /api/v1/audio",
            "POST /api/v1/sync"
        ], "Registrations left in main(): \(remaining)")
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarTakesNothingElse() throws {
        #expect(try routeFileText().contains(
            "func registerOperationalStandardStatusRoutes(on apiV1: MachineGatedRoutes) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for absent in ["Environment.get", "STORAGE_PATH", "storageDirectory", "operationsTimeZone",
                       "AIHOS_", "Vision", "canImport", "FileManager", "AppleSpeechTranscriber"] {
            #expect(code.contains(absent) == false, "\(absent) appeared in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Status is the only mutable property

    @Test("A request carrying any core field is refused, not silently ignored")
    func coreMetadataMutationIsRefused() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // All seven optional fields exist on the request type purely so their presence
        // can be detected. Dropping any one from this condition would let that field be
        // accepted and ignored, which is worse than refusing it.
        for field in [
            "payload.standardKey != nil",
            "|| payload.laneKey != nil",
            "|| payload.trackType != nil",
            "|| payload.expectedWindowStart != nil",
            "|| payload.expectedWindowEnd != nil",
            "|| payload.requiredCount != nil",
            "|| payload.createdAt != nil"
        ] {
            #expect(code.contains(field), "Core-field detection changed or missing: \(field)")
        }
        #expect(code.contains(#""reason": "Mutation of core metadata is not allowed.""#))
        #expect(code.contains(#"print("Operational Standard status update blocked: core metadata mutation attempted")"#))

        // Only two statuses are accepted, with their own reason.
        #expect(code.contains(#"guard payload.status == "ACTIVE" || payload.status == "PAUSED" else {"#))
        #expect(code.contains(#""reason": "status must be ACTIVE or PAUSED""#))

        // Invalid id and unknown standard each keep their own status and reason.
        #expect(code.contains(#""reason": "invalid operational standard id""#))
        #expect(code.contains("guard existingRows.count == 1 else {"))
        #expect(code.contains("return Response(status: .notFound)"))
    }

    // MARK: The transaction

    @Test("The update and the timeline row are written in one transaction")
    func bothWritesShareOneTransaction() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("try await req.db.transaction { database in"))
        #expect(code.contains("guard let transactionSQL = database as? SQLDatabase else {"))

        // Both statements must run on the transaction's connection, not the outer one.
        #expect(code.components(separatedBy: "transactionSQL.raw(").count - 1 == 2,
                "The two writes no longer both run inside the transaction")
        #expect(code.contains("UPDATE operational_standards"))
        #expect(code.contains("INSERT INTO standard_status_updates"))

        // The update comes first, then the timeline row recording that transition.
        let update = try #require(code.range(of: "UPDATE operational_standards")?.lowerBound)
        let insert = try #require(code.range(of: "INSERT INTO standard_status_updates")?.lowerBound)
        #expect(update < insert)

        // Exactly one UPDATE in the whole file: status is the only mutable property.
        #expect(code.components(separatedBy: "UPDATE ").count - 1 == 1)
        #expect(code.contains(#"SET status = \(bind: payload.status)"#))
        #expect(code.contains("DELETE") == false, "A delete appeared in \(routeFileName)")

        #expect(code.contains(#"print("Governance: status-only update; core metadata unchanged")"#))
        #expect(code.contains(#"print("Status Timeline: transition inserted append-only")"#))
    }

    // MARK: The read-back

    @Test("The response is built from a fresh read, not from the request")
    func responseComesFromTheDatabase() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Three queries in total: existence check, the transaction pair, then read-back.
        #expect(code.contains("let updatedRows = try await sql.raw("))
        #expect(code.contains("guard updatedRows.count == 1 else {"))
        #expect(code.contains(#"print("Operational Standard status update failed: updated row missing \(standardID.uuidString)")"#))

        for decoded in [
            #"try row.decode(column: "standardKey", as: String.self)"#,
            #"try row.decode(column: "lane_key", as: String.self)"#,
            #"try row.decode(column: "track_type", as: String.self)"#,
            #"try row.decode(column: "expected_window_start", as: String.self)"#,
            #"try row.decode(column: "expected_window_end", as: String.self)"#,
            #"try row.decode(column: "requiredCount", as: Int.self)"#,
            #"try row.decode(column: "status", as: String.self)"#,
            #"try row.decode(column: "created_at", as: String.self)"#
        ] {
            #expect(code.contains(decoded), "Read-back decode changed or missing: \(decoded)")
        }

        // The echoed status comes from the row, not from the payload.
        #expect(code.contains("status: status,"))
        #expect(code.contains("status: payload.status") == false,
                "The response echoes the requested status rather than the stored one")

        #expect(code.contains(#"let statusSourceTag = "[M]""#))
        #expect(code.contains("let changedAt = ISO8601DateFormatter().string(from: Date())"))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "try await req.db.transaction { database in",
                                  with: "if true { let database = req.db")

        #expect(mutated.contains("try await req.db.transaction { database in") == false)
        #expect(try routeFileText().contains("try await req.db.transaction { database in"))
    }
}
