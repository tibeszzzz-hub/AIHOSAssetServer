import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G6: the observation decision trace write route
//
// Order WFOS-20260820-PSKS-019. `POST /api/v1/assets/:assetID/decision-traces` moved
// from main() into Sources/AIHOSAssetServer/ObservationDecisionTraceWriteRoutes.swift.
//
// WHY THESE TESTS
//   Two different decisions share the decision_traces table: this one is bound to an
//   observation, the F-G5 one to a standard and window. They are told apart only by
//   which columns are filled, and this route writes explicit NULLs into standard_key
//   and both window bounds to say which kind it is. Those NULLs look like noise and are
//   contract: the handover log reads that same column to pick a message shape, and a
//   database check constraint rejects a row with both targets or neither.
//
//   Everything else follows the pattern already established for write routes: three
//   refusals with distinct bodies, an existence check before the insert, an allowlist
//   of one decision type, and server-decided source tag and timestamp.

private let routeFileName = "ObservationDecisionTraceWriteRoutes.swift"

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

@Suite("F-G6 observation decision trace write route extraction")
struct ObservationDecisionTraceWriteRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.post("assets", ":assetID", "decision-traces")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the decision trace write route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerObservationDecisionTraceWriteRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The read half and the standard-scoped sibling each stay in their own file")
    func siblingRoutesAreSeparate() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"apiV1.get("assets", ":assetID", "decision-traces")"#) == false,
                "The read route was folded into \(routeFileName)")
        #expect(code.contains(#"apiV1.post("decisions")"#) == false,
                "The standard-scoped decision route was folded into \(routeFileName)")
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else")
    func registrarTakesNothingElse() throws {
        #expect(try routeFileText().contains(
            "func registerObservationDecisionTraceWriteRoutes(on apiV1: MachineGatedRoutes) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        // Pure SQL: no storage, no external service, no configuration. That is why this
        // was chosen over the five-lines-shorter vision-ocr route.
        for lookup in ["Environment.get", "STORAGE_PATH", "storageDirectory",
                       "OPERATIONS_TIMEZONE", "operationsTimeZone", "AIHOS_",
                       "Vision", "canImport", "AppleSpeechTranscriber"] {
            #expect(code.contains(lookup) == false, "\(lookup) appeared in \(routeFileName)")
        }
        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: What makes this an observation decision

    @Test("The standard columns are written as explicit NULLs")
    func standardColumnsAreExplicitlyNull() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(
            #"(id, "standard_key", "expected_window_start", "expected_window_end", target_asset_record_id, "decision_type", "source_tag", "created_at")"#
        ))
        // Three NULLs, then the asset id. This is the shape that makes the row an
        // observation decision rather than a standard-scoped one; the handover log and
        // a database check constraint both depend on it.
        #expect(code.contains(
            #"(\(bind: decisionTraceID), NULL, NULL, NULL, \(bind: assetID), \(bind: payload.decisionType), \(bind: sourceTag), \(bind: createdAt));"#
        ))
        #expect(code.contains(
            #"print("Governance: observation decision trace inserted append-only; standard_key remains NULL")"#
        ))

        #expect(code.contains("INSERT INTO decision_traces"))
        #expect(code.components(separatedBy: "INSERT INTO").count - 1 == 1)
    }

    // MARK: Refusals

    @Test("Three refusals, each with its own status and reason")
    func refusalsStayDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"guard let assetIDString = req.parameters.get("assetID"),"#))
        #expect(code.contains(#""reason": "invalid asset id""#))
        #expect(code.contains(#"print("Observation Decision Trace decode failed: \(error)")"#))

        // The decision type is an allowlist of exactly one, refused with its own body.
        #expect(code.contains(#"guard payload.decisionType == "handled" else {"#))
        #expect(code.contains(#""reason": "decisionType must be handled""#))

        // Unknown asset is 404, not 400 and not a silent success.
        #expect(code.contains("guard assetRows.count == 1 else {"))
        #expect(code.contains("return Response(status: .notFound)"))
    }

    @Test("The asset must exist, and the type must be accepted, before anything is written")
    func checksPrecedeTheInsert() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        let typeGuard = try #require(code.range(of: #"guard payload.decisionType == "handled" else {"#)?.lowerBound)
        let existence = try #require(code.range(of: "FROM asset_records")?.lowerBound)
        let insert = try #require(code.range(of: "INSERT INTO decision_traces")?.lowerBound)

        #expect(typeGuard < existence, "An unsupported decision type reaches the database before it is refused")
        #expect(existence < insert, "A decision can be attached to an observation that does not exist")

        #expect(code.contains("SELECT id"))
        #expect(code.contains(#"WHERE id = \(bind: assetID)"#))
        #expect(code.contains("LIMIT 1"))
    }

    // MARK: Server-decided fields and response

    @Test("Source tag and timestamp are decided here, and the response echoes the row")
    func serverDecidedFieldsAndResponse() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("let decisionTraceID = UUID()"))
        #expect(code.contains("let createdAt = ISO8601DateFormatter().string(from: Date())"))
        #expect(code.contains(#"let sourceTag = "[M]""#))

        for callerSupplied in ["payload.sourceTag", "payload.createdAt", "payload.id"] {
            #expect(code.contains(callerSupplied) == false,
                    "\(callerSupplied) is taken from the request instead of decided here")
        }

        for field in [
            "id: decisionTraceID.uuidString,",
            "targetAssetRecordID: assetID.uuidString,",
            "decisionType: payload.decisionType,",
            "sourceTag: sourceTag,",
            "createdAt: createdAt"
        ] {
            #expect(code.contains(field), "Response field changed or missing: \(field)")
        }
        #expect(code.contains("-> ObservationDecisionTraceResponse") || code.contains("ObservationDecisionTraceResponse("))
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains(#"print("Observation Decision Trace INSERT PASS")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "NULL, NULL, NULL, \\(bind: assetID)",
                                  with: "\\(bind: payload.standardKey), NULL, NULL, \\(bind: assetID)")

        #expect(mutated.contains("NULL, NULL, NULL, \\(bind: assetID)") == false)
        #expect(try routeFileText().contains("NULL, NULL, NULL, \\(bind: assetID)"))
    }
}
