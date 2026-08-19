import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F2: the payload text read route lifted out of the composition root
//
// Order WFOS-20260819-PSKS-021. `GET /api/v1/assets/:assetID/payload-text` moved from
// main() into Sources/AIHOSAssetServer/PayloadTextReadRoutes.swift.
//
// WHY THESE TESTS
//   Unlike F-F1 this route reads the database, so the move has more that can drift
//   silently: the selected columns, the bind, the sort direction, the nullability of
//   payload_text, and the shape of the encoded response. A compiler will accept every
//   one of those being wrong. They are pinned below, together with the structural
//   facts that the route lives in the new file and that main() only calls the
//   registrar.
//
// The route manifest and the gate inventory already scan the whole library and still
// demand 21 routes with 20 gated, so route count and gating are covered there.

private let routeFileName = "PayloadTextReadRoutes.swift"

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

@Suite("F-F2 payload text read route extraction")
struct PayloadTextReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("assets", ":assetID", "payload-text")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the payload text read route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerPayloadTextReadRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The write route deliberately stayed behind")
    func writeRouteRemainsInTheCompositionRoot() throws {
        // Only the read side moved. Pinned so the split is a stated decision rather
        // than something a later reader has to reconstruct — and so that quietly
        // dragging the write route across counts as a change, not a tidy-up.
        let write = #"apiV1.post("assets", ":assetID", "payload-text")"#

        #expect(try serverSourceText().contains(write))
        #expect(try routeFileText().contains(write) == false)
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarSignatureIsPinned() throws {
        // The parameter label `apiV1` is load-bearing: the route manifest resolves a
        // registration's gate and its /api/v1 prefix from the receiver's name.
        //
        // That the signature has exactly one parameter is the point of the rest of
        // this assertion: the handler takes its database from `req.db`, so nothing had
        // to be threaded through from main() at all.
        #expect(try routeFileText().contains(
            "func registerPayloadTextReadRoutes(on apiV1: MachineGatedRoutes) {"
        ))
    }

    @Test("The route file introduces no configuration lookup and no global state")
    func routeFileHasNoOwnConfigurationOrState() throws {
        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        // Column zero makes this a scope check rather than a spelling check: locals
        // inside the handler must stay allowed.
        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Query contract

    @Test("The query is read-only and selects exactly the five pinned columns")
    func queryContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "SELECT",
            "id,",
            #""assetRecordID","#,
            "payload_text,",
            "source_tag,",
            "created_at",
            "FROM asset_payload_texts",
            #"WHERE "assetRecordID" = \(bind: assetID)"#,
            "ORDER BY created_at ASC"
        ] {
            #expect(code.contains(pinned), "Query contract element changed or missing: \(pinned)")
        }

        // A read route must stay a read route. This is the one property of the move
        // that would be actively dangerous to get wrong.
        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }
    }

    // MARK: Response contract

    @Test("The response mapping, nullability and status codes are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for pinned in [
            "guard let sql = req.db as? SQLDatabase else {",
            "return Response(status: .internalServerError)",
            #"guard let assetIDString = req.parameters.get("assetID"),"#,
            "let assetID = UUID(uuidString: assetIDString) else {",
            "return Response(status: .badRequest)",
            "let rows = try await sql.raw(",
            "-> PayloadTextResponse in",
            #"try row.decode(column: "id", as: UUID.self).uuidString"#,
            #"try row.decode(column: "assetRecordID", as: UUID.self).uuidString"#,
            #"try row.decode(column: "source_tag", as: String.self)"#,
            #"try row.decode(column: "created_at", as: String.self)"#,
            "let response = Response(status: .ok)",
            "try response.content.encode(payloadTexts)"
        ] {
            #expect(code.contains(pinned), "Response contract line changed or missing: \(pinned)")
        }

        // payload_text is the only nullable column in the projection. Decoding it as a
        // non-optional would turn an empty transcription into a decode failure at
        // runtime, which no test that only checks column names would notice.
        #expect(code.contains(#"try row.decode(column: "payload_text", as: String?.self)"#))

        // Source awareness is part of what this route reports and is contract, not chatter.
        #expect(code.contains(#"print("Payload Text retrieval PASS: \(payloadTexts.count) entries")"#))
        #expect(code.contains(
            #"print("Source Awareness: payload_text returned separately from original asset media")"#
        ))
        #expect(code.contains(#"print("Payload Text retrieval failed: invalid assetID")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "ORDER BY created_at ASC", with: "ORDER BY created_at DESC")

        #expect(mutated.contains("ORDER BY created_at ASC") == false)
        #expect(mutated.contains("ORDER BY created_at DESC"))
    }
}
