import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G4: the payload text write route
//
// Order WFOS-20260820-PSKS-015. `POST /api/v1/assets/:assetID/payload-text` moved from
// main() into Sources/AIHOSAssetServer/PayloadTextWriteRoutes.swift. It is the write
// half of the resource whose read half moved in F-F2.
//
// WHY THESE TESTS
//   This route stores a text representation of an existing observation. Four properties
//   would each compile if broken and each would corrupt the record rather than crash:
//
//   - Three distinct refusals: malformed id 400, undecodable body 400, unknown asset
//     404. Merging any two would answer the wrong question.
//   - The existence check runs before the insert, so a payload can never be attached to
//     an asset that is not there.
//   - Only asset_payload_texts is written. The original observation is never touched.
//   - createdAt is generated server-side; a caller-supplied timestamp would let a
//     record claim a time it did not happen at.

private let routeFileName = "PayloadTextWriteRoutes.swift"

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

@Suite("F-G4 payload text write route extraction")
struct PayloadTextWriteRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.post("assets", ":assetID", "payload-text")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the payload text write route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerPayloadTextWriteRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The read half stays in its own file")
    func readRouteIsSeparate() throws {
        let read = #"apiV1.get("assets", ":assetID", "payload-text")"#

        #expect(try routeFileText().contains(read) == false,
                "The read route was folded into \(routeFileName)")

        let readSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "PayloadTextReadRoutes.swift" }?.text,
            "PayloadTextReadRoutes.swift is missing from the library"
        )
        #expect(readSource.contains(read))
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarTakesNothingElse() throws {
        #expect(try routeFileText().contains(
            "func registerPayloadTextWriteRoutes(on apiV1: MachineGatedRoutes) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "storageDirectory", "OPERATIONS_TIMEZONE", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }
        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: The three refusals

    @Test("Each refusal keeps its own status and its own reason")
    func refusalsStayDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Malformed asset id: 400.
        #expect(code.contains(#"guard let assetIDString = req.parameters.get("assetID"),"#))
        #expect(code.contains("let assetID = UUID(uuidString: assetIDString) else {"))
        #expect(code.contains(#"print("Payload Text INSERT failed: invalid assetID")"#))

        // Undecodable body: also 400, but a different reason and a different log line.
        #expect(code.contains("payload = try req.content.decode(PayloadTextRequest.self)"))
        #expect(code.contains(#"print("Payload Text decode failed: \(error)")"#))

        // Unknown asset: 404, not 400 and not an empty success.
        #expect(code.contains("guard assetRows.count == 1 else {"))
        #expect(code.contains(#"print("Payload Text INSERT failed: asset not found \(assetID.uuidString)")"#))
        #expect(code.contains("return Response(status: .notFound)"))

        // Two 400s and one 500 for a failed insert — four refusal returns in total.
        #expect(code.components(separatedBy: "return Response(status: .badRequest)").count - 1 == 2)
        #expect(code.components(separatedBy: "return Response(status: .internalServerError)").count - 1 == 2)
    }

    @Test("The asset must exist before anything is written")
    func existenceCheckPrecedesTheInsert() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("SELECT id"))
        #expect(code.contains("FROM asset_records"))
        #expect(code.contains(#"WHERE id = \(bind: assetID)"#))

        let selectIndex = try #require(code.range(of: "FROM asset_records")?.lowerBound)
        let insertIndex = try #require(code.range(of: "INSERT INTO asset_payload_texts")?.lowerBound)
        #expect(selectIndex < insertIndex,
                "The insert runs before the asset is known to exist, which would leave orphan rows")
    }

    // MARK: What is written, and what is not

    @Test("Only the payload table is written, and the original observation is untouched")
    func originalAssetIsNeverModified() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("INSERT INTO asset_payload_texts"))
        #expect(code.contains(#"(id, "assetRecordID", payload_text, source_tag, created_at)"#))
        #expect(code.contains(
            #"(\(bind: payloadTextID), \(bind: assetID), \(bind: payload.payloadText), \(bind: payload.sourceTag), \(bind: createdAt));"#
        ))

        // The observation itself is read from and never modified. Governance triggers
        // would block it anyway, but the route must not even try.
        for forbidden in ["UPDATE asset_records", "DELETE FROM asset_records", "INSERT INTO asset_records"] {
            #expect(code.contains(forbidden) == false, "\(forbidden) appeared in \(routeFileName)")
        }
        #expect(code.contains(
            #"print("Source Awareness: original asset unchanged; payload_text stored as subordinate representation")"#
        ))
    }

    @Test("The identifier and timestamp are generated server-side")
    func idAndTimestampAreServerGenerated() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("let payloadTextID = UUID()"))
        #expect(code.contains("let createdAt = ISO8601DateFormatter().string(from: Date())"))

        // A caller-supplied timestamp would let a record claim a time it did not happen
        // at, so neither field may be read from the request.
        #expect(code.contains("payload.createdAt") == false)
        #expect(code.contains("payload.id") == false)

        // The response echoes exactly the row that was written.
        for field in [
            "id: payloadTextID.uuidString,",
            "assetRecordID: assetID.uuidString,",
            "payloadText: payload.payloadText,",
            "sourceTag: payload.sourceTag,",
            "createdAt: createdAt"
        ] {
            #expect(code.contains(field), "Response field changed or missing: \(field)")
        }
        #expect(code.contains("let response = Response(status: .ok)"))

        for logged in [
            #"print("Payload Text INSERT PASS")"#,
            #"print("assetRecordID: \(assetID.uuidString)")"#,
            #"print("payloadTextID: \(payloadTextID.uuidString)")"#,
            #"print("sourceTag: \(payload.sourceTag)")"#,
            #"print("createdAt: \(createdAt)")"#
        ] {
            #expect(code.contains(logged), "Log line changed or missing: \(logged)")
        }
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
