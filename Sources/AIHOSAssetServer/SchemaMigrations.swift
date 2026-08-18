import Fluent
import SQLKit
import Vapor

// MARK: - Schema and data migrations
//
// The tables, columns and constraints AIHOS stores its records in. Extracted verbatim
// from AIHOSAssetServer.swift by F-D1 — no name, SQL, schema field, prepare/revert
// body or ordering changed.
//
// Two rules govern this file and neither is a matter of taste:
//   1. A migration type name is its identity. Fluent records applied migrations by
//      type name in `_fluent_migrations`, so renaming one makes Fluent treat it as new
//      and run `prepare` again against production data.
//   2. Execution order is decided solely by the `app.migrations.add(...)` sequence in
//      the composition root, never by the order of declarations here.
//
// The three governance-trigger migrations deliberately stayed in AIHOSAssetServer.swift.
// They create the append-only and immutability triggers rather than schema, and belong
// with the governance concern rather than with table definitions.

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

struct AddObservationDecisionTraceTarget: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for observation decision trace target migration")
        }

        try await sql.raw("""
            ALTER TABLE decision_traces
            ADD COLUMN IF NOT EXISTS target_asset_record_id UUID NULL;
        """).run()

        try await sql.raw("""
            ALTER TABLE decision_traces
            ALTER COLUMN "standard_key" DROP NOT NULL;
        """).run()

        try await sql.raw("""
            ALTER TABLE decision_traces
            ALTER COLUMN "expected_window_start" DROP NOT NULL;
        """).run()

        try await sql.raw("""
            ALTER TABLE decision_traces
            ALTER COLUMN "expected_window_end" DROP NOT NULL;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1
                    FROM pg_constraint
                    WHERE conname = 'decision_traces_target_asset_record_id_fkey'
                ) THEN
                    ALTER TABLE decision_traces
                    ADD CONSTRAINT decision_traces_target_asset_record_id_fkey
                    FOREIGN KEY (target_asset_record_id)
                    REFERENCES asset_records(id);
                END IF;
            END $$;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1
                    FROM pg_constraint
                    WHERE conname = 'decision_traces_exactly_one_target_check'
                ) THEN
                    ALTER TABLE decision_traces
                    ADD CONSTRAINT decision_traces_exactly_one_target_check
                    CHECK (
                        (
                            "standard_key" IS NOT NULL
                            AND target_asset_record_id IS NULL
                        )
                        OR
                        (
                            "standard_key" IS NULL
                            AND target_asset_record_id IS NOT NULL
                        )
                    );
                END IF;
            END $$;
        """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable for observation decision trace target migration revert")
        }

        try await sql.raw("""
            ALTER TABLE decision_traces
            DROP CONSTRAINT IF EXISTS decision_traces_exactly_one_target_check;
        """).run()

        try await sql.raw("""
            ALTER TABLE decision_traces
            DROP CONSTRAINT IF EXISTS decision_traces_target_asset_record_id_fkey;
        """).run()

        try await sql.raw("""
            ALTER TABLE decision_traces
            DROP COLUMN IF EXISTS target_asset_record_id;
        """).run()
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
