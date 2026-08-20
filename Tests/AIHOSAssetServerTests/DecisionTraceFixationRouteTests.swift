import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G5: the decision trace fixation route
//
// Order WFOS-20260820-PSKS-017. `POST /api/v1/decisions` moved from main() into
// Sources/AIHOSAssetServer/DecisionTraceFixationRoutes.swift.
//
// WHY THESE TESTS
//   This route is what stops a gap from being reported: the gap and pulse calculations
//   suppress a gap when a leave-empty decision exists for that standard and window.
//   That makes three of its properties governance rather than style, and each would
//   compile if broken:
//
//   - The decision type is an allowlist of exactly one. Accepting whatever arrives
//     would let the gap calculations be silenced by a value nobody defined.
//   - The source tag, the lane key and createdAt are decided server-side. A
//     caller-supplied source tag would let a machine decision claim to be a human one.
//   - The window bounds are stored verbatim, because the calculations match on them
//     literally. Normalising them here would stop the suppression from matching.

private let routeFileName = "DecisionTraceFixationRoutes.swift"

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

@Suite("F-G5 decision trace fixation route extraction")
struct DecisionTraceFixationRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.post("decisions")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the decisions route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerDecisionTraceFixationRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The asset-scoped decision trace routes are a different resource and stayed apart")
    func assetScopedTracesAreSeparate() throws {
        // /api/v1/assets/:id/decision-traces writes a trace bound to an observation.
        // This route writes one bound to a standard and window. Similar names, different
        // resources — pinned so neither absorbs the other.
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"apiV1.post("assets", ":assetID", "decision-traces")"#) == false)
        #expect(code.contains(":assetID") == false, "An asset-scoped route appeared in \(routeFileName)")
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group and nothing else, including no time zone")
    func registrarTakesNothingElse() throws {
        // Worth stating explicitly: unlike the gap and pulse routes this one needs no
        // operations time zone. The window bounds arrive in the request and createdAt is
        // a UTC instant, so there is no local day to resolve.
        #expect(try routeFileText().contains(
            "func registerDecisionTraceFixationRoutes(on apiV1: MachineGatedRoutes) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "STORAGE_PATH", "storageDirectory",
                       "OPERATIONS_TIMEZONE", "operationsTimeZone", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }
        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: The allowlist of one

    @Test("Only leave_empty is accepted, and anything else is refused rather than stored")
    func decisionTypeIsAnAllowlistOfOne() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"guard payload.decisionType == "leave_empty" else {"#))
        #expect(code.contains(#"print("Decision rejected: unsupported decisionType \(payload.decisionType)")"#))

        // The refusal must come before the insert, or an unrecognised decision would
        // already be in the record by the time it is rejected.
        let guardIndex = try #require(code.range(of: #"guard payload.decisionType == "leave_empty" else {"#)?.lowerBound)
        let insertIndex = try #require(code.range(of: "INSERT INTO decision_traces")?.lowerBound)
        #expect(guardIndex < insertIndex,
                "An unsupported decision type reaches the insert before it is refused")

        // Two distinct 400s: an undecodable body and an unsupported type.
        #expect(code.contains(#"print("Decision payload decode failed: \(error)")"#))
        #expect(code.components(separatedBy: "return Response(status: .badRequest)").count - 1 == 2)
    }

    // MARK: What the server decides, not the caller

    @Test("Source tag, lane key and timestamp are all server-decided")
    func serverDecidedFieldsArePinned() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"let sourceTag = "[M]""#))
        #expect(code.contains(#"let inheritedLaneKey = "unassigned""#))
        #expect(code.contains("let decisionID = UUID()"))
        #expect(code.contains("let createdAt = ISO8601DateFormatter().string(from: Date())"))

        // None of the four may be read from the request. A caller-supplied source tag
        // would let a machine decision claim to be a human one.
        for callerSupplied in ["payload.sourceTag", "payload.createdAt", "payload.laneKey", "payload.id"] {
            #expect(code.contains(callerSupplied) == false,
                    "\(callerSupplied) is taken from the request instead of decided here")
        }
    }

    @Test("The window bounds are stored exactly as received")
    func windowBoundsAreStoredVerbatim() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // The gap and pulse calculations match on these literally, so any reshaping
        // here would stop the suppression from matching the gap it should suppress.
        #expect(code.contains(#"\(bind: payload.expectedWindowStart)"#))
        #expect(code.contains(#"\(bind: payload.expectedWindowEnd)"#))
        for reshaping in ["expectedWindowStart.", "expectedWindowEnd.", "ISO8601DateFormatter().date(from:"] {
            #expect(code.contains(reshaping) == false,
                    "The window bounds are reshaped before storage: \(reshaping)")
        }

        #expect(code.contains(
            #"(id, "standard_key", "expected_window_start", "expected_window_end", "decision_type", "source_tag", "created_at", lane_key)"#
        ))
        #expect(code.contains("INSERT INTO decision_traces"))
        #expect(code.components(separatedBy: "INSERT INTO").count - 1 == 1)
    }

    @Test("The response echoes every stored field, and the log lines are unchanged")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for field in [
            #""id": decisionID.uuidString,"#,
            #""sourceTag": sourceTag,"#,
            #""decisionType": payload.decisionType,"#,
            #""standardKey": payload.standardKey,"#,
            #""expectedWindowStart": payload.expectedWindowStart,"#,
            #""expectedWindowEnd": payload.expectedWindowEnd,"#,
            #""createdAt": createdAt,"#,
            #""laneKey": inheritedLaneKey"#
        ] {
            #expect(code.contains(field), "Response field changed or missing: \(field)")
        }

        #expect(code.contains("guard let sql = req.db as? SQLDatabase else {"))
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains(#"print("Decision Trace fixation PASS")"#))
        #expect(code.contains(#"print("Decision Trace INSERT failed: \(error)")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"let sourceTag = "[M]""#, with: #"let sourceTag = payload.sourceTag"#)

        #expect(mutated.contains(#"let sourceTag = "[M]""#) == false)
        #expect(try routeFileText().contains(#"let sourceTag = "[M]""#))
    }
}
