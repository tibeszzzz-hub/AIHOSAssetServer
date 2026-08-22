import Foundation
import SQLKit

// MARK: - Observation window, lane-scoped evidence, and the mechanical gap decision
//
// Turning a standard's "22:00–23:00" into a range that can be compared against stored
// timestamps, classifying the records that fall inside that range, and deciding what a
// single standard's gap status actually is.
//
// The window arithmetic below was extracted verbatim from AIHOSAssetServer.swift by
// F-E2. Atom A (WFOS-20260822-PSKS-004) added the lane-scoped evidence tally, the
// activation and declaration predicates, and the gap decision table — the route files
// coordinate, this file decides. That split is deliberate: `MechanicalGapReadRoutes`
// and `OperationalPulseReadRoutes` must answer the same questions the same way, and a
// rule that lives in one route file drifts from the other the moment either is edited.
//
// What stayed behind: the operations time zone that these helpers resolve boundaries
// in (F-E1), the diagnostic query, isStandardActive, and the server host and storage
// configuration.
//
// TWO PROPERTIES OF THIS FILE THAT ARE CONTRACT, NOT STYLE
//   No query here carries an ORDER BY. Result ordering is a client contract pinned per
//   file (ResultOrderingContractTests); these helpers count and classify, they never
//   decide what order a client sees.
//
//   Every value that reaches SQL is bound, never interpolated as text. The lane key a
//   caller supplies is validated against the allowlist before it arrives, and it is
//   still bound — validation and parameterisation are separate defences and both stay.

/// Half-open epoch bounds of one standard's window on one local operations date.
///
/// Both values are exactly ten digits so they can be compared directly against the
/// stored text. `endEpoch` is exclusive.
struct ObservationWindowBounds: Equatable {
    let startEpoch: String
    let endEpoch: String
}

/// Formats an epoch second as the canonical fixed-width text form.
///
/// Returns `nil` outside the representable range, so a value that would break the
/// fixed width — and therefore break lexicographic ordering — can never be emitted.
func canonicalEpochString(_ epochSeconds: Int) -> String? {
    guard epochSeconds >= 0, epochSeconds <= 9_999_999_999 else { return nil }
    return String(format: "%010d", epochSeconds)
}

/// Resolves `localDate` plus `startHour..<endHour` into canonical epoch bounds.
///
/// The single window helper both the gap and the pulse calculation use. Boundaries
/// are built from date components rather than by adding hours to midnight, so a day
/// that is 23 or 25 hours long resolves to the correct wall-clock instants.
///
/// Returns `nil` for an unusable request — malformed date, inverted or out-of-range
/// hours, or an epoch outside the fixed width — so the caller fails closed instead of
/// counting against a half-built window.
func observationWindowBounds(
    localDate: String,
    startHour: Int,
    endHour: Int,
    timeZone: TimeZone
) -> ObservationWindowBounds? {
    guard isValidISO8601DateString(localDate) else { return nil }
    guard startHour >= 0, endHour > startHour, endHour <= 24 else { return nil }

    let parts = localDate.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]) else { return nil }

    let calendar = operationsCalendar(timeZone: timeZone)

    var startComponents = DateComponents()
    startComponents.year = year
    startComponents.month = month
    startComponents.day = day
    startComponents.hour = startHour

    guard let startDate = calendar.date(from: startComponents) else { return nil }

    let endDate: Date?
    if endHour == 24 {
        // A window closing at midnight belongs to the next local day's 00:00.
        var midnightComponents = DateComponents()
        midnightComponents.year = year
        midnightComponents.month = month
        midnightComponents.day = day
        midnightComponents.hour = 0

        endDate = calendar.date(from: midnightComponents).flatMap {
            calendar.date(byAdding: .day, value: 1, to: $0)
        }
    } else {
        var endComponents = DateComponents()
        endComponents.year = year
        endComponents.month = month
        endComponents.day = day
        endComponents.hour = endHour

        endDate = calendar.date(from: endComponents)
    }

    guard let endDate,
          let startEpoch = canonicalEpochString(Int(startDate.timeIntervalSince1970)),
          let endEpoch = canonicalEpochString(Int(endDate.timeIntervalSince1970)),
          startEpoch < endEpoch else { return nil }

    return ObservationWindowBounds(startEpoch: startEpoch, endEpoch: endEpoch)
}

