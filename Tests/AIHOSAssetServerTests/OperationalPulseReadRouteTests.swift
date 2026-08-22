import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F9: the operational pulse read route
//
// Order WFOS-20260820-PSKS-007. `GET /api/v1/state/pulse` moved from main() into
// Sources/AIHOSAssetServer/OperationalPulseReadRoutes.swift. With this, every read
// route has left the composition root.
//
// WHY THESE TESTS
//   Pulse and gaps walk the same standards with the same helpers, which makes them look
//   like one routine with a flag. They are not, and the differences are exactly what a
//   later merge would erase:
//
//   - Pulse evaluates today in the operations zone and takes no date parameter, so it
//     has no validation and no 400 path.
//   - It counts instead of listing, and a standard skipped as inactive is excluded from
//     activeStandardsCount — which is what makes blue mean "nothing active" rather than
//     "nothing checked".
//   - Its gap branch logs both outcomes, so an operator can see that a decision trace
//     was the reason a gap is not counted.
//   - The colour rule is ordered: no active standards wins over any gap count.

private let routeFileName = "OperationalPulseReadRoutes.swift"

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

@Suite("F-F9 operational pulse read route extraction")
struct OperationalPulseReadRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("state", "pulse")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the pulse route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerOperationalPulseReadRoutes(on: apiV1, operationsTimeZone: operationsTimeZone, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("No read route is registered in the composition root any more")
    func compositionRootHasNoReadRoutesLeft() throws {
        // The end state of the F-F series. Every remaining registration in main() is a
        // write or a diagnostic; a GET reappearing there means a route was added
        // straight into the composition root instead of a route file.
        let lines = trimmedSourceLines(try serverSourceText())
        let gettersInMain = lines.filter { $0.hasPrefix("apiV1.get(") }

        #expect(gettersInMain.isEmpty, "GET routes still registered in main(): \(gettersInMain)")
    }

    // MARK: Dependencies — threaded, not duplicated

    @Test("Both values are parameters and every other helper is reused")
    func dependenciesAreThreadedNotDuplicated() throws {
        // Atom A added `storageDirectory`. Pulse now asks the same evidence question as
        // gaps, and that question is answered against the filesystem.
        for parameter in [
            "func registerOperationalPulseReadRoutes(",
            "on apiV1: MachineGatedRoutes,",
            "operationsTimeZone: TimeZone,",
            "storageDirectory: String"
        ] {
            #expect(try routeFileText().contains(parameter), "Registrar signature changed: \(parameter)")
        }

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        for lookup in ["Environment.get", "OPERATIONS_TIMEZONE", "resolvedOperationsTimeZone", "STORAGE_PATH", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        for helper in [
            "operationsDateString(for: Date(), in: operationsTimeZone)",
            "iso8601Timestamp(dateString: pulseDate, hour: endHour)",
            "isStandardActive(",
            "standardCreatedAtIsDeclared(createdAt)",
            "standardStatusDecisionCountQuery(standardID: standardID, at: evaluationTimestamp)",
            "observationWindowBounds(",
            "laneScopedObservationEvidenceQuery(bounds: windowBounds, laneKey: laneKey)",
            "observationEvidenceTally(",
            "leaveEmptyDecisionCountQuery(",
            "timestampReadExpectationDiagnosticQuery()",
            "logTimestampReadExpectationDiagnostic("
        ] {
            #expect(code.contains(helper), "Helper call changed or missing: \(helper)")
        }

        #expect(codeLines.contains { $0.hasPrefix("func ") && $0.contains("register") == false } == false,
                "A helper was redefined inside \(routeFileName)")
        for declaration in ["var ", "let ", "struct ", "enum "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
    }

    @Test("Pulse and gaps share the evidence rule rather than each carrying one")
    func pulseSharesTheEvidenceRuleWithGaps() throws {
        // The two calculations answer different questions, but "did this observation
        // actually happen" must not be one of the differences. A second copy of that
        // rule is how the board and the list start disagreeing about the same day.
        let gapsSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "MechanicalGapReadRoutes.swift" }?.text,
            "MechanicalGapReadRoutes.swift is missing from the library"
        )

        for shared in [
            "laneScopedObservationEvidenceQuery(bounds: windowBounds, laneKey: laneKey)",
            "standardCreatedAtIsDeclared(createdAt)",
            "observationEvidenceTally("
        ] {
            #expect(try routeFileText().contains(shared), "Pulse stopped using the shared rule: \(shared)")
            #expect(gapsSource.contains(shared), "Gaps stopped using the shared rule: \(shared)")
        }
    }

    // MARK: What separates pulse from gaps

    @Test("Pulse takes no date parameter and therefore has no 400 path")
    func pulseAlwaysEvaluatesToday() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("let pulseDate = operationsDateString(for: Date(), in: operationsTimeZone)"))

        // Gaps accepts ?date= and validates it. Pulse deliberately does neither: it
        // reports the current operations day and nothing else.
        #expect(code.contains(#"req.query[String.self, at: "date"]"#) == false,
                "Pulse gained a date parameter, which is the gaps contract, not this one")
        #expect(code.contains("isValidISO8601DateString") == false)
        #expect(code.contains(".badRequest") == false, "Pulse gained a 400 path it has no input for")
    }

    @Test("Decided-inactive standards are excluded from the active count before it is used")
    func inactiveStandardsAreNotCounted() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("guard activationResolved, standardWasActive else {"))
        #expect(code.contains(
            #"print("Historical status resolution: standard inactive at pulse evaluation time — skipping \(standardKey)")"#
        ))

        // The unconditional increment must come after the guard. Counting every standard
        // first would make blue unreachable and turn "nothing active" into "nothing
        // checked". The unresolved branch inside the guard increments too, and that is
        // the subject of its own test below.
        let guardIndex = try #require(code.range(of: "guard activationResolved, standardWasActive else {")?.lowerBound)
        let unconditionalIndex = try #require(code.range(of: "\n            activeStandardsCount += 1\n")?.lowerBound)
        #expect(guardIndex < unconditionalIndex,
                "activeStandardsCount is incremented before the inactive standards are skipped")

        // Same fail-closed window rule as gaps, with its own calculation label.
        #expect(code.contains("guard let windowBounds = observationWindowBounds("))
        #expect(code.contains(#""Unresolvable observation window, standard skipped""#))
        #expect(code.contains(#""calculation": .string("state/pulse")"#))
        #expect(code.components(separatedBy: "continue").count - 1 == 2)
    }

    @Test("An unresolved activation counts as active AND as a gap, so it cannot wash to blue")
    func unresolvedActivationCannotProduceBlue() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A-AC9. A legacy-sentinel standard used to fall through the inactive skip and
        // leave both counters untouched, which is what let the board report "nothing
        // active" while every one of those standards was unexamined.
        #expect(code.contains("if !governanceFieldsDeclared {"))
        #expect(code.contains("activationResolved = statusDecisionCount > 0"))

        let announcement = "Standard activation unresolved at pulse evaluation time"
        let printIndex = try #require(code.range(of: announcement)?.lowerBound)
        let branch = String(code[..<printIndex].suffix(240))

        #expect(branch.contains("activeStandardsCount += 1"),
                "The unresolved branch does not count the standard as active")
        #expect(branch.contains("informationGapsCount += 1"),
                "The unresolved branch does not count the standard as a gap")
    }

    @Test("An unresolvable window counts as a gap rather than contributing to green")
    func unresolvableWindowCannotProduceGreen() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Before Atom A this branch touched neither counter, so a configuration fault
        // was indistinguishable from a standard that had been met.
        let warningIndex = try #require(code.range(of: "Unresolvable observation window, standard skipped")?.upperBound)
        let tail = String(code[warningIndex...])
        let gapIndex = try #require(tail.range(of: "informationGapsCount += 1")?.lowerBound)
        let continueIndex = try #require(tail.range(of: "continue")?.lowerBound)

        #expect(gapIndex < continueIndex, "The unresolvable-window branch leaves without counting a gap")
    }

    @Test("Pulse declares that it matched no track, on every call")
    func trackLimitationIsDeclared() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A-AC9: pulse may never be read as evidence about a particular lane or track.
        #expect(code.contains(#"print("trackEvaluable: false")"#))
        #expect(code.contains("track_type") == false,
                "Pulse reads track_type, which it cannot yet match against anything")
    }

    @Test("Pulse counts each standard against its own lane")
    func pulseCountsWithinTheStandardsLane() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A-AC4: no other lane may close this standard's expectation.
        #expect(code.contains(#"let laneKey = try standard.decode(column: "lane_key", as: String.self)"#))
        #expect(code.contains("laneScopedObservationEvidenceQuery(bounds: windowBounds, laneKey: laneKey)"))

        // Pulse takes no lane parameter of its own: it reports the whole day.
        #expect(code.contains(#"req.query[String.self, at: "laneKey"]"#) == false,
                "Pulse gained a lane parameter, which is the gaps contract, not this one")
    }

    @Test("Both gap outcomes are logged, not just the counted one")
    func bothGapOutcomesAreReported() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("if evidence.observedCount < requiredCount {"))
        #expect(code.contains("if decisionCount == 0 {"))
        #expect(code.contains("informationGapsCount += 1"))
        #expect(code.contains(#"print("Open gap without Decision Trace: \(standardKey)")"#))

        // The else branch is the point: a gap covered by a decision trace is reported as
        // historically intact rather than passed over in silence.
        #expect(code.contains(#"print("Gap has Decision Trace and remains historically intact: \(standardKey)")"#))
    }

    // MARK: The colour rule

    @Test("The three pulse states keep their exact values and their branch order")
    func pulseStateRuleIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        let blue = try #require(code.range(of: #"pulseState = "blue""#)?.lowerBound)
        let yellow = try #require(code.range(of: #"pulseState = "yellow""#)?.lowerBound)
        let green = try #require(code.range(of: #"pulseState = "green""#)?.lowerBound)

        #expect(code.contains("if activeStandardsCount == 0 {"))
        #expect(code.contains("} else if informationGapsCount > 0 {"))

        // Ordered, not independent: no active standards wins over any gap count, and
        // green is only what is left when neither earlier branch applied. Reordering
        // these compiles and changes what the board shows.
        #expect(blue < yellow)
        #expect(yellow < green)
    }

    @Test("The response carries exactly the two pinned fields")
    func responseContractIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("guard let sql = req.db as? SQLDatabase else {"))
        #expect(code.contains("return Response(status: .internalServerError)"))
        #expect(code.contains("let response = Response(status: .ok)"))
        #expect(code.contains(#""pulseState": pulseState,"#))
        #expect(code.contains(#""sourceTag": "[S]""#))

        for logged in [
            #"print("Mechanical pulse generation PASS")"#,
            #"print("activeStandardsCount: \(activeStandardsCount)")"#,
            #"print("informationGapsCount: \(informationGapsCount)")"#,
            #"print("pulseState: \(pulseState)")"#,
            #"print("sourceTag: [S]")"#
        ] {
            #expect(code.contains(logged), "Log line changed or missing: \(logged)")
        }

        for mutating in ["INSERT", "UPDATE ", "DELETE", "DROP", "ALTER", "TRUNCATE"] {
            #expect(code.uppercased().contains(mutating) == false,
                    "\(mutating) appeared in \(routeFileName)")
        }
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"pulseState = "blue""#, with: #"pulseState = "green""#)

        #expect(mutated.contains(#"pulseState = "blue""#) == false)
        #expect(try routeFileText().contains(#"pulseState = "blue""#))
    }
}
