import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F8 + Atom A: the mechanical gap detection read route
//
// Orders WFOS-20260820-PSKS-005 (extraction) and WFOS-20260822-PSKS-004 (Atom A,
// prompt version A-v4). `GET /api/v1/gaps/mechanical` lives in
// Sources/AIHOSAssetServer/MechanicalGapReadRoutes.swift; `GET /api/v1/state/pulse`
// lives in its own file and is pinned as such.
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
//   - Answering an unknown lane with an empty array would read as "nothing is missing
//     there", which is the most dangerous possible answer to a typo.
//   - Reporting `Missing expected observation` while something about the standard is
//     still unresolved would accuse a hotel of a failure the server cannot establish.
//
// WHAT IS PINNED AS SOURCE AND WHAT IS EXERCISED FOR REAL
//   The route handler needs a database to run, and this package has no database test
//   harness, so registration, dependencies and query shape are pinned as source. The
//   decision itself is not: Atom A deliberately put the decision table, the evidence
//   classification and the entry builder in ObservationWindowHelpers.swift as pure
//   functions, and those are called directly below against real files on disk. What
//   decides what a hotel is told is therefore tested, not merely pinned.

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

/// The complete response contract of one entry: fourteen keys, never conditional.
///
/// The first nine are the pre-Atom-A shape, unchanged in name and in type. The last
/// five were added by A-AC2. A client reads one shape whatever the answer.
private let expectedEntryKeys: Set<String> = [
    "sourceTag",
    "standardKey",
    "description",
    "expectedDate",
    "evaluationTimestamp",
    "expectedWindow",
    "requiredCount",
    "observedCount",
    "gapStatus",
    "laneKey",
    "unverifiableCount",
    "unclassifiedCount",
    "trackEvaluable",
    "unknownReason"
]

/// A context whose values are distinguishable, so a builder that crossed two fields
/// would be caught rather than pass on matching placeholders.
private func sampleContext(
    laneKey: String = "kitchen",
    requiredCount: Int = 2,
    trackEvaluable: Bool = false
) -> MechanicalGapStandardContext {
    MechanicalGapStandardContext(
        sourceTag: "[?]",
        standardKey: "kitchen-photo-22:00-23:00",
        description: "Expected photo information for kitchen between 22:00 and 23:00",
        laneKey: laneKey,
        expectedDate: "2026-08-22",
        evaluationTimestamp: "2026-08-22T23:00:00Z",
        expectedWindow: "22:00-23:00",
        requiredCount: requiredCount,
        trackEvaluable: trackEvaluable
    )
}