// MARK: - Lane-scoped observation evidence

/// How the records inside one lane and one window divide into evidence outcomes.
///
/// The three counts are mutually exclusive and together cover every distinct record in
/// the lane and window, so a record can never be silently absent from all three. That
/// exhaustiveness is the point: before Atom A a record whose payload file had vanished
/// still counted as a fulfilled observation, because the calculation counted rows and
/// never asked whether the evidence behind them could be read.
struct ObservationEvidenceTally {
    /// Distinct records carrying at least one artefact whose file is readable.
    let observedCount: Int
    /// Distinct records carrying artefacts of which none can be read from storage.
    let unverifiableCount: Int
    /// Distinct records inside the lane and window with no registered artefact at all.
    let unclassifiedCount: Int

    /// The tally for a standard that was never evaluated against a window.
    static let empty = ObservationEvidenceTally(
        observedCount: 0,
        unverifiableCount: 0,
        unclassifiedCount: 0
    )
}

/// Every record in one lane and window, with each artefact it carries. The only window
/// SQL in the server.
///
/// The timestamp comparison is a plain half-open text range. That is exact rather than
/// convenient: every stored value is fixed-width, so lexicographic order is numeric
/// order. The shape guard is defence in depth — should a non-canonical row ever exist
/// despite the ingest contract, it is excluded rather than mis-ranked.
///
/// The join is LEFT, not INNER, and that is the whole reason this query replaced a
/// `COUNT(*)`: a record with no artefact row must still be seen, because "present in
/// the lane and window but carrying no registered form" is a distinct outcome from
/// "not there at all". An INNER join would drop exactly those records and report a
/// cleaner day than the data supports.
///
/// The lane predicate is what stops one lane closing another's expectation. It is
/// bound, never interpolated.
func laneScopedObservationEvidenceQuery(
    bounds: ObservationWindowBounds,
    laneKey: String
) -> SQLQueryString {
    """
        SELECT
            asset_records.id AS "recordID",
            asset_files."fileName" AS "fileName"
        FROM asset_records
        LEFT JOIN asset_files
            ON asset_files."assetRecordID" = asset_records.id
        WHERE asset_records.lane_key = \(bind: laneKey)
          AND asset_records."captureTimestamp" ~ '^[0-9]{10}$'
          AND asset_records."captureTimestamp" >= \(bind: bounds.startEpoch)
          AND asset_records."captureTimestamp" < \(bind: bounds.endEpoch)
    """
}

/// One row of `laneScopedObservationEvidenceQuery`: a record and one artefact it carries,
/// or a record and `nil` when it carries none.
typealias ObservationEvidenceArtefact = (recordID: UUID, fileName: String?)

/// Decodes the rows of `laneScopedObservationEvidenceQuery`.
///
/// Split from the classification below so the rule that decides what a hotel is told can
/// be exercised directly, without a database. Decoding is the part that needs a driver;
/// deciding is the part that needs testing.
func observationEvidenceArtefacts(from rows: [any SQLRow]) throws -> [ObservationEvidenceArtefact] {
    try rows.map { row in
        (
            recordID: try row.decode(column: "recordID", as: UUID.self),
            fileName: try row.decode(column: "fileName", as: String?.self)
        )
    }
}

