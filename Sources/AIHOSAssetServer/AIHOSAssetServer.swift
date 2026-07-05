import Vapor
import Fluent
import FluentPostgresDriver
import SQLKit
import Foundation
#if canImport(Speech)
import Speech
#endif

#if canImport(Vision)
import Vision
#endif

struct SyncMetadata: Codable {
    let captureTimestamp: String
    let sourceTag: String
    let fileName: String?
    let laneKey: String?
}


struct MultipartSyncPayload: Content {
    let metadata: String
    let image: File
}

struct MultipartAudioPayload: Content {
    let metadata: String
    let audio: File
}

struct DecisionPayload: Content {
    let standardKey: String
    let expectedWindowStart: String
    let expectedWindowEnd: String
    let decisionType: String
}

struct PayloadTextRequest: Content {
    let payloadText: String?
    let sourceTag: String
}

struct PayloadTextResponse: Content {
    let id: String
    let assetRecordID: String
    let payloadText: String?
    let sourceTag: String
    let createdAt: String
}

struct MechanicalTranscriptionResponse: Content {
    let assetRecordID: String
    let payloadTextID: String?
    let payloadText: String?
    let sourceTag: String
    let transcriptionStatus: String
    let reason: String?
    let createdAt: String
}

struct VisionOCRTestResponse: Content {
    let ocrStatus: String
    let rawText: String?
    let reason: String?
}

struct ShiftHandoverLogEntry: Content {
    let id: String
    let sourceTag: String
    let eventTimestamp: String
    let entryType: String
    let message: String
    let laneKey: String
}

struct OperationalStandardResponse: Content {
    let id: String
    let standardKey: String
    let laneKey: String
    let trackType: String
    let expectedWindowStart: String
    let expectedWindowEnd: String
    let requiredCount: Int
    let status: String
    let createdAt: String
}

struct OperationalStandardCreateRequest: Content {
    let laneKey: String
    let trackType: String
    let expectedWindowStart: String
    let expectedWindowEnd: String
    let requiredCount: Int
}

struct OperationalStandardStatusUpdateRequest: Content {
    let status: String
    let standardKey: String?
    let laneKey: String?
    let trackType: String?
    let expectedWindowStart: String?
    let expectedWindowEnd: String?
    let requiredCount: Int?
    let createdAt: String?
}

struct StandardStatusUpdateResponse: Content {
    let id: String
    let standardID: String
    let status: String
    let sourceTag: String
    let changedAt: String
}

struct CreateAssetRecords: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("asset_records")
            .id()
            .field("captureTimestamp", .string, .required)
            .field("sourceTag", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("asset_records").delete()
    }
}


struct CreateSubordinateTracks: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("asset_files")
            .id()
            .field("assetRecordID", .uuid, .required, .references("asset_records", "id"))
            .field("fileName", .string, .required)
            .create()

        try await database.schema("asset_events")
            .id()
            .field("assetRecordID", .uuid, .required, .references("asset_records", "id"))
            .field("eventType", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("asset_events").delete()
        try await database.schema("asset_files").delete()
    }
}


struct CreateOperationalStandards: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("operational_standards")
            .id()
            .field("standardKey", .string, .required)
            .field("description", .string, .required)
            .field("sourceTag", .string, .required)
            .field("startHour", .int, .required)
            .field("endHour", .int, .required)
            .field("requiredCount", .int, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("operational_standards").delete()
    }
}

struct AddOperationalStandardsGovernanceFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for operational standards governance migration")
        }

        try await sql.raw("""
            ALTER TABLE operational_standards
            ADD COLUMN IF NOT EXISTS lane_key TEXT NOT NULL DEFAULT 'unassigned';
        """).run()

        try await sql.raw("""
            ALTER TABLE operational_standards
            ADD COLUMN IF NOT EXISTS track_type TEXT NOT NULL DEFAULT 'observation';
        """).run()

        try await sql.raw("""
            ALTER TABLE operational_standards
            ADD COLUMN IF NOT EXISTS expected_window_start TEXT NOT NULL DEFAULT '00:00';
        """).run()

        try await sql.raw("""
            ALTER TABLE operational_standards
            ADD COLUMN IF NOT EXISTS expected_window_end TEXT NOT NULL DEFAULT '00:00';
        """).run()

        try await sql.raw("""
            ALTER TABLE operational_standards
            ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'ACTIVE';
        """).run()

        try await sql.raw("""
            ALTER TABLE operational_standards
            ADD COLUMN IF NOT EXISTS created_at TEXT NOT NULL DEFAULT 'legacy-created-at';
        """).run()

        try await sql.raw("""
            UPDATE operational_standards
            SET expected_window_start = LPAD("startHour"::TEXT, 2, '0') || ':00'
            WHERE expected_window_start = '00:00';
        """).run()

        try await sql.raw("""
            UPDATE operational_standards
            SET expected_window_end = LPAD("endHour"::TEXT, 2, '0') || ':00'
            WHERE expected_window_end = '00:00';
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for operational standards governance migration revert")
        }

        try await sql.raw("ALTER TABLE operational_standards DROP COLUMN IF EXISTS created_at;").run()
        try await sql.raw("ALTER TABLE operational_standards DROP COLUMN IF EXISTS status;").run()
        try await sql.raw("ALTER TABLE operational_standards DROP COLUMN IF EXISTS expected_window_end;").run()
        try await sql.raw("ALTER TABLE operational_standards DROP COLUMN IF EXISTS expected_window_start;").run()
        try await sql.raw("ALTER TABLE operational_standards DROP COLUMN IF EXISTS track_type;").run()
        try await sql.raw("ALTER TABLE operational_standards DROP COLUMN IF EXISTS lane_key;").run()
    }
}

struct CreateDecisionTraces: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for decision traces migration")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS decision_traces (
                id UUID PRIMARY KEY,
                "standard_key" TEXT NOT NULL,
                "expected_window_start" TEXT NOT NULL,
                "expected_window_end" TEXT NOT NULL,
                "decision_type" TEXT NOT NULL,
                "source_tag" TEXT NOT NULL,
                "created_at" TEXT NOT NULL
            );
        """).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("decision_traces").delete()
    }
}

struct CreatePayloadTextStorage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("asset_payload_texts")
            .id()
            .field("assetRecordID", .uuid, .required, .references("asset_records", "id"))
            .field("payload_text", .string)
            .field("source_tag", .string, .required)
            .field("created_at", .string, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("asset_payload_texts").delete()
    }
}

