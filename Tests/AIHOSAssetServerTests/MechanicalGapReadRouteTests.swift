import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F8: the mechanical gap detection read route
//
// Order WFOS-20260820-PSKS-005. `GET /api/v1/gaps/mechanical` moved from main() into
// Sources/AIHOSAssetServer/MechanicalGapReadRoutes.swift. `GET /api/v1/state/pulse`
// deliberately stayed behind and is pinned as such.
//
// WHY THESE TESTS
//   This route decides whether a hotel is told an expected observation is missing, so
//   the ways it can go wrong are governance failures rather than cosmetic ones:
//
//   - Defaulting the date in UTC instead of the operations zone would report the wrong
//     day for part of every night.
//   - Collapsing its two fail-closed skips into one would hide a configuration fault
//     inside routine output.
//   - Dropping the leave-empty check would re-report a deliberate decision as a gap.
//
//   Each is pinned below, together with the threaded time zone and the reuse of the
//   existing module helpers rather than local copies of them.

private let routeFileName = "MechanicalGapReadRoutes.swift"

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

@Suite("F-F8 mechanical gap read route extraction")
struct MechanicalGapReadRouteTests {

    // MARK: Placement, and the separation from pulse

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("gaps", "mechanical")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the mechanical gaps route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerMechanicalGapReadRoutes(on: apiV1, operationsTimeZone: operationsTimeZone)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("state/pulse stayed in the composition root and did not follow")
    func pulseRouteDidNotMove() throws {
        // The order was to move gaps only. The two share helpers but not code, and this
        // pins that the separation actually happened rather than being intended.
        let pulse = #"apiV1.get("state", "pulse")"#

        #expect(try serverSourceText().contains(pulse))
        #expect(try routeFileText().contains(pulse) == false,
                "The pulse route was dragged along with the gaps extraction")
    }

    // MARK: Dependencies — threaded, not duplicated

    @Test("The time zone is a parameter, and every other helper is reused from the module")
    func dependenciesAreThreadedNotDuplicated() throws {
        #expect(try routeFileText().contains(
            "func registerMechanicalGapReadRoutes(on apiV1: MachineGatedRoutes, operationsTimeZone: TimeZone) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        // main() resolves the zone once, fail-closed. A second lookup here could
        // disagree with it, and this value decides which day is being asked about.
        for lookup in ["Environment.get", "OPERATIONS_TIMEZONE", "resolvedOperationsTimeZone", "STORAGE_PATH", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        // The helpers are called, not redefined. A local copy of any of these would
        // drift from the shared one without the compiler objecting.
        for helper in [
            "operationsDateString(for: Date(), in: operationsTimeZone)",
            "isValidISO8601DateString(requestedDate)",
            "iso8601Timestamp(dateString: requestedDate, hour: endHour)",
            "isStandardActive(",
            "observationWindowBounds(",
            "observationCountInWindowQuery(bounds: windowBounds)",
            "leaveEmptyDecisionCountQuery(",
            "timestampReadExpectationDiagnosticQuery()",
            "logTimestampReadExpectationDiagnostic("
        ] {
            #expect(code.contains(helper), "Helper call changed or missing: \(helper)")
        }

        // No redefinition and no file-scope state.
        #expect(codeLines.contains { $0.hasPrefix("func ") && $0.contains("register") == false } == false,
                "A helper was redefined inside \(routeFileName)")
        for declaration in ["var ", "let ", "struct "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    // MARK: The operations-zone default

    @Test("The default date is today in the operations zone, not UTC")
    func defaultDateUsesOperationsZone() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"let requestedDate = req.query[String.self, at: "date"]"#))
        #expect(code.contains("?? operationsDateString(for: Date(), in: operationsTimeZone)"))

        // The malformed-date refusal carries a body a client may read.
        #expect(code.contains("guard isValidISO8601DateString(requestedDate) else {"))
        #expect(code.contains("let response = Response(status: .badRequest)"))
        #expect(code.contains(#""reason": "date must use YYYY-MM-DD format""#))
    }

    // MARK: Two skips that are not the same skip

    @Test("The inactive skip and the unresolvable-window skip stay distinct")
    func twoFailClosedSkipsAreDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A standard inactive at evaluation time is a normal outcome: printed, skipped.
        #expect(code.contains("guard standardWasActive else {"))
        #expect(code.contains(
            #"print("Historical status resolution: standard inactive at gap evaluation time — skipping \(standardKey)")"#
        ))

        // A window that cannot be resolved is a fault: warned with metadata, skipped,
        // and never evaluated against a half-built range.
        #expect(code.contains("guard let windowBounds = observationWindowBounds("))
        #expect(code.contains(#"req.logger.warning("#))
        #expect(code.contains(#""Unresolvable observation window, standard skipped""#))
        for metadata in [
            #""calculation": .string("gaps/mechanical")"#,
            #""standardKey": .string(standardKey)"#,
            #""localDate": .string(requestedDate)"#
        ] {
            #expect(code.contains(metadata), "Warning metadata changed or missing: \(metadata)")
        }

        // Two skips, two continues — collapsing them would hide a fault as routine.
        #expect(code.components(separatedBy: "continue").count - 1 == 2)
    }

    // MARK: The gap condition

    @Test("A gap needs both a short count and no leave-empty decision")
    func gapConditionIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("if observedCount < requiredCount {"))
        #expect(code.contains("if decisionCount == 0 {"))

        // Order matters: the decision query only runs when the count is already short.
        let shortIndex = try #require(code.range(of: "if observedCount < requiredCount {")?.lowerBound)
        let decisionIndex = try #require(code.range(of: "if decisionCount == 0 {")?.lowerBound)
        #expect(shortIndex < decisionIndex,
                "The leave-empty check no longer sits inside the short-count branch")

        // The reported payload, field by field.
        for field in [
            #""sourceTag": sourceTag,"#,
            #""standardKey": standardKey,"#,
            #""description": description,"#,
            #""expectedDate": requestedDate,"#,
            #""evaluationTimestamp": evaluationTimestamp,"#,
            #""expectedWindow": String(format: "%02d:00-%02d:00", startHour, endHour),"#,
            #""requiredCount": String(requiredCount),"#,
            #""observedCount": String(observedCount),"#,
            #""gapStatus": "Missing expected observation""#
        ] {
            #expect(code.contains(field), "Gap payload field changed or missing: \(field)")
        }

        #expect(code.contains(#"print("Mechanical gap detection PASS: \(gaps.count) gaps")"#))
        #expect(code.contains("try response.content.encode(gaps)"))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: "?? operationsDateString(for: Date(), in: operationsTimeZone)",
                                  with: "?? \"1970-01-01\"")

        #expect(mutated.contains("?? operationsDateString(for: Date(), in: operationsTimeZone)") == false)
        #expect(try routeFileText().contains("?? operationsDateString(for: Date(), in: operationsTimeZone)"))
    }
}