/// Groups artefacts by record and classifies each record into exactly one outcome.
///
/// Grouping happens by `asset_records.id`, so a record carrying a photo and a recording
/// counts once, not twice — the query returns one row per artefact and a record with
/// several artefacts would otherwise close a standard on its own.
///
/// A record counts as observed when AT LEAST ONE of its artefacts is readable. It is
/// unverifiable only when none of them are: one readable artefact is evidence that the
/// observation happened, and a second, missing file does not undo that.
///
/// `storageDirectory` is the validated storage root. No path is logged from here, and
/// none is returned — the caller receives counts only.
func observationEvidenceTally(
    fromArtefacts artefacts: [ObservationEvidenceArtefact],
    storageDirectory: String
) -> ObservationEvidenceTally {
    var artefactsByRecord: [UUID: [String]] = [:]

    for artefact in artefacts {
        var names = artefactsByRecord[artefact.recordID] ?? []
        if let fileName = artefact.fileName {
            names.append(fileName)
        }
        artefactsByRecord[artefact.recordID] = names
    }

    var observedCount = 0
    var unverifiableCount = 0
    var unclassifiedCount = 0

    for artefacts in artefactsByRecord.values {
        if artefacts.isEmpty {
            unclassifiedCount += 1
        } else if artefacts.contains(where: {
            FileManager.default.fileExists(atPath: storageDirectory + "/" + $0)
        }) {
            observedCount += 1
        } else {
            unverifiableCount += 1
        }
    }

    return ObservationEvidenceTally(
        observedCount: observedCount,
        unverifiableCount: unverifiableCount,
        unclassifiedCount: unclassifiedCount
    )
}

/// Decodes and classifies in one step. What the route calls.
func observationEvidenceTally(
    from rows: [any SQLRow],
    storageDirectory: String
) throws -> ObservationEvidenceTally {
    observationEvidenceTally(
        fromArtefacts: try observationEvidenceArtefacts(from: rows),
        storageDirectory: storageDirectory
    )
}

// MARK: - Standard activation and declaration

/// Whether a standard's `created_at` is a real timestamp rather than the legacy sentinel.
///
/// `AddOperationalStandardsGovernanceFields` added `created_at`, `lane_key` and
/// `track_type` with defaults, so every row that already existed — and every row
/// `POST /api/v1/standards/night-photo` still writes, because its INSERT names seven
/// columns and none of these — carries `created_at = 'legacy-created-at'`,
/// `lane_key = 'unassigned'` and `track_type = 'observation'`. None of those three
/// values was declared by anyone; they are what the column defaulted to.
///
/// That matters twice over, and this one predicate answers both questions:
///
///   - `isStandardActive` falls back to comparing `created_at` against the evaluation
///     timestamp as plain text. The sentinel begins with a letter and therefore sorts
///     after every ISO 8601 value, so the comparison silently returns false and the
///     standard disappears from the day's report as though someone had retired it.
///   - `track_type` on such a row is equally undeclared, which is why the server may
///     not present its track as authoritative.
///
/// Returns true only for a value in the shape `ISO8601DateFormatter` produces, which is
/// what `POST /api/v1/standards` writes.
func standardCreatedAtIsDeclared(_ createdAt: String) -> Bool {
    createdAt.range(
        of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"#,
        options: .regularExpression
    ) != nil
}

/// Counts explicit status decisions recorded for one standard at or before an instant.
///
/// Used only to tell two different "not active" answers apart. `isStandardActive`
/// returns a single Bool and cannot say whether it read a recorded decision or fell
/// back to `created_at`; on a legacy-sentinel row those two mean opposite things. A
/// recorded decision is a person deciding, and the standard is genuinely Not active. No
/// decision at all means activation could not be resolved, and the honest answer is
/// Unknown rather than a quiet disappearance.
///
/// `isStandardActive` keeps its signature and remains the single authority on whether a
/// standard was active; this asks a different question alongside it.
func standardStatusDecisionCountQuery(
    standardID: UUID,
    at evaluationTimestamp: String
) -> SQLQueryString {
    """
        SELECT COUNT(*) AS "decisionCount"
        FROM standard_status_updates
        WHERE standard_id = \(bind: standardID)
          AND changed_at <= \(bind: evaluationTimestamp)
    """
}