struct CreateGovernanceTriggers: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for governance trigger migration")
        }

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_asset_record_update()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'asset_records are immutable and cannot be updated';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_asset_record_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'asset_records are immutable and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_asset_event_update()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'asset_events are append-only and cannot be updated';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_asset_event_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'asset_events are append-only and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_asset_payload_text_update()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'asset_payload_texts are append-only and cannot be updated';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_asset_payload_text_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'asset_payload_texts are append-only and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_decision_trace_update()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'decision_traces are append-only and cannot be updated';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_decision_trace_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'decision_traces are append-only and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        // --- ADDITIONAL OPERATIONAL STANDARDS GOVERNANCE TRIGGERS ---
        try await sql.raw("""
        CREATE OR REPLACE FUNCTION protect_operational_standard_update()
        RETURNS trigger AS $$
        BEGIN
            IF NEW.status IS DISTINCT FROM OLD.status
               AND NEW."standardKey" = OLD."standardKey"
               AND NEW.lane_key = OLD.lane_key
               AND NEW.track_type = OLD.track_type
               AND NEW.expected_window_start = OLD.expected_window_start
               AND NEW.expected_window_end = OLD.expected_window_end
               AND NEW."requiredCount" = OLD."requiredCount"
               AND NEW.created_at = OLD.created_at
               AND NEW.description = OLD.description
               AND NEW."sourceTag" = OLD."sourceTag"
               AND NEW."startHour" = OLD."startHour"
               AND NEW."endHour" = OLD."endHour" THEN
                RETURN NEW;
            END IF;

            RAISE EXCEPTION 'operational_standards governance violation: only status updates are allowed';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_operational_standard_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'operational_standards are append-only and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()
        // --- END ADDITIONAL OPERATIONAL STANDARDS GOVERNANCE TRIGGERS ---

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_records_update
        BEFORE UPDATE ON asset_records
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_record_update();
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_records_delete
        BEFORE DELETE ON asset_records
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_record_delete();
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_events_update
        BEFORE UPDATE ON asset_events
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_event_update();
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_events_delete
        BEFORE DELETE ON asset_events
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_event_delete();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_asset_payload_texts_update ON asset_payload_texts;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_payload_texts_update
        BEFORE UPDATE ON asset_payload_texts
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_payload_text_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_asset_payload_texts_delete ON asset_payload_texts;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_payload_texts_delete
        BEFORE DELETE ON asset_payload_texts
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_payload_text_delete();
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_decision_traces_update
        BEFORE UPDATE ON decision_traces
        FOR EACH ROW
        EXECUTE FUNCTION prevent_decision_trace_update();
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_decision_traces_delete
        BEFORE DELETE ON decision_traces
        FOR EACH ROW
        EXECUTE FUNCTION prevent_decision_trace_delete();
        """).run()

        // --- ADDITIONAL OPERATIONAL STANDARDS TRIGGER CREATION ---
        try await sql.raw("""
        DROP TRIGGER IF EXISTS protect_operational_standards_update ON operational_standards;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER protect_operational_standards_update
        BEFORE UPDATE ON operational_standards
        FOR EACH ROW
        EXECUTE FUNCTION protect_operational_standard_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_operational_standards_delete ON operational_standards;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_operational_standards_delete
        BEFORE DELETE ON operational_standards
        FOR EACH ROW
        EXECUTE FUNCTION prevent_operational_standard_delete();
        """).run()
        // --- END ADDITIONAL OPERATIONAL STANDARDS TRIGGER CREATION ---
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for governance trigger migration revert")
        }

        try await sql.raw("DROP TRIGGER IF EXISTS prevent_operational_standards_delete ON operational_standards;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS protect_operational_standards_update ON operational_standards;").run()

        try await sql.raw("DROP FUNCTION IF EXISTS prevent_operational_standard_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS protect_operational_standard_update();").run()

        try await sql.raw("DROP TRIGGER IF EXISTS prevent_decision_traces_delete ON decision_traces;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_decision_traces_update ON decision_traces;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_asset_payload_texts_delete ON asset_payload_texts;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_asset_payload_texts_update ON asset_payload_texts;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_asset_events_delete ON asset_events;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_asset_events_update ON asset_events;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_asset_records_delete ON asset_records;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_asset_records_update ON asset_records;").run()

        try await sql.raw("DROP FUNCTION IF EXISTS prevent_decision_trace_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_decision_trace_update();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_asset_payload_text_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_asset_payload_text_update();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_asset_event_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_asset_event_update();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_asset_record_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_asset_record_update();").run()
    }
}

struct ActivateOperationalStandardsGovernanceTriggers: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for operational standards governance activation")
        }

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION protect_operational_standard_update()
        RETURNS trigger AS $$
        BEGIN
            IF NEW.status IS DISTINCT FROM OLD.status
               AND NEW."standardKey" = OLD."standardKey"
               AND NEW.lane_key = OLD.lane_key
               AND NEW.track_type = OLD.track_type
               AND NEW.expected_window_start = OLD.expected_window_start
               AND NEW.expected_window_end = OLD.expected_window_end
               AND NEW."requiredCount" = OLD."requiredCount"
               AND NEW.created_at = OLD.created_at
               AND NEW.description = OLD.description
               AND NEW."sourceTag" = OLD."sourceTag"
               AND NEW."startHour" = OLD."startHour"
               AND NEW."endHour" = OLD."endHour" THEN
                RETURN NEW;
            END IF;

            RAISE EXCEPTION 'operational_standards governance violation: only status updates are allowed';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_operational_standard_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'operational_standards are append-only and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS protect_operational_standards_update ON operational_standards;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER protect_operational_standards_update
        BEFORE UPDATE ON operational_standards
        FOR EACH ROW
        EXECUTE FUNCTION protect_operational_standard_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_operational_standards_delete ON operational_standards;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_operational_standards_delete
        BEFORE DELETE ON operational_standards
        FOR EACH ROW
        EXECUTE FUNCTION prevent_operational_standard_delete();
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for operational standards governance activation revert")
        }

        try await sql.raw("DROP TRIGGER IF EXISTS prevent_operational_standards_delete ON operational_standards;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS protect_operational_standards_update ON operational_standards;").run()

        try await sql.raw("DROP FUNCTION IF EXISTS prevent_operational_standard_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS protect_operational_standard_update();").run()
    }
}

struct CreateStandardStatusUpdates: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for standard status updates migration")
        }

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS standard_status_updates (
            id UUID PRIMARY KEY,
            standard_id UUID NOT NULL REFERENCES operational_standards(id),
            status TEXT NOT NULL,
            source_tag TEXT NOT NULL,
            changed_at TEXT NOT NULL
        );
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_standard_status_update_mutation()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'standard_status_updates are append-only and cannot be updated';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        CREATE OR REPLACE FUNCTION prevent_standard_status_update_delete()
        RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'standard_status_updates are append-only and cannot be deleted';
        END;
        $$ LANGUAGE plpgsql;
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_standard_status_updates_update ON standard_status_updates;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_standard_status_updates_update
        BEFORE UPDATE ON standard_status_updates
        FOR EACH ROW
        EXECUTE FUNCTION prevent_standard_status_update_mutation();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_standard_status_updates_delete ON standard_status_updates;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_standard_status_updates_delete
        BEFORE DELETE ON standard_status_updates
        FOR EACH ROW
        EXECUTE FUNCTION prevent_standard_status_update_delete();
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for standard status updates migration revert")
        }

        try await sql.raw("DROP TRIGGER IF EXISTS prevent_standard_status_updates_delete ON standard_status_updates;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_standard_status_updates_update ON standard_status_updates;").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_standard_status_update_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_standard_status_update_mutation();").run()
        try await sql.raw("DROP TABLE IF EXISTS standard_status_updates;").run()
    }
}

// Lane key allowlist and helper
let allowedLaneKeys: Set<String> = ["kitchen", "service", "finance", "unassigned"]
func validatedLaneKey(_ laneKey: String?) -> String? {
    guard let laneKey else { return "unassigned" }
    guard allowedLaneKeys.contains(laneKey) else { return nil }
    return laneKey
}

let allowedOperationalStandardLaneKeys: Set<String> = ["kitchen", "service", "bar", "cleaning", "maintenance", "unassigned"]
let allowedOperationalStandardTrackTypes: Set<String> = ["observation", "photo", "audio", "ocr"]

func validatedOperationalStandardLaneKey(_ laneKey: String) -> String? {
    guard allowedOperationalStandardLaneKeys.contains(laneKey) else { return nil }
    return laneKey
}