private func facts(
    activationResolved: Bool = true,
    standardActive: Bool = true,
    windowResolved: Bool = true,
    trackTypeDeclared: Bool = true,
    requiredCount: Int = 1,
    observed: Int = 0,
    unverifiable: Int = 0,
    unclassified: Int = 0,
    leaveEmptyDecisionRecorded: Bool = false
) -> MechanicalGapFacts {
    MechanicalGapFacts(
        activationResolved: activationResolved,
        standardActive: standardActive,
        windowResolved: windowResolved,
        trackTypeDeclared: trackTypeDeclared,
        requiredCount: requiredCount,
        evidence: ObservationEvidenceTally(
            observedCount: observed,
            unverifiableCount: unverifiable,
            unclassifiedCount: unclassified
        ),
        leaveEmptyDecisionRecorded: leaveEmptyDecisionRecorded
    )
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
        let call = "registerMechanicalGapReadRoutes(on: apiV1, operationsTimeZone: operationsTimeZone, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("state/pulse lives in its own file, not in this one")
    func pulseRouteIsSeparate() throws {
        // F-F8 moved gaps only and left pulse in the composition root; F-F9 then moved
        // pulse into a file of its own. What this test has always guarded is the same
        // thing either way: the two share helpers but not code, and neither extraction
        // may quietly absorb the other.
        let pulse = #"apiV1.get("state", "pulse")"#

        #expect(try routeFileText().contains(pulse) == false,
                "The pulse route was absorbed into \(routeFileName)")

        let pulseSource = try #require(
            try serverModuleSourceTexts().first { $0.name == "OperationalPulseReadRoutes.swift" }?.text,
            "OperationalPulseReadRoutes.swift is missing from the library"
        )
        #expect(pulseSource.contains(pulse))
    }

    // MARK: Dependencies — threaded, not duplicated

    @Test("Both values are parameters, and every other helper is reused from the module")
    func dependenciesAreThreadedNotDuplicated() throws {
        // Atom A added `storageDirectory`: deciding whether a record's evidence can be
        // read is a filesystem question, and there is no column that answers it.
        for parameter in [
            "func registerMechanicalGapReadRoutes(",
            "on apiV1: MachineGatedRoutes,",
            "operationsTimeZone: TimeZone,",
            "storageDirectory: String"
        ] {
            #expect(try routeFileText().contains(parameter), "Registrar signature changed: \(parameter)")
        }

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        // main() resolves both values once, fail-closed. A second lookup here could
        // disagree with it, and these values decide which day is being asked about and
        // whether the evidence behind a record counts.
        for lookup in ["Environment.get", "OPERATIONS_TIMEZONE", "resolvedOperationsTimeZone", "STORAGE_PATH", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        // The helpers are called, not redefined. A local copy of any of these would
        // drift from the shared one without the compiler objecting.
        for helper in [
            "operationsDateString(for: Date(), in: operationsTimeZone)",
            "isValidISO8601DateString(requestedDate)",
            "validatedOperationalStandardLaneKey(rawLaneKey)",
            "iso8601Timestamp(dateString: requestedDate, hour: endHour)",
            "isStandardActive(",
            "standardCreatedAtIsDeclared(createdAt)",
            "standardStatusDecisionCountQuery(standardID: standardID, at: evaluationTimestamp)",
            "observationWindowBounds(",
            "laneScopedObservationEvidenceQuery(bounds: windowBounds, laneKey: laneKey)",
            "observationEvidenceTally(",
            "leaveEmptyDecisionCountQuery(",
            "mechanicalGapOutcome(MechanicalGapFacts(",
            "mechanicalGapEntry(",
            "timestampReadExpectationDiagnosticQuery()",
            "logTimestampReadExpectationDiagnostic("
        ] {
            #expect(code.contains(helper), "Helper call changed or missing: \(helper)")
        }

        // No redefinition and no file-scope state. A-AC8: the decision table and the new
        // predicates belong in ObservationWindowHelpers.swift, not here.
        #expect(codeLines.contains { $0.hasPrefix("func ") && $0.contains("register") == false } == false,
                "A helper was redefined inside \(routeFileName)")
        for declaration in ["var ", "let ", "struct ", "enum "] {
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

    // MARK: The lane filter (A-AC3)

    @Test("An unknown lane is refused with 400, never answered with an empty array")
    func unknownLaneIsRefused() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"if let rawLaneKey = req.query[String.self, at: "laneKey"] {"#))
        #expect(code.contains("guard let validatedLaneKey = validatedOperationalStandardLaneKey(rawLaneKey) else {"))
        #expect(code.contains(#""reason": "laneKey must be a known operational standard lane""#))

        // Two refusals, both 400, both before any standard is read.
        #expect(code.components(separatedBy: "Response(status: .badRequest)").count - 1 == 2)

        let laneRefusalIndex = try #require(code.range(of: "guard let validatedLaneKey")?.lowerBound)
        let standardsQueryIndex = try #require(code.range(of: "FROM operational_standards")?.lowerBound)
        #expect(laneRefusalIndex < standardsQueryIndex,
                "The lane is validated after the standards are read")
    }

    @Test("The lane allowlist is the standards one, and it is reused rather than restated")
    func laneAllowlistIsTheStandardsAllowlist() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // The two lane allowlists are deliberately different sets: asset lanes include
        // finance and economy, standard lanes include maintenance. This route filters
        // standards, so it must use the standards one — and must not carry its own copy.
        #expect(code.contains("validatedOperationalStandardLaneKey(rawLaneKey)"))
        #expect(code.contains("validatedLaneKey(") == false,
                "The asset lane validator would silently widen the accepted set")
        for lane in allowedOperationalStandardLaneKeys.union(allowedLaneKeys) {
            #expect(code.contains("\"\(lane)\"") == false, "Lane literal `\(lane)` hardcoded in \(routeFileName)")
        }
    }

    @Test("An omitted lane means every standard, expressed as a bound value")
    func omittedLaneSelectsEverything() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("requestedLaneKey = nil"))
        #expect(code.contains(#"WHERE lane_key = COALESCE(\(bind: requestedLaneKey), lane_key)"#))

        // SÄKERHET: the lane reaches SQL as a bind, never as interpolated text — and it
        // is validated before it gets there. Both defences, not one.
        #expect(code.contains(#"\(raw:"#) == false, "Raw SQL interpolation in \(routeFileName)")
    }

    @Test("The standards read carries the lane and the creation timestamp it now needs")
    func standardsQuerySelectsLaneAndCreatedAt() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for column in ["lane_key,", "created_at"] {
            #expect(code.contains(column), "Column missing from the standards read: \(column)")
        }
        #expect(code.contains(#"ORDER BY "standardKey" ASC"#), "The pinned ordering contract changed")
    }

    // MARK: Two skips that are not the same skip

    @Test("The inactive skip and the unresolvable-window skip stay distinct")
    func twoFailClosedSkipsAreDistinct() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A standard that cannot be evaluated against a window is skipped — but since
        // Atom A it leaves an entry behind first, so a client can tell a standard that
        // was checked and met from one that was never checked at all.
        #expect(code.contains("guard activationResolved, standardWasActive else {"))
        #expect(code.contains(
            #"print("Standard not evaluated against a window at gap evaluation time: \(standardKey)")"#
        ))

        // A window that cannot be resolved is a fault: warned with metadata, recorded,
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

        // A-AC1: both skips emit an entry before continuing. Three appends in total,
        // one per path out of the loop body.
        #expect(code.components(separatedBy: "entries.append(mechanicalGapEntry(").count - 1 == 3)
    }

    // MARK: The gap condition

    @Test("A gap needs both a short count and no leave-empty decision")
    func gapConditionIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("if evidence.observedCount < requiredCount {"))
        #expect(code.contains("leaveEmptyDecisionRecorded = decisionCount > 0"))

        // Order matters: the decision query only runs when the count is already short.
        let shortIndex = try #require(code.range(of: "if evidence.observedCount < requiredCount {")?.lowerBound)
        let decisionIndex = try #require(code.range(of: "leaveEmptyDecisionCountQuery(")?.lowerBound)
        #expect(shortIndex < decisionIndex,
                "The leave-empty check no longer sits inside the short-count branch")

        #expect(code.contains(#"print("Mechanical gap detection PASS: \(entries.count) standards evaluated")"#))
        #expect(code.contains("try response.content.encode(entries)"))
    }

    @Test("The reported window keeps its exact historical format")
    func expectedWindowFormatIsUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // BEVARANDEKRAV: existing field values keep their shape. This one is a format
        // string a client parses, so it is pinned character for character.
        #expect(code.contains(#"expectedWindow: String(format: "%02d:00-%02d:00", startHour, endHour),"#))
    }

    @Test("Track matching is declared as not performed, never inferred")
    func trackIsDeclaredUnevaluated() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // A-AC4: no relation records the form of an asset record, so the route must not
        // present a track match it did not make.
        #expect(code.contains("trackEvaluable: false"))
        #expect(code.contains("track_type") == false,
                "The route reads track_type, which it cannot yet match against anything")
    }

    // MARK: The decision table — exercised, not pinned

    @Test("Every status in the closed vocabulary is reachable, and each has its own facts")
    func everyStatusIsReachable() {
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 2)).status == .fulfilled)
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 0, leaveEmptyDecisionRecorded: true)).status == .decisionRecorded)
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 0)).status == .missing)
        #expect(mechanicalGapOutcome(facts(activationResolved: false)).status == .unknown)
        #expect(mechanicalGapOutcome(facts(standardActive: false)).status == .notActive)
    }

    @Test("The five unknown reasons are reachable and none is dead")
    func everyUnknownReasonIsReachable() {
        let reasons = [
            mechanicalGapOutcome(facts(activationResolved: false)).reason,
            mechanicalGapOutcome(facts(windowResolved: false)).reason,
            mechanicalGapOutcome(facts(trackTypeDeclared: false)).reason,
            mechanicalGapOutcome(facts(unclassified: 1)).reason,
            mechanicalGapOutcome(facts(unverifiable: 1)).reason
        ]

        #expect(reasons == [
            .standardActivationUnresolved,
            .observationWindowUnresolvable,
            .standardTrackTypeNotDeclared,
            .trackFormNotRegistered,
            .evidenceUnverifiable
        ])

        // A-AC6: the vocabulary is closed. Every value it declares is produced by some
        // reachable combination of facts — a reason no fact can produce is a promise the
        // server cannot keep.
        #expect(Set(reasons).count == 5)
    }

    @Test("The reason priority is activation, window, standard track, unclassified, unverifiable")
    func reasonPriorityIsOrdered() {
        // Each case below has EVERY later reason present too. The winner proves the
        // order rather than merely being consistent with it.
        let everything = facts(
            activationResolved: false,
            windowResolved: false,
            trackTypeDeclared: false,
            unverifiable: 1,
            unclassified: 1
        )
        #expect(mechanicalGapOutcome(everything).reason == .standardActivationUnresolved)

        #expect(mechanicalGapOutcome(facts(
            windowResolved: false, trackTypeDeclared: false, unverifiable: 1, unclassified: 1
        )).reason == .observationWindowUnresolvable)

        #expect(mechanicalGapOutcome(facts(
            trackTypeDeclared: false, unverifiable: 1, unclassified: 1
        )).reason == .standardTrackTypeNotDeclared)

        #expect(mechanicalGapOutcome(facts(unverifiable: 1, unclassified: 1)).reason == .trackFormNotRegistered)
        #expect(mechanicalGapOutcome(facts(unverifiable: 1)).reason == .evidenceUnverifiable)
    }

    @Test("An unresolved standard is never reported as Missing, even when the count is short")
    func unknownNeverBecomesAnAccusation() {
        // `Missing expected observation` says a hotel failed to do something. It is only
        // said when nothing about the standard is still unresolved.
        for unresolved in [
            facts(activationResolved: false, requiredCount: 5, observed: 0),
            facts(windowResolved: false, requiredCount: 5, observed: 0),
            facts(trackTypeDeclared: false, requiredCount: 5, observed: 0),
            facts(requiredCount: 5, observed: 0, unclassified: 1),
            facts(requiredCount: 5, observed: 0, unverifiable: 1)
        ] {
            #expect(mechanicalGapOutcome(unresolved).status != .missing)
        }
    }

    @Test("Unverified evidence never produces Fulfilled, even when the count reaches the requirement")
    func unverifiedEvidenceNeverCloses() {
        // A-AC5: a record whose file cannot be read is not evidence that the observation
        // happened. Before Atom A it counted as one.
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 1, unverifiable: 1)).status == .unknown)
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 1, unclassified: 1)).status == .unknown)
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 1)).status == .fulfilled)
    }

    @Test("A leave-empty decision closes a short count but never overrides a fulfilled one")
    func decisionRecordedOnlyAppliesToAShortCount() {
        #expect(mechanicalGapOutcome(facts(requiredCount: 1, observed: 1, leaveEmptyDecisionRecorded: true)).status == .fulfilled)
        #expect(mechanicalGapOutcome(facts(requiredCount: 2, observed: 1, leaveEmptyDecisionRecorded: true)).status == .decisionRecorded)
    }

    @Test("Missing expected observation keeps its exact historical wording")
    func missingWordingIsUnchanged() {
        // Clients match on this string. Rewording it would be an API change wearing the
        // costume of a tidy-up.
        #expect(MechanicalGapStatus.missing.rawValue == "Missing expected observation")
        #expect(MechanicalGapStatus.fulfilled.rawValue == "Fulfilled")
        #expect(MechanicalGapStatus.decisionRecorded.rawValue == "Decision recorded")
        #expect(MechanicalGapStatus.unknown.rawValue == "Unknown")
        #expect(MechanicalGapStatus.notActive.rawValue == "Not active")
    }

    @Test("There is no server-side Unavailable status")
    func noServerSideUnavailable() throws {
        // A-AC1 / GS-19: a transport failure is not a statement about a hotel's day, and
        // classifying one as though it were is the client's job. The status vocabulary
        // is closed, so the check is that no member of it says Unavailable and that
        // neither calculation can emit the word.
        let statuses: [MechanicalGapStatus] = [.fulfilled, .decisionRecorded, .missing, .unknown, .notActive]
        #expect(statuses.contains { $0.rawValue.localizedCaseInsensitiveContains("unavailable") } == false)

        // Code lines only: the comment in ObservationWindowHelpers.swift that explains
        // why there is no such status must not be what satisfies or trips this.
        for file in ["MechanicalGapReadRoutes.swift", "OperationalPulseReadRoutes.swift", "ObservationWindowHelpers.swift"] {
            let source = try #require(
                try serverModuleSourceTexts().first { $0.name == file }?.text,
                "\(file) is missing from the library"
            )
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            #expect(code.localizedCaseInsensitiveContains("unavailable") == false,
                    "A server-side unavailable classification appeared in \(file)")
        }
    }

    // MARK: The entry shape (A-AC2)

    @Test("Every entry carries all fourteen keys, whatever the outcome")
    func everyEntryCarriesEveryKey() {
        let outcomes = [
            mechanicalGapOutcome(facts(activationResolved: false)),
            mechanicalGapOutcome(facts(standardActive: false)),
            mechanicalGapOutcome(facts(windowResolved: false)),
            mechanicalGapOutcome(facts(requiredCount: 1, observed: 0)),
            mechanicalGapOutcome(facts(requiredCount: 1, observed: 1))
        ]

        for outcome in outcomes {
            let entry = mechanicalGapEntry(
                context: sampleContext(),
                evidence: .empty,
                outcome: outcome
            )

            #expect(Set(entry.keys) == expectedEntryKeys,
                    "Key set changed for \(outcome.status.rawValue): \(Set(entry.keys).symmetricDifference(expectedEntryKeys))")
        }
    }

    @Test("An absent reason is the empty string, never a missing key")
    func absentReasonIsAnEmptyString() {
        let fulfilled = mechanicalGapEntry(
            context: sampleContext(),
            evidence: ObservationEvidenceTally(observedCount: 2, unverifiableCount: 0, unclassifiedCount: 0),
            outcome: mechanicalGapOutcome(facts(requiredCount: 1, observed: 2))
        )

        // A client that has to branch on key presence will eventually branch wrong.
        #expect(fulfilled["unknownReason"] == "")
        #expect(fulfilled.keys.contains("unknownReason"))
        #expect(fulfilled["gapStatus"] == "Fulfilled")
    }

    @Test("The counts stay strings, including the two that already existed")
    func countsAreStrings() {
        let entry = mechanicalGapEntry(
            context: sampleContext(requiredCount: 3),
            evidence: ObservationEvidenceTally(observedCount: 1, unverifiableCount: 4, unclassifiedCount: 5),
            outcome: mechanicalGapOutcome(facts(requiredCount: 3, observed: 1, unverifiable: 4, unclassified: 5))
        )

        // GS-12/17 and BEVARANDEKRAV: requiredCount and observedCount were already
        // strings and must stay strings; the new counts join them rather than
        // introducing a second convention in the same object.
        #expect(entry["requiredCount"] == "3")
        #expect(entry["observedCount"] == "1")
        #expect(entry["unverifiableCount"] == "4")
        #expect(entry["unclassifiedCount"] == "5")
    }

    @Test("trackEvaluable is the string true or false, never a bare boolean")
    func trackEvaluableIsAString() {
        let unevaluated = mechanicalGapEntry(
            context: sampleContext(trackEvaluable: false),
            evidence: .empty,
            outcome: mechanicalGapOutcome(facts())
        )
        let evaluated = mechanicalGapEntry(
            context: sampleContext(trackEvaluable: true),
            evidence: .empty,
            outcome: mechanicalGapOutcome(facts())
        )

        #expect(unevaluated["trackEvaluable"] == "false")
        #expect(evaluated["trackEvaluable"] == "true")
    }

    @Test("The entry reports the standard's own lane, not the requested filter")
    func entryCarriesTheStandardsLane() {
        let entry = mechanicalGapEntry(
            context: sampleContext(laneKey: "cleaning"),
            evidence: .empty,
            outcome: mechanicalGapOutcome(facts())
        )

        #expect(entry["laneKey"] == "cleaning")
    }

    @Test("The nine pre-Atom-A keys keep their names and their values")
    func backwardCompatibleFieldsAreUnchanged() {
        let entry = mechanicalGapEntry(
            context: sampleContext(requiredCount: 1),
            evidence: ObservationEvidenceTally(observedCount: 0, unverifiableCount: 0, unclassifiedCount: 0),
            outcome: mechanicalGapOutcome(facts(requiredCount: 1, observed: 0))
        )

        #expect(entry["sourceTag"] == "[?]")
        #expect(entry["standardKey"] == "kitchen-photo-22:00-23:00")
        #expect(entry["description"] == "Expected photo information for kitchen between 22:00 and 23:00")
        #expect(entry["expectedDate"] == "2026-08-22")
        #expect(entry["evaluationTimestamp"] == "2026-08-22T23:00:00Z")
        #expect(entry["expectedWindow"] == "22:00-23:00")
        #expect(entry["requiredCount"] == "1")
        #expect(entry["observedCount"] == "0")
        #expect(entry["gapStatus"] == "Missing expected observation")
    }

    // MARK: Evidence classification against real files (A-AC4, A-AC5)

    @Test("A record counts once however many artefacts it carries")
    func multipleArtefactsCountOnce() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        let recordID = UUID()
        try storage.write("photo.jpg")
        try storage.write("recording.m4a")

        let tally = observationEvidenceTally(
            fromArtefacts: [
                (recordID: recordID, fileName: "photo.jpg"),
                (recordID: recordID, fileName: "recording.m4a")
            ],
            storageDirectory: storage.path
        )

        // A shared observation identity is deliberate: a photo and a recording may
        // belong to one observation. Counting the artefacts rather than the records
        // would let a single observation close a standard requiring two.
        #expect(tally.observedCount == 1)
        #expect(tally.unverifiableCount == 0)
        #expect(tally.unclassifiedCount == 0)
    }

    @Test("A record whose files are all missing is unverifiable, not observed")
    func missingFilesAreUnverifiable() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        let tally = observationEvidenceTally(
            fromArtefacts: [(recordID: UUID(), fileName: "vanished.jpg")],
            storageDirectory: storage.path
        )

        #expect(tally.observedCount == 0)
        #expect(tally.unverifiableCount == 1)
        #expect(tally.unclassifiedCount == 0)
    }

    @Test("One readable artefact is enough; a second missing one does not undo it")
    func onePresentArtefactIsEnough() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        let recordID = UUID()
        try storage.write("present.jpg")

        let tally = observationEvidenceTally(
            fromArtefacts: [
                (recordID: recordID, fileName: "present.jpg"),
                (recordID: recordID, fileName: "vanished.m4a")
            ],
            storageDirectory: storage.path
        )

        #expect(tally.observedCount == 1)
        #expect(tally.unverifiableCount == 0)
    }

    @Test("A record with no artefact row at all is unclassified")
    func recordsWithoutArtefactsAreUnclassified() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        let tally = observationEvidenceTally(
            fromArtefacts: [(recordID: UUID(), fileName: nil)],
            storageDirectory: storage.path
        )

        #expect(tally.observedCount == 0)
        #expect(tally.unverifiableCount == 0)
        #expect(tally.unclassifiedCount == 1)
    }

    @Test("The three counts are exhaustive and mutually exclusive")
    func everyRecordLandsInExactlyOneCount() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        try storage.write("present.jpg")

        let observedRecord = UUID()
        let unverifiableRecord = UUID()
        let unclassifiedRecord = UUID()

        let tally = observationEvidenceTally(
            fromArtefacts: [
                (recordID: observedRecord, fileName: "present.jpg"),
                (recordID: unverifiableRecord, fileName: "vanished.jpg"),
                (recordID: unclassifiedRecord, fileName: nil)
            ],
            storageDirectory: storage.path
        )

        #expect(tally.observedCount == 1)
        #expect(tally.unverifiableCount == 1)
        #expect(tally.unclassifiedCount == 1)

        // No record may be silently absent from all three.
        #expect(tally.observedCount + tally.unverifiableCount + tally.unclassifiedCount == 3)
    }

    @Test("An empty result is three zeroes, not an error")
    func emptyResultIsZero() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        let tally = observationEvidenceTally(fromArtefacts: [], storageDirectory: storage.path)

        #expect(tally.observedCount == 0)
        #expect(tally.unverifiableCount == 0)
        #expect(tally.unclassifiedCount == 0)
        #expect(ObservationEvidenceTally.empty.observedCount == 0)
    }

    @Test("Positive control: the file check can see a file that is really there")
    func fileCheckIsNotVacuous() throws {
        let storage = try TemporaryStorage()
        defer { storage.remove() }

        try storage.write("real.jpg")

        // Without this a zero above could just as well mean the check never looked.
        #expect(FileManager.default.fileExists(atPath: storage.path + "/real.jpg"))
        #expect(FileManager.default.fileExists(atPath: storage.path + "/absent.jpg") == false)
    }

    // MARK: The legacy sentinel (A-AC7)

    @Test("A declared created_at is recognised and the legacy sentinel is not")
    func legacySentinelIsDiscriminated() {
        // POST /api/v1/standards writes ISO8601DateFormatter output. The night-photo
        // fixation names seven columns and supplies none of the governance fields, so
        // its rows carry the sentinel the migration defaulted them to.
        #expect(standardCreatedAtIsDeclared("2026-08-22T06:45:52Z"))
        #expect(standardCreatedAtIsDeclared(ISO8601DateFormatter().string(from: Date())))
        #expect(standardCreatedAtIsDeclared("legacy-created-at") == false)
        #expect(standardCreatedAtIsDeclared("") == false)
        #expect(standardCreatedAtIsDeclared("2026-08-22") == false)
    }

    @Test("The sentinel loses the text comparison isStandardActive falls back on")
    func sentinelSortsAfterEveryEvaluationTimestamp() {
        // This is the mechanism, stated as an assertion rather than as a comment: the
        // sentinel begins with a letter, every evaluation timestamp begins with a digit,
        // and isStandardActive's fallback is a plain string comparison. Without the
        // predicate above, every such standard silently resolved to inactive.
        let evaluationTimestamp = iso8601Timestamp(dateString: "2026-08-22", hour: 23)

        #expect(("legacy-created-at" <= evaluationTimestamp) == false)
        #expect("2026-08-22T06:45:52Z" <= evaluationTimestamp)
    }

    @Test("The status decision lookup is bounded by the evaluation timestamp")
    func statusDecisionLookupIsHistorical() throws {
        let body = try #require(declarationBody(
            startingWithLinePrefix: "func standardStatusDecisionCountQuery(",
            inSource: try serverModuleSourceText()
        ))
        let sql = body.joined(separator: "\n")

        // A decision taken after the day being asked about says nothing about that day.
        #expect(sql.contains("FROM standard_status_updates"))
        #expect(sql.contains(#"standard_id = \(bind: standardID)"#))
        #expect(sql.contains(#"changed_at <= \(bind: evaluationTimestamp)"#))
        #expect(sql.uppercased().contains("ORDER BY") == false)
    }

    @Test("isStandardActive keeps the signature the order pinned")
    func isStandardActiveSignatureIsUnchanged() throws {
        // A-AC7 and STOPPVILLKOR: the activation authority itself was not to be changed.
        // The legacy discrimination happens at the call site, alongside it.
        #expect(try serverModuleSourceText().contains(
            """
            func isStandardActive(
                standardID: UUID,
                at evaluationTimestamp: String,
                createdAt: String,
                sql: SQLDatabase
            ) async throws -> Bool {
            """
        ))
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

/// A real directory with real files, so the evidence check is exercised rather than mocked.
///
/// The check it exercises is `FileManager.fileExists`, and a stub for that would only
/// prove the stub works. Every instance is removed by its own test.
private struct TemporaryStorage {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "aihos-gap-evidence-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func write(_ fileName: String) throws {
        try Data("evidence".utf8).write(to: URL(fileURLWithPath: path + "/" + fileName))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