/// Counts human `leave_empty` decisions for one standard, on one local date, for one
/// window. The only decision-trace window SQL in the server.
///
/// `expected_window_start` and `expected_window_end` stay ISO 8601: they record what a
/// person decided about a named window, not when an observation was captured, and are
/// deliberately not converted to epoch here.
///
/// The date filter is the correction: without it a `leave_empty` decision made on any
/// earlier day suppressed today's gap for the same standard, forever.
func leaveEmptyDecisionCountQuery(
    standardKey: String,
    localDate: String,
    startHour: Int,
    endHour: Int
) -> SQLQueryString {
    """
        SELECT COUNT(*) AS "decisionCount"
        FROM decision_traces
        WHERE "standard_key" = \(bind: standardKey)
          AND "expected_window_start" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
          AND "expected_window_end" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
          AND SUBSTRING("expected_window_start" FROM 1 FOR 10) = \(bind: localDate)
          AND SUBSTRING("expected_window_end" FROM 1 FOR 10) = \(bind: localDate)
          AND CAST(SUBSTRING("expected_window_start" FROM 12 FOR 2) AS INTEGER) = \(bind: startHour)
          AND CAST(SUBSTRING("expected_window_end" FROM 12 FOR 2) AS INTEGER) = \(bind: endHour)
          AND "decision_type" = 'leave_empty'
          AND "source_tag" = '[M]'
    """
}

func hourFromExpectedWindow(_ expectedWindow: String) -> Int? {
    let parts = expectedWindow.split(separator: ":")

    guard parts.count == 2,
          let hour = Int(parts[0]),
          hour >= 0,
          hour <= 23,
          parts[1] == "00" else {
        return nil
    }

    return hour
}

// MARK: - The mechanical gap decision

/// The closed set of answers `GET /api/v1/gaps/mechanical` may give about one standard.
///
/// Every standard the route processes leaves with exactly one of these. There is no
/// server-side "unavailable": a transport failure is not a statement about a hotel's
/// day, and classifying one as though it were is the client's job, not the server's.
///
/// `Missing expected observation` keeps its exact historical wording. It is the value
/// clients already match on, and rewording it would be an API change wearing the
/// costume of a tidy-up.
enum MechanicalGapStatus: String {
    case fulfilled = "Fulfilled"
    case decisionRecorded = "Decision recorded"
    case missing = "Missing expected observation"
    case unknown = "Unknown"
    case notActive = "Not active"
}

/// The closed set of reasons a standard's status could not be established.
///
/// Empty for every status other than `.unknown`, so the key is always present and never
/// conditional — a client reads one shape regardless of the answer.
enum MechanicalUnknownReason: String {
    case none = ""
    case standardActivationUnresolved = "standard_activation_unresolved"
    case observationWindowUnresolvable = "observation_window_unresolvable"
    case standardTrackTypeNotDeclared = "standard_track_type_not_declared"
    case trackFormNotRegistered = "track_form_not_registered"
    case evidenceUnverifiable = "evidence_unverifiable"
}

/// Everything known about one standard at the moment its status is decided.
struct MechanicalGapFacts {
    /// False only when activation rests on an undeclared `created_at` and no decision exists.
    let activationResolved: Bool
    /// What `isStandardActive` answered.
    let standardActive: Bool
    /// False when the window could not be resolved into epoch bounds.
    let windowResolved: Bool
    /// False when the standard's own `track_type` was defaulted rather than declared.
    let trackTypeDeclared: Bool
    let requiredCount: Int
    let evidence: ObservationEvidenceTally
    /// Whether a human `leave_empty` decision covers this standard, date and window.
    let leaveEmptyDecisionRecorded: Bool
}

/// One standard's decided status and, when it is unknown, why.
struct MechanicalGapOutcome {
    let status: MechanicalGapStatus
    let reason: MechanicalUnknownReason
}