func validatedOperationalStandardTrackType(_ trackType: String) -> String? {
    guard allowedOperationalStandardTrackTypes.contains(trackType) else { return nil }
    return trackType
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

func legacyTimestampSkipLogQuery(context: String) -> SQLQueryString {
    """
        SELECT
            id,
            "captureTimestamp"
        FROM asset_records
        WHERE "captureTimestamp" !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
        ORDER BY "captureTimestamp" ASC
    """
}

func iso8601DateStringForToday() -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

    let now = Date()
    let components = calendar.dateComponents([.year, .month, .day], from: now)

    guard let year = components.year,
          let month = components.month,
          let day = components.day else {
        return String(ISO8601DateFormatter().string(from: now).prefix(10))
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}

func iso8601Timestamp(dateString: String, hour: Int) -> String {
    String(format: "%@T%02d:00:00Z", dateString, hour)
}

func isValidISO8601DateString(_ dateString: String) -> Bool {
    dateString.range(
        of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
        options: .regularExpression
    ) != nil
}

// --- Timestamp Parsing and Formatting Helpers ---
func parsedTimestampDate(_ timestamp: String) -> Date? {
    if let unixTimestamp = TimeInterval(timestamp) {
        return Date(timeIntervalSince1970: unixTimestamp)
    }

    let isoFormatter = ISO8601DateFormatter()
    return isoFormatter.date(from: timestamp)
}

func humanReadableTimestamp(_ timestamp: String) -> String {
    guard let date = parsedTimestampDate(timestamp) else {
        return timestamp
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func isStandardActive(
    standardID: UUID,
    at evaluationTimestamp: String,
    createdAt: String,
    sql: SQLDatabase
) async throws -> Bool {
    let statusRows = try await sql.raw("""
        SELECT status
        FROM standard_status_updates
        WHERE standard_id = \(bind: standardID)
          AND changed_at <= \(bind: evaluationTimestamp)
        ORDER BY changed_at DESC
        LIMIT 1
    """).all()

    if let statusRow = statusRows.first {
        let historicalStatus = try statusRow.decode(column: "status", as: String.self)
        return historicalStatus == "ACTIVE"
    }

    return createdAt <= evaluationTimestamp
}

#if canImport(Speech)
actor AppleSpeechTranscriber {
    enum TranscriptionOutcome {
        case text(String)
        case null(reason: String)
    }

    enum TranscriptionError: Error {
        case recognizerUnavailable
        case authorizationDenied
        case authorizationRestricted
        case authorizationNotDetermined
        case emptyResult
    }

    func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionOutcome {
        let authorizationStatus = await resolvedSpeechAuthorizationStatus()

        switch authorizationStatus {
        case .authorized:
            break
        case .denied:
            throw TranscriptionError.authorizationDenied
        case .restricted:
            throw TranscriptionError.authorizationRestricted
        case .notDetermined:
            throw TranscriptionError.authorizationNotDetermined
        @unknown default:
            throw TranscriptionError.authorizationRestricted
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let transcription = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var didResume = false

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let result else { return }

                if result.isFinal {
                    if !didResume {
                        didResume = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }

        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscription.isEmpty else {
            return .null(reason: "Apple Speech returned empty transcription")
        }

        return .text(trimmedTranscription)
    }

    private func resolvedSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()

        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
    }
}
#else
actor AppleSpeechTranscriber {
    enum TranscriptionOutcome {
        case text(String)
        case null(reason: String)
    }

    func transcribeAudioFile(at fileURL: URL, localeIdentifier: String = "en-US") async throws -> TranscriptionOutcome {
        return .null(reason: "Apple Speech is unavailable on this server runtime")
    }
}
#endif

#if canImport(Vision)

actor AppleVisionOCRVerifier {
    enum OCROutcome {
        case text(String)
        case null(reason: String)
    }

    func recognizeText(in imageURL: URL) async throws -> OCROutcome {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let requestHandler = VNImageRequestHandler(url: imageURL)
        try requestHandler.perform([request])

        let observations = request.results ?? []
        let recognizedLines = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }

        let rawText = recognizedLines.joined(separator: "\n")
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawText.isEmpty else {
            return .null(reason: "Apple Vision OCR returned no readable text")
        }

        return .text(rawText)
    }
}
#else
actor AppleVisionOCRVerifier {
    enum OCROutcome {
        case text(String)
        case null(reason: String)
    }

    func recognizeText(in imageURL: URL) async throws -> OCROutcome {
        return .null(reason: "Apple Vision OCR is unavailable on this server runtime")
    }
}
#endif

@main
struct AIHOSAssetServer {
    static func main() async throws {
        let app = try await Application.make(.detect())
        defer {
            Task {
                try? await app.asyncShutdown()
            }
        }

        app.http.server.configuration.hostname = "0.0.0.0"
        if let portString = Environment.get("PORT"), let port = Int(portString) {
            app.http.server.configuration.port = port
            print("HTTP Server Port from Render PORT: \(port)")
        } else {
            app.http.server.configuration.port = 8080
            print("HTTP Server Port default: 8080")
        }
        print("HTTP Server Host: 0.0.0.0")

        if let databaseURL = Environment.get("DATABASE_URL") {
            var configuration = try SQLPostgresConfiguration(url: databaseURL)

            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none

            configuration.coreConfiguration.tls = try .require(.init(configuration: tlsConfiguration))

            app.databases.use(
                .postgres(configuration: configuration),
                as: .psql
            )

            print("PostgreSQL configuration registered from DATABASE_URL with explicit TLS override")
        } else {
            app.databases.use(
                .postgres(
                    configuration: .init(
                        hostname: "localhost",
                        port: 5432,
                        username: "tibi",
                        password: nil,
                        database: "tibi",
                        tls: .disable
                    )
                ),
                as: .psql
            )
            print("PostgreSQL local configuration registered")
        }

        app.migrations.add(CreateAssetRecords())
        app.migrations.add(CreateSubordinateTracks())
        app.migrations.add(CreateOperationalStandards())
        app.migrations.add(AddOperationalStandardsGovernanceFields())
        app.migrations.add(CreateDecisionTraces())
        app.migrations.add(CreatePayloadTextStorage())
        app.migrations.add(CreateLaneMetadataFoundation())
        app.migrations.add(CreateGovernanceTriggers())
        app.migrations.add(ActivateOperationalStandardsGovernanceTriggers())
        app.migrations.add(CreateStandardStatusUpdates())

        print("Migration registered: CreateAssetRecords")
        print("Migration registered: CreateSubordinateTracks")
        print("Migration registered: CreateOperationalStandards")
        print("Migration registered: AddOperationalStandardsGovernanceFields")
        print("Migration registered: CreateDecisionTraces")
        print("Migration registered: CreatePayloadTextStorage")
        print("Migration registered: CreateLaneMetadataFoundation")
        print("Migration registered: CreateGovernanceTriggers")
        print("Migration registered: ActivateOperationalStandardsGovernanceTriggers")
        print("Migration registered: CreateStandardStatusUpdates")

        try await app.autoMigrate()
        print("Database migrations executed")

        app.get("health", "db") { req async -> Response in
            req.logger.info("DB HEALTH ROUTE ENTERED")

            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")

            guard let sql = req.db as? SQLDatabase else {
                req.logger.error("DB HEALTH SQL CAST FAIL")
                return Response(
                    status: .internalServerError,
                    headers: headers,
                    body: .init(string: #"{"status":"fail","stage":"sql_cast"}"#)
                )
            }

            req.logger.info("DB HEALTH SQL CAST PASS")

            do {
                try await sql.raw("SELECT 1").run()
                req.logger.info("DB HEALTH SELECT 1 PASS")

                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init(string: #"{"status":"ok","stage":"select_1"}"#)
                )
            } catch {
                req.logger.error("DB HEALTH SELECT 1 FAIL: \(String(reflecting: error))")

                return Response(
                    status: .internalServerError,
                    headers: headers,
                    body: .init(string: #"{"status":"fail","stage":"select_1"}"#)
                )
            }
        }

        app.get("test", "immutable") { req async throws -> HTTPStatus in
            guard let sql = req.db as? SQLDatabase else {
                return .internalServerError
            }

            let testID = UUID().uuidString

            do {
                try await sql.raw("""
                INSERT INTO asset_records (id, "captureTimestamp", "sourceTag")
                VALUES ('\(unsafeRaw: testID)', 'test-capture-timestamp', '[TEST]');
                """).run()
                print("Immutable validation INSERT PASS")
            } catch {
                print("Immutable validation INSERT failed: \(error)")
                return .internalServerError
            }

            do {
                try await sql.raw("""
                UPDATE asset_records
                SET "sourceTag" = '[TEST-UPDATED]'
                WHERE id = '\(unsafeRaw: testID)';
                """).run()
                print("Immutable validation UPDATE unexpectedly succeeded")
                return .internalServerError
            } catch {
                print("Immutable validation UPDATE blocked by governance trigger")
            }

            do {
                try await sql.raw("""
                DELETE FROM asset_records
                WHERE id = '\(unsafeRaw: testID)';
                """).run()
                print("Immutable validation DELETE unexpectedly succeeded")
                return .internalServerError
            } catch {
                print("Immutable validation DELETE blocked by governance trigger")
            }

            print("Immutable validation PASS")
            return .ok
        }

        app.on(.POST, "test", "vision-ocr", body: .collect(maxSize: "10mb")) { req async throws -> Response in
            let payload: MultipartSyncPayload

            do {
                payload = try req.content.decode(MultipartSyncPayload.self)
            } catch {
                print("Vision OCR test multipart parsing failed: \(error)")
                return Response(status: .badRequest)
            }

            let workingDirectory = app.directory.workingDirectory
            let testDirectory = workingDirectory + "PayloadStorage/OCRTest"
            let testFileName = "vision-ocr-test-\(UUID().uuidString).jpg"
            let testFilePath = testDirectory + "/" + testFileName
            let testFileURL = URL(fileURLWithPath: testFilePath)

            do {
                try FileManager.default.createDirectory(
                    atPath: testDirectory,
                    withIntermediateDirectories: true
                )

                try Data(buffer: payload.image.data).write(to: testFileURL)
                print("Vision OCR test image save PASS")
                print("testFilePath: \(testFilePath)")
            } catch {
                print("Vision OCR test image save failed: \(error)")
                return Response(status: .internalServerError)
            }

            let verifier = AppleVisionOCRVerifier()
            let outcome: AppleVisionOCRVerifier.OCROutcome

            do {
                outcome = try await verifier.recognizeText(in: testFileURL)
            } catch {
                print("Vision OCR honest error: \(error)")
                let response = Response(status: .internalServerError)
                try response.content.encode(
                    VisionOCRTestResponse(
                        ocrStatus: "error",
                        rawText: nil,
                        reason: String(describing: error)
                    )
                )
                return response
            }

            let response = Response(status: .ok)

            switch outcome {
            case .text(let rawText):
                print("Vision OCR technical verification PASS")
                print("ocrStatus: text")
                print("rawText: \(rawText)")
                try response.content.encode(
                    VisionOCRTestResponse(
                        ocrStatus: "text",
                        rawText: rawText,
                        reason: nil
                    )
                )
            case .null(let reason):
                print("Vision OCR technical verification PASS")
                print("ocrStatus: null")
                print("reason: \(reason)")
                try response.content.encode(
                    VisionOCRTestResponse(
                        ocrStatus: "null",
                        rawText: nil,
                        reason: reason
                    )
                )
            }

            return response
        }

        app.on(.POST, "api", "v1", "sync", body: .collect(maxSize: "10mb")) { req async throws -> HTTPStatus in
            let payload: MultipartSyncPayload

            do {
                payload = try req.content.decode(MultipartSyncPayload.self)
            } catch {
                print("Multipart parsing failed: \(error)")
                return .badRequest
            }

            let metadataData = Data(payload.metadata.utf8)
            let metadata: SyncMetadata

            do {
                metadata = try JSONDecoder().decode(SyncMetadata.self, from: metadataData)
            } catch {
                print("Metadata decode failed: \(error)")
                return .badRequest
            }

            // Validate laneKey before any DB write
            guard let laneKey = validatedLaneKey(metadata.laneKey) else {
                print("Lane validation failed")
                return .badRequest
            }

            let imageSize = payload.image.data.readableBytes
            let storedFileName = metadata.fileName ?? "\(UUID().uuidString).jpg"
            let workingDirectory = app.directory.workingDirectory
            let storageDirectory = workingDirectory + "PayloadStorage"
            let storedFilePath = storageDirectory + "/" + storedFileName
            let forceTransactionalFailure = storedFileName == "test-force-transaction-failure.jpg"

            do {
                try FileManager.default.createDirectory(
                    atPath: storageDirectory,
                    withIntermediateDirectories: true
                )

                try Data(buffer: payload.image.data).write(to: URL(fileURLWithPath: storedFilePath))
                print("Payload file save PASS")
                print("storedFilePath: \(storedFilePath)")
            } catch {
                print("Payload file save failed: \(error)")
                return .internalServerError
            }

            do {
                try await req.db.transaction { database in
                    guard let sql = database as? SQLDatabase else {
                        throw Abort(.internalServerError, reason: "SQL database unavailable inside transaction")
                    }

                    let recordID = UUID()
                    let fileID = UUID()

                    try await sql.raw("""
                    INSERT INTO asset_records (id, "captureTimestamp", "sourceTag", lane_key)
                    VALUES (\(bind: recordID), \(bind: metadata.captureTimestamp), \(bind: metadata.sourceTag), \(bind: laneKey));
                    """).run()

                    if forceTransactionalFailure {
                        print("Intentional transactional failure requested")
                        let missingRecordID = UUID()

                        try await sql.raw("""
                        INSERT INTO asset_files (id, "assetRecordID", "fileName")
                        VALUES (\(bind: fileID), \(bind: missingRecordID), \(bind: storedFileName));
                        """).run()
                    } else {
                        try await sql.raw("""
                        INSERT INTO asset_files (id, "assetRecordID", "fileName")
                        VALUES (\(bind: fileID), \(bind: recordID), \(bind: storedFileName));
                        """).run()
                    }

                    print("Transactional asset_record INSERT PASS")
                    print("Transactional asset_file INSERT PASS")
                    print("assetRecordID: \(recordID.uuidString)")
                    print("assetFileID: \(fileID.uuidString)")
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: storedFilePath) {
                        try FileManager.default.removeItem(atPath: storedFilePath)
                        print("Rollback cleanup PASS: saved payload file deleted")
                    } else {
                        print("Rollback cleanup PASS: no saved payload file found")
                    }
                } catch {
                    print("Rollback cleanup FAILED: saved payload file could not be deleted: \(error)")
                }

                print("Transactional payload fixation failed: \(error)")
                return .internalServerError
            }

            print("[M] Payload fixed transactionally. Tid: \(metadata.captureTimestamp). Bildstorlek: \(imageSize) bytes.")
            print("sourceTag: \(metadata.sourceTag)")
            print("fileName: \(storedFileName)")
            print("storedFilePath: \(storedFilePath)")

            return .ok
        }

        app.on(.POST, "api", "v1", "audio", body: .collect(maxSize: "20mb")) { req async throws -> HTTPStatus in
            let payload: MultipartAudioPayload

            do {
                payload = try req.content.decode(MultipartAudioPayload.self)
            } catch {
                print("Audio multipart parsing failed: \(error)")
                return .badRequest
            }

            let metadataData = Data(payload.metadata.utf8)
            let metadata: SyncMetadata

            do {
                metadata = try JSONDecoder().decode(SyncMetadata.self, from: metadataData)
            } catch {
                print("Audio metadata decode failed: \(error)")
                return .badRequest
            }

            guard let laneKey = validatedLaneKey(metadata.laneKey) else {
                print("Audio lane validation failed")
                return .badRequest
            }

            let audioSize = payload.audio.data.readableBytes
            let storedFileName = metadata.fileName ?? "\(UUID().uuidString).m4a"
            let workingDirectory = app.directory.workingDirectory
            let storageDirectory = workingDirectory + "PayloadStorage"
            let storedFilePath = storageDirectory + "/" + storedFileName

            do {
                try FileManager.default.createDirectory(
                    atPath: storageDirectory,
                    withIntermediateDirectories: true
                )

                guard !FileManager.default.fileExists(atPath: storedFilePath) else {
                    print("Audio file save rejected: file already exists \(storedFileName)")
                    return .conflict
                }

                try Data(buffer: payload.audio.data).write(to: URL(fileURLWithPath: storedFilePath))
                print("Audio file save PASS")
                print("storedFilePath: \(storedFilePath)")
            } catch {
                print("Audio file save failed: \(error)")
                return .internalServerError
            }

            do {
                try await req.db.transaction { database in
                    guard let sql = database as? SQLDatabase else {
                        throw Abort(.internalServerError, reason: "SQL database unavailable inside audio transaction")
                    }

                    let recordID = UUID()
                    let fileID = UUID()

                    try await sql.raw("""
                    INSERT INTO asset_records (id, "captureTimestamp", "sourceTag", lane_key)
                    VALUES (\(bind: recordID), \(bind: metadata.captureTimestamp), \(bind: metadata.sourceTag), \(bind: laneKey));
                    """).run()

                    try await sql.raw("""
                    INSERT INTO asset_files (id, "assetRecordID", "fileName")
                    VALUES (\(bind: fileID), \(bind: recordID), \(bind: storedFileName));
                    """).run()

                    print("Audio asset_record INSERT PASS")
                    print("Audio asset_file INSERT PASS")
                    print("assetRecordID: \(recordID.uuidString)")
                    print("assetFileID: \(fileID.uuidString)")
                }
            } catch {
                do {
                    if FileManager.default.fileExists(atPath: storedFilePath) {
                        try FileManager.default.removeItem(atPath: storedFilePath)
                        print("Audio rollback cleanup PASS: saved audio file deleted")
                    } else {
                        print("Audio rollback cleanup PASS: no saved audio file found")
                    }
                } catch {
                    print("Audio rollback cleanup FAILED: saved audio file could not be deleted: \(error)")
                }

                print("Transactional audio fixation failed: \(error)")
                return .internalServerError
            }

            print("[M] Audio fixed transactionally. Tid: \(metadata.captureTimestamp). Ljudstorlek: \(audioSize) bytes.")
            print("sourceTag: \(metadata.sourceTag)")
            print("laneKey: \(laneKey)")
            print("fileName: \(storedFileName)")
            print("storedFilePath: \(storedFilePath)")
            print("Source Awareness: original audio stored as asset file; no transcription or payload_text generated")

            return .ok
        }

        app.get("api", "v1", "records") { req async throws -> Response in
            let sql = req.db as! SQLDatabase

            let rows = try await sql.raw("""
                SELECT
                    asset_records.id,
                    asset_records."captureTimestamp",
                    asset_records."sourceTag",
                    asset_records.lane_key,
                    asset_files."fileName"
                FROM asset_records
                INNER JOIN asset_files
                    ON asset_files."assetRecordID" = asset_records.id
                ORDER BY asset_records."captureTimestamp" ASC
            """).all()

            var records = rows.map { row -> [String: String] in
                let id = try! row.decode(column: "id", as: UUID.self).uuidString
                let captureTimestamp = try! row.decode(column: "captureTimestamp", as: String.self)
                let sourceTag = try! row.decode(column: "sourceTag", as: String.self)
                let laneKey = try! row.decode(column: "lane_key", as: String.self)
                let fileName = try! row.decode(column: "fileName", as: String.self)

                return [
                    "id": id,
                    "captureTimestamp": captureTimestamp,
                    "displayTimestamp": humanReadableTimestamp(captureTimestamp),
                    "sourceTag": sourceTag,
                    "lane_key": laneKey,
                    "fileName": fileName
                ]
            }

            records.sort { first, second in
                let firstDate = parsedTimestampDate(first["captureTimestamp"] ?? "") ?? Date.distantPast
                let secondDate = parsedTimestampDate(second["captureTimestamp"] ?? "") ?? Date.distantPast
                return firstDate > secondDate
            }

            let response = Response(status: .ok)
            try response.content.encode(records)
            return response
        }

        app.get("api", "v1", "standards") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    lane_key,
                    track_type,
                    expected_window_start,
                    expected_window_end,
                    "requiredCount",
                    status,
                    created_at
                FROM operational_standards
                ORDER BY created_at ASC
            """).all()

            let standards = try rows.map { row -> OperationalStandardResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let standardKey = try row.decode(column: "standardKey", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)
                let trackType = try row.decode(column: "track_type", as: String.self)
                let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
                let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
                let requiredCount = try row.decode(column: "requiredCount", as: Int.self)
                let status = try row.decode(column: "status", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)

                return OperationalStandardResponse(
                    id: id,
                    standardKey: standardKey,
                    laneKey: laneKey,
                    trackType: trackType,
                    expectedWindowStart: expectedWindowStart,
                    expectedWindowEnd: expectedWindowEnd,
                    requiredCount: requiredCount,
                    status: status,
                    createdAt: createdAt
                )
            }

            print("Operational Standards retrieval PASS: \(standards.count) standards")
            print("Operational Standards sort: createdAt ASC")
            print("Operational Standards source: server-side operational_standards")

            let response = Response(status: .ok)
            try response.content.encode(standards)
            return response
        }

        app.post("api", "v1", "standards") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let payload: OperationalStandardCreateRequest

            do {
                payload = try req.content.decode(OperationalStandardCreateRequest.self)
            } catch {
                print("Operational Standard create failed: payload decode error \(error)")
                return Response(status: .badRequest)
            }

            guard let laneKey = validatedOperationalStandardLaneKey(payload.laneKey) else {
                print("Operational Standard create failed: invalid laneKey \(payload.laneKey)")
                return Response(status: .badRequest)
            }

            guard let trackType = validatedOperationalStandardTrackType(payload.trackType) else {
                print("Operational Standard create failed: invalid trackType \(payload.trackType)")
                return Response(status: .badRequest)
            }

            guard let startHour = hourFromExpectedWindow(payload.expectedWindowStart),
                  let endHour = hourFromExpectedWindow(payload.expectedWindowEnd),
                  endHour > startHour else {
                print("Operational Standard create failed: invalid expected window")
                return Response(status: .badRequest)
            }

            guard payload.requiredCount > 0 else {
                print("Operational Standard create failed: requiredCount must be greater than zero")
                return Response(status: .badRequest)
            }

            let duplicateRows = try await sql.raw("""
                SELECT COUNT(*) AS duplicate_count
                FROM operational_standards
                WHERE lane_key = \(bind: laneKey)
                  AND track_type = \(bind: trackType)
                  AND expected_window_start = \(bind: payload.expectedWindowStart)
                  AND expected_window_end = \(bind: payload.expectedWindowEnd)
                  AND "requiredCount" = \(bind: payload.requiredCount)
                  AND status = 'ACTIVE'
            """).all()

            let duplicateCount = try duplicateRows[0].decode(column: "duplicate_count", as: Int.self)

            guard duplicateCount == 0 else {
                print("Operational Standard create blocked: duplicate active standard")
                let response = Response(status: .conflict)
                try response.content.encode([
                    "reason": "duplicate active operational standard"
                ])
                return response
            }

            let standardID = UUID()
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let status = "ACTIVE"
            let sourceTag = "[?]"
            let standardKey = "\(laneKey)-\(trackType)-\(payload.expectedWindowStart)-\(payload.expectedWindowEnd)"
            let description = "Expected \(trackType) information for \(laneKey) between \(payload.expectedWindowStart) and \(payload.expectedWindowEnd)"

            do {
                try await sql.raw("""
                    INSERT INTO operational_standards
                    (id, "standardKey", description, "sourceTag", "startHour", "endHour", "requiredCount", lane_key, track_type, expected_window_start, expected_window_end, status, created_at)
                    VALUES
                    (\(bind: standardID), \(bind: standardKey), \(bind: description), \(bind: sourceTag), \(bind: startHour), \(bind: endHour), \(bind: payload.requiredCount), \(bind: laneKey), \(bind: trackType), \(bind: payload.expectedWindowStart), \(bind: payload.expectedWindowEnd), \(bind: status), \(bind: createdAt));
                """).run()
            } catch {
                print("Operational Standard create failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Operational Standard create PASS")
            print("standardID: \(standardID.uuidString)")
            print("laneKey: \(laneKey)")
            print("trackType: \(trackType)")
            print("expectedWindowStart: \(payload.expectedWindowStart)")
            print("expectedWindowEnd: \(payload.expectedWindowEnd)")
            print("requiredCount: \(payload.requiredCount)")
            print("status: \(status)")
            print("createdAt: \(createdAt)")
            print("Governance: standard created append-only; no historical standard mutated")

            let response = Response(status: .ok)
            try response.content.encode(
                OperationalStandardResponse(
                    id: standardID.uuidString,
                    standardKey: standardKey,
                    laneKey: laneKey,
                    trackType: trackType,
                    expectedWindowStart: payload.expectedWindowStart,
                    expectedWindowEnd: payload.expectedWindowEnd,
                    requiredCount: payload.requiredCount,
                    status: status,
                    createdAt: createdAt
                )
            )
            return response
        }

        app.on(.PATCH, "api", "v1", "standards", ":standardID", "status") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let standardIDString = req.parameters.get("standardID"),
                  let standardID = UUID(uuidString: standardIDString) else {
                print("Operational Standard status update failed: invalid standardID")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "invalid operational standard id"
                ])
                return response
            }

            let payload: OperationalStandardStatusUpdateRequest

            do {
                payload = try req.content.decode(OperationalStandardStatusUpdateRequest.self)
            } catch {
                print("Operational Standard status update failed: payload decode error \(error)")
                return Response(status: .badRequest)
            }

            if payload.standardKey != nil
                || payload.laneKey != nil
                || payload.trackType != nil
                || payload.expectedWindowStart != nil
                || payload.expectedWindowEnd != nil
                || payload.requiredCount != nil
                || payload.createdAt != nil {
                print("Operational Standard status update blocked: core metadata mutation attempted")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "Mutation of core metadata is not allowed."
                ])
                return response
            }

            guard payload.status == "ACTIVE" || payload.status == "PAUSED" else {
                print("Operational Standard status update failed: invalid status \(payload.status)")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "status must be ACTIVE or PAUSED"
                ])
                return response
            }

            let existingRows = try await sql.raw("""
                SELECT id
                FROM operational_standards
                WHERE id = \(bind: standardID)
            """).all()

            guard existingRows.count == 1 else {
                print("Operational Standard status update failed: standard not found \(standardID.uuidString)")
                return Response(status: .notFound)
            }

            let statusUpdateID = UUID()
            let changedAt = ISO8601DateFormatter().string(from: Date())
            let statusSourceTag = "[M]"

            do {
                try await req.db.transaction { database in
                    guard let transactionSQL = database as? SQLDatabase else {
                        throw Abort(.internalServerError, reason: "SQL database unavailable inside status update transaction")
                    }

                    try await transactionSQL.raw("""
                        UPDATE operational_standards
                        SET status = \(bind: payload.status)
                        WHERE id = \(bind: standardID)
                    """).run()

                    try await transactionSQL.raw("""
                        INSERT INTO standard_status_updates
                        (id, standard_id, status, source_tag, changed_at)
                        VALUES
                        (\(bind: statusUpdateID), \(bind: standardID), \(bind: payload.status), \(bind: statusSourceTag), \(bind: changedAt));
                    """).run()
                }
            } catch {
                print("Operational Standard status update failed: \(error)")
                return Response(status: .internalServerError)
            }

            let updatedRows = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    lane_key,
                    track_type,
                    expected_window_start,
                    expected_window_end,
                    "requiredCount",
                    status,
                    created_at
                FROM operational_standards
                WHERE id = \(bind: standardID)
                LIMIT 1
            """).all()

            guard updatedRows.count == 1 else {
                print("Operational Standard status update failed: updated row missing \(standardID.uuidString)")
                return Response(status: .internalServerError)
            }

            let row = updatedRows[0]
            let id = try row.decode(column: "id", as: UUID.self).uuidString
            let standardKey = try row.decode(column: "standardKey", as: String.self)
            let laneKey = try row.decode(column: "lane_key", as: String.self)
            let trackType = try row.decode(column: "track_type", as: String.self)
            let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
            let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
            let requiredCount = try row.decode(column: "requiredCount", as: Int.self)
            let status = try row.decode(column: "status", as: String.self)
            let createdAt = try row.decode(column: "created_at", as: String.self)

            print("Operational Standard status update PASS")
            print("standardID: \(standardID.uuidString)")
            print("status: \(status)")
            print("statusUpdateID: \(statusUpdateID.uuidString)")
            print("sourceTag: \(statusSourceTag)")
            print("changedAt: \(changedAt)")
            print("Governance: status-only update; core metadata unchanged")
            print("Status Timeline: transition inserted append-only")

            let response = Response(status: .ok)
            try response.content.encode(
                OperationalStandardResponse(
                    id: id,
                    standardKey: standardKey,
                    laneKey: laneKey,
                    trackType: trackType,
                    expectedWindowStart: expectedWindowStart,
                    expectedWindowEnd: expectedWindowEnd,
                    requiredCount: requiredCount,
                    status: status,
                    createdAt: createdAt
                )
            )
            return response
        }

        app.get("api", "v1", "standards", ":standardID", "status-updates") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let standardIDString = req.parameters.get("standardID"),
                  let standardID = UUID(uuidString: standardIDString) else {
                print("Standard Status Timeline retrieval failed: invalid standardID")
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "invalid operational standard id"
                ])
                return response
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    standard_id,
                    status,
                    source_tag,
                    changed_at
                FROM standard_status_updates
                WHERE standard_id = \(bind: standardID)
                ORDER BY changed_at ASC
            """).all()

            let updates = try rows.map { row -> StandardStatusUpdateResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let standardID = try row.decode(column: "standard_id", as: UUID.self).uuidString
                let status = try row.decode(column: "status", as: String.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let changedAt = try row.decode(column: "changed_at", as: String.self)

                return StandardStatusUpdateResponse(
                    id: id,
                    standardID: standardID,
                    status: status,
                    sourceTag: sourceTag,
                    changedAt: changedAt
                )
            }

            print("Standard Status Timeline retrieval PASS: \(updates.count) updates")
            print("standardID: \(standardID.uuidString)")
            print("Status Timeline sort: changed_at ASC")

            let response = Response(status: .ok)
            try response.content.encode(updates)
            return response
        }

        app.get("api", "v1", "shift-handover", "log") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let observationRows = try await sql.raw("""
                SELECT
                    asset_records.id,
                    asset_records."captureTimestamp",
                    asset_records."sourceTag",
                    asset_records.lane_key,
                    asset_files."fileName"
                FROM asset_records
                INNER JOIN asset_files
                    ON asset_files."assetRecordID" = asset_records.id
            """).all()

            var logEntries: [ShiftHandoverLogEntry] = []

            for row in observationRows {
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let captureTimestamp = try row.decode(column: "captureTimestamp", as: String.self)
                let sourceTag = try row.decode(column: "sourceTag", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)
                let fileName = try row.decode(column: "fileName", as: String.self)

                logEntries.append(
                    ShiftHandoverLogEntry(
                        id: id,
                        sourceTag: sourceTag,
                        eventTimestamp: captureTimestamp,
                        entryType: "Observation Record",
                        message: "Observation record: \(fileName)",
                        laneKey: laneKey
                    )
                )
            }

            let decisionRows = try await sql.raw("""
                SELECT
                    id,
                    "standard_key",
                    "expected_window_start",
                    "expected_window_end",
                    "decision_type",
                    "source_tag",
                    "created_at",
                    lane_key
                FROM decision_traces
            """).all()

            for row in decisionRows {
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let standardKey = try row.decode(column: "standard_key", as: String.self)
                let expectedWindowStart = try row.decode(column: "expected_window_start", as: String.self)
                let expectedWindowEnd = try row.decode(column: "expected_window_end", as: String.self)
                let decisionType = try row.decode(column: "decision_type", as: String.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)
                let laneKey = try row.decode(column: "lane_key", as: String.self)

                logEntries.append(
                    ShiftHandoverLogEntry(
                        id: id,
                        sourceTag: sourceTag,
                        eventTimestamp: createdAt,
                        entryType: "Decision Trace",
                        message: "Decision trace: \(decisionType) — \(standardKey) — \(expectedWindowStart) to \(expectedWindowEnd)",
                        laneKey: laneKey
                    )
                )
            }

            let sortedLogEntries = logEntries.sorted { first, second in
                first.eventTimestamp > second.eventTimestamp
            }

            print("Shift Handover log retrieval PASS: \(sortedLogEntries.count) entries")
            print("Shift Handover sort: eventTimestamp DESC")
            print("Shift Handover source scope: [M] only")

            let response = Response(status: .ok)
            try response.content.encode(sortedLogEntries)
            return response
        }

        app.get("api", "v1", "files", ":fileName") { req async throws -> Response in
            guard let fileName = req.parameters.get("fileName") else {
                return Response(status: .badRequest)
            }

            let workingDirectory = app.directory.workingDirectory
            let storageDirectory = workingDirectory + "PayloadStorage"
            let filePath = storageDirectory + "/" + fileName

            guard FileManager.default.fileExists(atPath: filePath) else {
                print("File delivery failed: missing file \(fileName)")
                return Response(status: .notFound)
            }

            print("File delivery PASS: \(fileName)")
            return req.fileio.streamFile(at: filePath)
        }

        app.post("api", "v1", "assets", ":assetID", "payload-text") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Payload Text INSERT failed: invalid assetID")
                return Response(status: .badRequest)
            }

            let payload: PayloadTextRequest

            do {
                payload = try req.content.decode(PayloadTextRequest.self)
            } catch {
                print("Payload Text decode failed: \(error)")
                return Response(status: .badRequest)
            }

            let assetRows = try await sql.raw("""
                SELECT id
                FROM asset_records
                WHERE id = \(bind: assetID)
            """).all()

            guard assetRows.count == 1 else {
                print("Payload Text INSERT failed: asset not found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let payloadTextID = UUID()
            let createdAt = ISO8601DateFormatter().string(from: Date())

            do {
                try await sql.raw("""
                    INSERT INTO asset_payload_texts
                    (id, "assetRecordID", payload_text, source_tag, created_at)
                    VALUES
                    (\(bind: payloadTextID), \(bind: assetID), \(bind: payload.payloadText), \(bind: payload.sourceTag), \(bind: createdAt));
                """).run()
            } catch {
                print("Payload Text INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Payload Text INSERT PASS")
            print("assetRecordID: \(assetID.uuidString)")
            print("payloadTextID: \(payloadTextID.uuidString)")
            print("sourceTag: \(payload.sourceTag)")
            print("createdAt: \(createdAt)")
            print("Source Awareness: original asset unchanged; payload_text stored as subordinate representation")

            let response = Response(status: .ok)
            try response.content.encode(
                PayloadTextResponse(
                    id: payloadTextID.uuidString,
                    assetRecordID: assetID.uuidString,
                    payloadText: payload.payloadText,
                    sourceTag: payload.sourceTag,
                    createdAt: createdAt
                )
            )
            return response
        }

        app.get("api", "v1", "assets", ":assetID", "payload-text") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Payload Text retrieval failed: invalid assetID")
                return Response(status: .badRequest)
            }

            let rows = try await sql.raw("""
                SELECT
                    id,
                    "assetRecordID",
                    payload_text,
                    source_tag,
                    created_at
                FROM asset_payload_texts
                WHERE "assetRecordID" = \(bind: assetID)
                ORDER BY created_at ASC
            """).all()

            let payloadTexts = try rows.map { row -> PayloadTextResponse in
                let id = try row.decode(column: "id", as: UUID.self).uuidString
                let assetRecordID = try row.decode(column: "assetRecordID", as: UUID.self).uuidString
                let payloadText = try row.decode(column: "payload_text", as: String?.self)
                let sourceTag = try row.decode(column: "source_tag", as: String.self)
                let createdAt = try row.decode(column: "created_at", as: String.self)

                return PayloadTextResponse(
                    id: id,
                    assetRecordID: assetRecordID,
                    payloadText: payloadText,
                    sourceTag: sourceTag,
                    createdAt: createdAt
                )
            }

            print("Payload Text retrieval PASS: \(payloadTexts.count) entries")
            print("Source Awareness: payload_text returned separately from original asset media")

            let response = Response(status: .ok)
            try response.content.encode(payloadTexts)
            return response
        }

        app.post("api", "v1", "assets", ":assetID", "transcribe-audio") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            guard let assetIDString = req.parameters.get("assetID"),
                  let assetID = UUID(uuidString: assetIDString) else {
                print("Mechanical transcription failed: invalid assetID")
                return Response(status: .badRequest)
            }

            let assetRows = try await sql.raw("""
                SELECT id
                FROM asset_records
                WHERE id = \(bind: assetID)
            """).all()

            guard assetRows.count == 1 else {
                print("Mechanical transcription failed: asset not found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let fileRows = try await sql.raw("""
                SELECT "fileName"
                FROM asset_files
                WHERE "assetRecordID" = \(bind: assetID)
                ORDER BY "fileName" ASC
                LIMIT 1
            """).all()

            guard fileRows.count == 1 else {
                print("Mechanical transcription failed: no audio asset file found \(assetID.uuidString)")
                return Response(status: .notFound)
            }

            let fileName = try fileRows[0].decode(column: "fileName", as: String.self)
            let workingDirectory = app.directory.workingDirectory
            let storageDirectory = workingDirectory + "PayloadStorage"
            let filePath = storageDirectory + "/" + fileName
            let fileURL = URL(fileURLWithPath: filePath)

            guard FileManager.default.fileExists(atPath: filePath) else {
                print("Mechanical transcription failed: missing audio file \(fileName)")
                return Response(status: .notFound)
            }

            let sourceTag = "[S]"
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let transcriber = AppleSpeechTranscriber()
            let outcome: AppleSpeechTranscriber.TranscriptionOutcome

            do {
                outcome = try await transcriber.transcribeAudioFile(at: fileURL)
            } catch {
                print("Mechanical transcription honest error: \(error)")
                let response = Response(status: .internalServerError)
                try response.content.encode(
                    MechanicalTranscriptionResponse(
                        assetRecordID: assetID.uuidString,
                        payloadTextID: nil,
                        payloadText: nil,
                        sourceTag: sourceTag,
                        transcriptionStatus: "error",
                        reason: String(describing: error),
                        createdAt: createdAt
                    )
                )
                return response
            }

            let payloadTextID = UUID()
            let payloadText: String?
            let transcriptionStatus: String
            let reason: String?

            switch outcome {
            case .text(let text):
                payloadText = text
                transcriptionStatus = "text"
                reason = nil
            case .null(let nullReason):
                payloadText = nil
                transcriptionStatus = "null"
                reason = nullReason
            }

            do {
                try await sql.raw("""
                    INSERT INTO asset_payload_texts
                    (id, "assetRecordID", payload_text, source_tag, created_at)
                    VALUES
                    (\(bind: payloadTextID), \(bind: assetID), \(bind: payloadText), \(bind: sourceTag), \(bind: createdAt));
                """).run()
            } catch {
                print("Mechanical transcription payload_text INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Mechanical Voice Transcription PASS")
            print("assetRecordID: \(assetID.uuidString)")
            print("fileName: \(fileName)")
            print("payloadTextID: \(payloadTextID.uuidString)")
            print("transcriptionStatus: \(transcriptionStatus)")
            print("sourceTag: \(sourceTag)")
            print("createdAt: \(createdAt)")
            print("Source Awareness: original audio unchanged; Apple Speech output stored as subordinate payload_text")

            let response = Response(status: .ok)
            try response.content.encode(
                MechanicalTranscriptionResponse(
                    assetRecordID: assetID.uuidString,
                    payloadTextID: payloadTextID.uuidString,
                    payloadText: payloadText,
                    sourceTag: sourceTag,
                    transcriptionStatus: transcriptionStatus,
                    reason: reason,
                    createdAt: createdAt
                )
            )
            return response
        }

        app.post("api", "v1", "standards", "night-photo") { req async throws -> HTTPStatus in
            guard let sql = req.db as? SQLDatabase else {
                return .internalServerError
            }

            try await sql.raw("""
                INSERT INTO operational_standards (id, "standardKey", "description", "sourceTag", "startHour", "endHour", "requiredCount")
                SELECT
                    \(bind: UUID()),
                    \(bind: "night-photo-22-23"),
                    \(bind: "At least one photo between 22:00 and 23:00"),
                    \(bind: "[?]"),
                    \(bind: 22),
                    \(bind: 23),
                    \(bind: 1)
                WHERE NOT EXISTS (
                    SELECT 1 FROM operational_standards
                    WHERE "standardKey" = \(bind: "night-photo-22-23")
                );
            """).run()

            print("Operational standard fixation PASS: night-photo-22-23")
            return .ok
        }

        app.post("api", "v1", "decisions") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let payload: DecisionPayload

            do {
                payload = try req.content.decode(DecisionPayload.self)
            } catch {
                print("Decision payload decode failed: \(error)")
                return Response(status: .badRequest)
            }

            guard payload.decisionType == "leave_empty" else {
                print("Decision rejected: unsupported decisionType \(payload.decisionType)")
                return Response(status: .badRequest)
            }

            let decisionID = UUID()
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let sourceTag = "[M]"
            let inheritedLaneKey = "unassigned"

            do {
                try await sql.raw("""
                    INSERT INTO decision_traces
                    (id, "standard_key", "expected_window_start", "expected_window_end", "decision_type", "source_tag", "created_at", lane_key)
                    VALUES
                    (\(bind: decisionID), \(bind: payload.standardKey), \(bind: payload.expectedWindowStart), \(bind: payload.expectedWindowEnd), \(bind: payload.decisionType), \(bind: sourceTag), \(bind: createdAt), \(bind: inheritedLaneKey));
                """).run()
            } catch {
                print("Decision Trace INSERT failed: \(error)")
                return Response(status: .internalServerError)
            }

            print("Decision Trace fixation PASS")
            print("decisionID: \(decisionID.uuidString)")
            print("standardKey: \(payload.standardKey)")
            print("expectedWindowStart: \(payload.expectedWindowStart)")
            print("expectedWindowEnd: \(payload.expectedWindowEnd)")
            print("decisionType: \(payload.decisionType)")
            print("sourceTag: \(sourceTag)")
            print("createdAt: \(createdAt)")
            print("laneKey: \(inheritedLaneKey)")

            let response = Response(status: .ok)
            try response.content.encode([
                "id": decisionID.uuidString,
                "sourceTag": sourceTag,
                "decisionType": payload.decisionType,
                "standardKey": payload.standardKey,
                "expectedWindowStart": payload.expectedWindowStart,
                "expectedWindowEnd": payload.expectedWindowEnd,
                "createdAt": createdAt,
                "laneKey": inheritedLaneKey
            ])
            return response
        }

        app.get("api", "v1", "gaps", "mechanical") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }
            let requestedDate = req.query[String.self, at: "date"] ?? iso8601DateStringForToday()

            guard isValidISO8601DateString(requestedDate) else {
                let response = Response(status: .badRequest)
                try response.content.encode([
                    "reason": "date must use YYYY-MM-DD format"
                ])
                return response
            }
            let standards = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    "description",
                    "sourceTag",
                    "startHour",
                    "endHour",
                    "requiredCount",
                    created_at
                FROM operational_standards
                ORDER BY "standardKey" ASC
            """).all()

            var gaps: [[String: String]] = []

            let skippedTimestampRows = try await sql.raw(legacyTimestampSkipLogQuery(context: "Gap calculation")).all()
            for skippedRow in skippedTimestampRows {
                let skippedID = try skippedRow.decode(column: "id", as: UUID.self).uuidString
                let skippedTimestamp = try skippedRow.decode(column: "captureTimestamp", as: String.self)
                print("Legacy timestamp detected — skipping for Gap calculation")
                print("assetRecordID: \(skippedID)")
                print("captureTimestamp: \(skippedTimestamp)")
            }

            for standard in standards {
                let standardID = try standard.decode(column: "id", as: UUID.self)
                let standardKey = try standard.decode(column: "standardKey", as: String.self)
                let description = try standard.decode(column: "description", as: String.self)
                let sourceTag = try standard.decode(column: "sourceTag", as: String.self)
                let startHour = try standard.decode(column: "startHour", as: Int.self)
                let endHour = try standard.decode(column: "endHour", as: Int.self)
                let requiredCount = try standard.decode(column: "requiredCount", as: Int.self)
                let createdAt = try standard.decode(column: "created_at", as: String.self)
                let evaluationTimestamp = iso8601Timestamp(dateString: requestedDate, hour: endHour)
                let standardWasActive = try await isStandardActive(
                    standardID: standardID,
                    at: evaluationTimestamp,
                    createdAt: createdAt,
                    sql: sql
                )

                guard standardWasActive else {
                    print("Historical status resolution: standard inactive at gap evaluation time — skipping \(standardKey)")
                    continue
                }

                let countRows = try await sql.raw("""
                    SELECT COUNT(*) AS "recordCount"
                    FROM asset_records
                    WHERE "captureTimestamp" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
                      AND SUBSTRING("captureTimestamp" FROM 1 FOR 10) = \(bind: requestedDate)
                      AND CAST(SUBSTRING("captureTimestamp" FROM 12 FOR 2) AS INTEGER) >= \(bind: startHour)
                      AND CAST(SUBSTRING("captureTimestamp" FROM 12 FOR 2) AS INTEGER) < \(bind: endHour)
                """).all()

                let observedCount = try countRows[0].decode(column: "recordCount", as: Int.self)

                if observedCount < requiredCount {
                    let decisionRows = try await sql.raw("""
                        SELECT COUNT(*) AS "decisionCount"
                        FROM decision_traces
                        WHERE "standard_key" = \(bind: standardKey)
                          AND "expected_window_start" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
                          AND "expected_window_end" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
                          AND CAST(SUBSTRING("expected_window_start" FROM 12 FOR 2) AS INTEGER) = \(bind: startHour)
                          AND CAST(SUBSTRING("expected_window_end" FROM 12 FOR 2) AS INTEGER) = \(bind: endHour)
                          AND "decision_type" = 'leave_empty'
                          AND "source_tag" = '[M]'
                    """).all()

                    let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)

                    if decisionCount == 0 {
                        gaps.append([
                            "sourceTag": sourceTag,
                            "standardKey": standardKey,
                            "description": description,
                            "expectedDate": requestedDate,
                            "evaluationTimestamp": evaluationTimestamp,
                            "expectedWindow": String(format: "%02d:00-%02d:00", startHour, endHour),
                            "requiredCount": String(requiredCount),
                            "observedCount": String(observedCount),
                            "gapStatus": "Missing expected observation"
                        ])
                    }
                }
            }

            print("Mechanical gap detection PASS: \(gaps.count) gaps")

            let response = Response(status: .ok)
            try response.content.encode(gaps)
            return response
        }

        app.get("api", "v1", "state", "pulse") { req async throws -> Response in
            guard let sql = req.db as? SQLDatabase else {
                return Response(status: .internalServerError)
            }

            let gapsRows = try await sql.raw("""
                SELECT
                    id,
                    "standardKey",
                    "description",
                    "sourceTag",
                    "startHour",
                    "endHour",
                    "requiredCount",
                    created_at
                FROM operational_standards
                ORDER BY "standardKey" ASC
            """).all()

            var activeStandardsCount = 0
            var informationGapsCount = 0

            let skippedTimestampRows = try await sql.raw(legacyTimestampSkipLogQuery(context: "Pulse calculation")).all()
            for skippedRow in skippedTimestampRows {
                let skippedID = try skippedRow.decode(column: "id", as: UUID.self).uuidString
                let skippedTimestamp = try skippedRow.decode(column: "captureTimestamp", as: String.self)
                print("Legacy timestamp detected — skipping for Pulse calculation")
                print("assetRecordID: \(skippedID)")
                print("captureTimestamp: \(skippedTimestamp)")
            }

            for standard in gapsRows {
                let standardID = try standard.decode(column: "id", as: UUID.self)
                let standardKey = try standard.decode(column: "standardKey", as: String.self)
                let startHour = try standard.decode(column: "startHour", as: Int.self)
                let endHour = try standard.decode(column: "endHour", as: Int.self)
                let requiredCount = try standard.decode(column: "requiredCount", as: Int.self)
                let createdAt = try standard.decode(column: "created_at", as: String.self)
                let evaluationTimestamp = iso8601Timestamp(dateString: iso8601DateStringForToday(), hour: endHour)
                let standardWasActive = try await isStandardActive(
                    standardID: standardID,
                    at: evaluationTimestamp,
                    createdAt: createdAt,
                    sql: sql
                )

                guard standardWasActive else {
                    print("Historical status resolution: standard inactive at pulse evaluation time — skipping \(standardKey)")
                    continue
                }

                activeStandardsCount += 1

                let countRows = try await sql.raw("""
                    SELECT COUNT(*) AS "recordCount"
                    FROM asset_records
                    WHERE "captureTimestamp" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
                      AND CAST(SUBSTRING("captureTimestamp" FROM 12 FOR 2) AS INTEGER) >= \(bind: startHour)
                      AND CAST(SUBSTRING("captureTimestamp" FROM 12 FOR 2) AS INTEGER) < \(bind: endHour)
                """).all()

                let observedCount = try countRows[0].decode(column: "recordCount", as: Int.self)

                if observedCount < requiredCount {
                    let decisionRows = try await sql.raw("""
                        SELECT COUNT(*) AS "decisionCount"
                        FROM decision_traces
                        WHERE "standard_key" = \(bind: standardKey)
                          AND "expected_window_start" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
                          AND "expected_window_end" ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:'
                          AND CAST(SUBSTRING("expected_window_start" FROM 12 FOR 2) AS INTEGER) = \(bind: startHour)
                          AND CAST(SUBSTRING("expected_window_end" FROM 12 FOR 2) AS INTEGER) = \(bind: endHour)
                          AND "decision_type" = 'leave_empty'
                          AND "source_tag" = '[M]'
                    """).all()

                    let decisionCount = try decisionRows[0].decode(column: "decisionCount", as: Int.self)

                    if decisionCount == 0 {
                        informationGapsCount += 1
                        print("Open gap without Decision Trace: \(standardKey)")
                    } else {
                        print("Gap has Decision Trace and remains historically intact: \(standardKey)")
                    }
                }
            }

            let pulseState: String

            if activeStandardsCount == 0 {
                pulseState = "blue"
            } else if informationGapsCount > 0 {
                pulseState = "yellow"
            } else {
                pulseState = "green"
            }

            print("Mechanical pulse generation PASS")
            print("activeStandardsCount: \(activeStandardsCount)")
            print("informationGapsCount: \(informationGapsCount)")
            print("pulseState: \(pulseState)")
            print("sourceTag: [S]")

            let response = Response(status: .ok)
            try response.content.encode([
                "pulseState": pulseState,
                "sourceTag": "[S]"
            ])
            return response
        }

        print("AIHOS Asset Server starting")

        try await app.execute()
    }
}

