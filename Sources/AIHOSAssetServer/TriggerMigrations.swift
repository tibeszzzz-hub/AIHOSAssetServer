import Fluent
import SQLKit
import Vapor

// MARK: - Governance trigger migrations
//
// The database-level guarantees AIHOS records rest on: asset_records immutable,
// asset_events, asset_payload_texts, decision_traces and standard_status_updates
// append-only, and operational_standards updatable in status only. Extracted verbatim
// from AIHOSAssetServer.swift by F-D2 — no SQL, trigger function, prepare/revert body,
// type name or semantics changed.
//
// These are the invariants that make the audit trail worth trusting. They live in the
// database rather than in Swift precisely so that no code path, present or future, can
// route around them.
//
// Every CREATE TRIGGER here is preceded by DROP TRIGGER IF EXISTS (F-A). Without that,
// running a migration against a database that already has the triggers fails with
// Postgres 42710 and blocks boot. That protection moved with the statements it guards.
//
// As with SchemaMigrations.swift: the type name is the identity Fluent records in
// _fluent_migrations, and execution order comes solely from the app.migrations.add
// sequence in the composition root.

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
        DROP TRIGGER IF EXISTS prevent_asset_records_update ON asset_records;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_records_update
        BEFORE UPDATE ON asset_records
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_record_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_asset_records_delete ON asset_records;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_records_delete
        BEFORE DELETE ON asset_records
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_record_delete();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_asset_events_update ON asset_events;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_asset_events_update
        BEFORE UPDATE ON asset_events
        FOR EACH ROW
        EXECUTE FUNCTION prevent_asset_event_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_asset_events_delete ON asset_events;
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
        DROP TRIGGER IF EXISTS prevent_decision_traces_update ON decision_traces;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_decision_traces_update
        BEFORE UPDATE ON decision_traces
        FOR EACH ROW
        EXECUTE FUNCTION prevent_decision_trace_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_decision_traces_delete ON decision_traces;
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

// Migration for Lane Metadata Foundation
// Migration to activate governance triggers for decision_traces (append-only)
struct ActivateDecisionTraceGovernanceTriggers: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for decision trace governance activation")
        }

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

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_decision_traces_update ON decision_traces;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_decision_traces_update
        BEFORE UPDATE ON decision_traces
        FOR EACH ROW
        EXECUTE FUNCTION prevent_decision_trace_update();
        """).run()

        try await sql.raw("""
        DROP TRIGGER IF EXISTS prevent_decision_traces_delete ON decision_traces;
        """).run()

        try await sql.raw("""
        CREATE TRIGGER prevent_decision_traces_delete
        BEFORE DELETE ON decision_traces
        FOR EACH ROW
        EXECUTE FUNCTION prevent_decision_trace_delete();
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for decision trace governance activation revert")
        }

        try await sql.raw("DROP TRIGGER IF EXISTS prevent_decision_traces_delete ON decision_traces;").run()
        try await sql.raw("DROP TRIGGER IF EXISTS prevent_decision_traces_update ON decision_traces;").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_decision_trace_delete();").run()
        try await sql.raw("DROP FUNCTION IF EXISTS prevent_decision_trace_update();").run()
    }
}
