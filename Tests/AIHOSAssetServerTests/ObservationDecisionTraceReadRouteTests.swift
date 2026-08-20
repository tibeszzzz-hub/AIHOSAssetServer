import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F5: the observation decision trace read route
//
// Order WFOS-20260819-PSKS-027. `GET /api/v1/assets/:assetID/decision-traces` moved
// from main() into Sources/AIHOSAssetServer/ObservationDecisionTraceReadRoutes.swift.
//
// WHY THESE TESTS
//   This is the first extracted route that issues two queries, and the relationship
//   between them is the contract. The asset record is checked for existence first and
//   an unknown asset answers 404; only then are the traces read. Collapsing that into
//   one query would turn "unknown asset" into "no decisions", which answers a
//   different question with the same body — and it would compile.
//
//   Decision traces are governance evidence, so the ascending sort and the projection
//   are pinned for the same reason as the status timeline: a trace list read backwards
//   misrepresents the order decisions were taken in.

private let routeFileName = "ObservationDecisionTraceReadRoutes.swift"

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

@Suite("F-F5 observation decision trace read route extraction")
struct ObservationDecisionTraceReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("assets", ":assetID", "decision-traces")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the decision trace read route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerObservationDecisionTraceReadRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The write route lives in its own file, not in this one")
    func writeRouteIsSeparate() throws {
        // F-F5 moved the read side and left the write in the composition root; F-G6
        // then moved the write into a file of its own. What this guards is unchanged:
        // the read file holds reads only.
        let write = #"apiV1.post("assets", ":assetID", "decision-traces")"#

        #expect(try routeFileText().contains(write) == false,
                "The write route was folded into \(routeFileName)")

        let writeSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "ObservationDecisionTraceWriteRoutes.swift" }?.text,
            "ObservationDecisionTraceWriteRoutes.swift is missing from the library"
        )
        #expect(writeSource.contains(write))
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarSignatureIsPinned() throws {
        #expect(try routeFileText().contains(
            "func registerObservationDecisionTraceReadRoutes(on apiV1: MachineGatedRoutes) {"
        ))
    }

    @Test("The route file introduces no configuration lookup and no global state")
    func routeFileHasNoOwnConfigurationOrState() throws {
        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "OPERATIONS_TIMEZONE", "AIHOS_", "storageDirectory"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: The two-query contract

    @Test("The asset existence check runs before the trace read and answers 404")
    func existenceCheckPrecedesTheTraceRead() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Two raw queries, not one.
        let rawQueries = code.components(separatedBy: "sql.raw(").count - 1
        #expect(rawQueries == 2, "Expected exactly two queries, found \(rawQueries)")

        for pinned in [
            "SELECT id",
            "FROM asset_records",
            #"WHERE id = \(bind: assetID)"#,
            "LIMIT 1",
            "guard assetRows.count == 1 else {",
            "return Response(status: .notFound)"
        ] {
            #expect(code.contains(pinned), "Existence check element changed or missing: \(pinned)")
        }

        // Order is the point: an unknown asset must 404 rather than return an empty
        // list, so the existence check has to come first in the source.
        let existenceIndex = try #require(code.range(of: "FROM asset_records")?.lowerBound)
        let traceIndex = try #require(code.range(of: "FROM decision_traces")?.lowerBound)
        #expect(existenceIndex < traceIndex,
                "The trace read precedes the existence check, so an unknown asset would return [] instead of 404")
    }

    // MARK: Query and response contract

    @Test("The trace query is read-only and selects exactly the five pinned columns")
    func traceQueryContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "id,",
            "target_asset_record_id,",
            #""decision_type","#,
            #""source_tag","#,
            #""created_at""#,
            "FROM decision_traces",
            #"WHERE target_asset_record_id = \(bind: assetID)"#,
            #"ORDER BY "created_at" ASC"#
        ] {
            #expect(code.contains(pinned), "Query contract element changed or missing: \(pinned)")
        }

        // Governance evidence read backwards misrepresents the order decisions were
        // taken in, so descending must not appear at all.
        #expect(code.contains("DESC") == false, "The decision trace list is sorted newest-first")

        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }
    }

    @Test("The response mapping, status codes and the 400 body are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "guard let sql = req.db as? SQLDatabase else {",
            "return Response(status: .internalServerError)",
            #"guard let assetIDString = req.parameters.get("assetID"),"#,
            "let assetID = UUID(uuidString: assetIDString) else {",
            "let response = Response(status: .badRequest)",
            "-> ObservationDecisionTraceResponse in",
            #"try row.decode(column: "id", as: UUID.self).uuidString"#,
            #"try row.decode(column: "target_asset_record_id", as: UUID.self).uuidString"#,
            #"try row.decode(column: "decision_type", as: String.self)"#,
            #"try row.decode(column: "source_tag", as: String.self)"#,
            #"try row.decode(column: "created_at", as: String.self)"#,
            "let response = Response(status: .ok)",
            "try response.content.encode(decisionTraces)"
        ] {
            #expect(code.contains(pinned), "Response contract line changed or missing: \(pinned)")
        }

        // The 400 carries a body a client may read.
        #expect(code.contains(#""reason": "invalid asset id""#))

        // Three distinct log lines, including the sort direction.
        #expect(code.contains(#"print("Observation Decision Trace retrieval failed: invalid assetID")"#))
        #expect(code.contains(#"print("Observation Decision Trace retrieval PASS: \(decisionTraces.count) traces")"#))
        #expect(code.contains(#"print("Observation Decision Trace sort: created_at ASC")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "return Response(status: .notFound)",
                                  with: "return Response(status: .ok)")

        #expect(mutated.contains("return Response(status: .notFound)") == false)
        #expect(try routeFileText().contains("return Response(status: .notFound)"))
    }
}