// Migration for Lane Metadata Foundation
struct CreateLaneMetadataFoundation: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for lane metadata migration")
        }
        // 1. Add lane_key to asset_records
        try await sql.raw("""
            ALTER TABLE asset_records ADD COLUMN IF NOT EXISTS lane_key TEXT NOT NULL DEFAULT 'unassigned';
        """).run()
        // 2. Add lane_key to decision_traces
        try await sql.raw("""
            ALTER TABLE decision_traces ADD COLUMN IF NOT EXISTS lane_key TEXT NOT NULL DEFAULT 'unassigned';
        """).run()
        // 3. Set lane_key to 'unassigned' where NULL in asset_records
        try await sql.raw("""
            UPDATE asset_records SET lane_key = 'unassigned' WHERE lane_key IS NULL;
        """).run()
        // 4. Set lane_key to 'unassigned' where NULL in decision_traces
        try await sql.raw("""
            UPDATE decision_traces SET lane_key = 'unassigned' WHERE lane_key IS NULL;
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for lane metadata migration revert")
        }
        // Drop lane_key from decision_traces and asset_records if exists
        try await sql.raw("""
            ALTER TABLE decision_traces DROP COLUMN IF EXISTS lane_key;
        """).run()
        try await sql.raw("""
            ALTER TABLE asset_records DROP COLUMN IF EXISTS lane_key;
        """).run()
    }
}
