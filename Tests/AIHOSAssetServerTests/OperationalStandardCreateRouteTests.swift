import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-G7: the operational standard creation route
//
// Order WFOS-20260820-PSKS-021. `POST /api/v1/standards` moved from main() into
// Sources/AIHOSAssetServer/OperationalStandardCreateRoutes.swift.
//
// WHY THESE TESTS
//   Everything the gap and pulse calculations report is measured against rows this
//   route writes, and standards are append-only — a bad one cannot be corrected in
//   place, only superseded. So the five validations that run before any write are the
//   real subject here, along with the duplicate guard that answers 409 rather than 400,
//   and the fields the server derives instead of accepting.

private let routeFileName = "OperationalStandardCreateRoutes.swift"

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

@Suite("F-G7 operational standard create route extraction")
struct OperationalStandardCreateRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.post("standards")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the standard create route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerOperationalStandardCreateRoutes(on: apiV1)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The status PATCH stayed in the composition root and did not follow")
    func statusPatchDidNotMove() throws {
        let patch = #"apiV1.on(.PATCH, "standards", ":standardID", "status")"#

        #expect(try serverSourceText().contains(patch))
        #expect(try routeFileText().contains(patch) == false,
                "The status route was dragged along with the create extraction")
    }

    // MARK: Dependencies

    @Test("The registrar takes the route group, and the validators are reused")
    func registrarTakesNothingElse() throws {
        #expect(try routeFileText().contains(
            "func registerOperationalStandardCreateRoutes(on apiV1: MachineGatedRoutes) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        // Pure SQL. This is why it was chosen over the 28-lines-shorter vision-ocr route.
        for absent in ["Environment.get", "STORAGE_PATH", "storageDirectory", "operationsTimeZone",
                       "AIHOS_", "Vision", "canImport", "FileManager"] {
            #expect(code.contains(absent) == false, "\(absent) appeared in \(routeFileName)")
        }

        // The lane and track validators and the window parser are module-level helpers,
        // called rather than reimplemented — a local copy would drift from the shared one.
        for helper in [
            "validatedOperationalStandardLaneKey(payload.laneKey)",
            "validatedOperationalStandardTrackType(payload.trackType)",
            "hourFromExpectedWindow(payload.expectedWindowStart)",
            "hourFromExpectedWindow(payload.expectedWindowEnd)"
        ] {
            #expect(code.contains(helper), "Helper call changed or missing: \(helper)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: Validation before any write

    @Test("All five validations run, each with its own reason, before the database is touched")
    func validationsPrecedeTheDatabase() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for reason in [
            #"print("Operational Standard create failed: payload decode error \(error)")"#,
            #"print("Operational Standard create failed: invalid laneKey \(payload.laneKey)")"#,
            #"print("Operational Standard create failed: invalid trackType \(payload.trackType)")"#,
            #"print("Operational Standard create failed: invalid expected window")"#,
            #"print("Operational Standard create failed: requiredCount must be greater than zero")"#
        ] {
            #expect(code.contains(reason), "Validation reason changed or missing: \(reason)")
        }

        // Five refusals, all 400.
        #expect(code.components(separatedBy: "return Response(status: .badRequest)").count - 1 == 5)

        // The window must parse to two hours AND end after start. Dropping the ordering
        // check would allow a window that can never contain anything.
        #expect(code.contains("endHour > startHour else {"))
        #expect(code.contains("guard payload.requiredCount > 0 else {"))

        // Every validation precedes the first query.
        let lastGuard = try #require(code.range(of: "guard payload.requiredCount > 0 else {")?.lowerBound)
        let firstQuery = try #require(code.range(of: "FROM operational_standards")?.lowerBound)
        #expect(lastGuard < firstQuery, "The database is queried before the payload is fully validated")
    }

    // MARK: The duplicate guard

    @Test("A duplicate active standard is a 409 conflict, not a 400")
    func duplicateGuardIsAConflict() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("guard duplicateCount == 0 else {"))
        #expect(code.contains("let response = Response(status: .conflict)"))
        #expect(code.contains(#""reason": "duplicate active operational standard""#))
        #expect(code.contains(#"print("Operational Standard create blocked: duplicate active standard")"#))

        // Five columns together, plus ACTIVE — so a superseded standard does not block
        // re-creation, and a standard differing in any one column is not a duplicate.
        for column in [
            #"WHERE lane_key = \(bind: laneKey)"#,
            #"AND track_type = \(bind: trackType)"#,
            #"AND expected_window_start = \(bind: payload.expectedWindowStart)"#,
            #"AND expected_window_end = \(bind: payload.expectedWindowEnd)"#,
            #"AND "requiredCount" = \(bind: payload.requiredCount)"#,
            "AND status = 'ACTIVE'"
        ] {
            #expect(code.contains(column), "Duplicate guard column changed or missing: \(column)")
        }

        let duplicateCheck = try #require(code.range(of: "guard duplicateCount == 0 else {")?.lowerBound)
        let insert = try #require(code.range(of: "INSERT INTO operational_standards")?.lowerBound)
        #expect(duplicateCheck < insert, "A duplicate is inserted before it is detected")
    }

    // MARK: Derived and server-decided fields

    @Test("Key, description, status, tag, id and timestamp are all decided here")
    func derivedFieldsArePinned() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"let standardKey = "\(laneKey)-\(trackType)-\(payload.expectedWindowStart)-\(payload.expectedWindowEnd)""#))
        #expect(code.contains(#"let description = "Expected \(trackType) information for \(laneKey) between \(payload.expectedWindowStart) and \(payload.expectedWindowEnd)""#))
        #expect(code.contains(#"let status = "ACTIVE""#))
        #expect(code.contains(#"let sourceTag = "[?]""#))
        #expect(code.contains("let standardID = UUID()"))
        #expect(code.contains("let createdAt = ISO8601DateFormatter().string(from: Date())"))

        // The key is derived from the VALIDATED lane and track, not the raw payload, so
        // two callers describing the same expectation produce the same key.
        #expect(code.contains(#"let standardKey = "\(payload.laneKey)"#) == false)

        // None of the six may be read from the request.
        for callerSupplied in ["payload.standardKey", "payload.description", "payload.status",
                               "payload.sourceTag", "payload.createdAt", "payload.id"] {
            #expect(code.contains(callerSupplied) == false,
                    "\(callerSupplied) is taken from the request instead of decided here")
        }
    }

    @Test("The insert is append-only and the response echoes the created row")
    func insertAndResponseAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("INSERT INTO operational_standards"))
        #expect(code.components(separatedBy: "INSERT INTO").count - 1 == 1)
        for mutating in ["UPDATE operational_standards", "DELETE FROM operational_standards"] {
            #expect(code.contains(mutating) == false, "\(mutating) appeared in \(routeFileName)")
        }
        #expect(code.contains(
            #"print("Governance: standard created append-only; no historical standard mutated")"#
        ))

        for field in [
            "id: standardID.uuidString,",
            "standardKey: standardKey,",
            "laneKey: laneKey,",
            "trackType: trackType,",
            "expectedWindowStart: payload.expectedWindowStart,",
            "expectedWindowEnd: payload.expectedWindowEnd,",
            "requiredCount: payload.requiredCount,",
            "status: status,",
            "createdAt: createdAt"
        ] {
            #expect(code.contains(field), "Response field changed or missing: \(field)")
        }
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains(#"print("Operational Standard create PASS")"#))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "Response(status: .conflict)", with: "Response(status: .badRequest)")

        #expect(mutated.contains("Response(status: .conflict)") == false)
        #expect(try routeFileText().contains("Response(status: .conflict)"))
    }
}