/// The decision table. Ordered, and the order is the contract.
///
/// Activation is asked first because a standard whose activation cannot be established
/// tells us nothing about its window, its track or its evidence — reporting an evidence
/// reason for it would be a more specific claim than the data supports. The window
/// comes next for the same reason, then the standard's own track declaration, and only
/// then the two record-level reasons, narrower last.
///
/// A single ordering rule runs through all of it: never report a more specific reason
/// than the facts justify, and never report `Missing` while any reason for not knowing
/// is still outstanding. `Missing expected observation` is an accusation — it says a
/// hotel failed to do something — and it is only made when nothing else is unresolved.
///
/// The unreported reasons do not vanish. `unclassifiedCount` and `unverifiableCount`
/// travel on every entry regardless of which reason won, so a client can see that a day
/// reported as activation-unresolved also had unreadable evidence behind it.
func mechanicalGapOutcome(_ facts: MechanicalGapFacts) -> MechanicalGapOutcome {
    guard facts.activationResolved else {
        return MechanicalGapOutcome(status: .unknown, reason: .standardActivationUnresolved)
    }

    guard facts.standardActive else {
        return MechanicalGapOutcome(status: .notActive, reason: .none)
    }

    guard facts.windowResolved else {
        return MechanicalGapOutcome(status: .unknown, reason: .observationWindowUnresolvable)
    }

    guard facts.trackTypeDeclared else {
        return MechanicalGapOutcome(status: .unknown, reason: .standardTrackTypeNotDeclared)
    }

    guard facts.evidence.unclassifiedCount == 0 else {
        return MechanicalGapOutcome(status: .unknown, reason: .trackFormNotRegistered)
    }

    guard facts.evidence.unverifiableCount == 0 else {
        return MechanicalGapOutcome(status: .unknown, reason: .evidenceUnverifiable)
    }

    guard facts.evidence.observedCount < facts.requiredCount else {
        return MechanicalGapOutcome(status: .fulfilled, reason: .none)
    }

    guard !facts.leaveEmptyDecisionRecorded else {
        return MechanicalGapOutcome(status: .decisionRecorded, reason: .none)
    }

    return MechanicalGapOutcome(status: .missing, reason: .none)
}

/// The per-standard values that do not depend on how the evaluation turned out.
///
/// Built once per standard so the three places that emit an entry cannot disagree about
/// what the standard is called or which window it covers.
struct MechanicalGapStandardContext {
    let sourceTag: String
    let standardKey: String
    let description: String
    let laneKey: String
    let expectedDate: String
    let evaluationTimestamp: String
    let expectedWindow: String
    let requiredCount: Int
    /// Whether the server matched the standard's track against the records it counted.
    ///
    /// Always false today. No relation records the form of an asset record — not MIME,
    /// content type, kind or any unambiguous artefact type — so track cannot be matched
    /// without guessing from a client-supplied file name. The limitation is declared on
    /// every entry rather than hidden, because a client that assumed track matching had
    /// happened would read these counts as more precise than they are.
    let trackEvaluable: Bool
}

/// Builds one entry of the `GET /api/v1/gaps/mechanical` response.
///
/// The single place the response shape is decided. Every key is always present and
/// every value is a String — including the counts, which stay text so that a client
/// reading the existing contract sees no type change. No key is conditional: an absent
/// reason is the empty string, never a missing key, because a client that has to branch
/// on key presence will eventually branch wrong.
func mechanicalGapEntry(
    context: MechanicalGapStandardContext,
    evidence: ObservationEvidenceTally,
    outcome: MechanicalGapOutcome
) -> [String: String] {
    [
        "sourceTag": context.sourceTag,
        "standardKey": context.standardKey,
        "description": context.description,
        "laneKey": context.laneKey,
        "expectedDate": context.expectedDate,
        "evaluationTimestamp": context.evaluationTimestamp,
        "expectedWindow": context.expectedWindow,
        "requiredCount": String(context.requiredCount),
        "observedCount": String(evidence.observedCount),
        "unverifiableCount": String(evidence.unverifiableCount),
        "unclassifiedCount": String(evidence.unclassifiedCount),
        "trackEvaluable": context.trackEvaluable ? "true" : "false",
        "gapStatus": outcome.status.rawValue,
        "unknownReason": outcome.reason.rawValue
    ]
}
