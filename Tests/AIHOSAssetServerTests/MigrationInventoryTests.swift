import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - AC-5: migration inventory and registration order
//
// Atom SERVER-MOD-A0 (WFOS-20260817-PSKS-020), binding correction GS-C2.
//
// BASELINE, STATED EXACTLY: 12 `AsyncMigration` types and 12 `app.migrations.add`
// registrations. The figure of 14 in WFOS-20260817-KSPS-021 was a miscount; 12 is
// verified here and asserted mechanically.
//
// WHY NAMES AND ORDER ARE PINNED AS STRING LITERALS
//   Fluent records applied migrations by TYPE NAME in `_fluent_migrations`. Renaming a
//   migration type makes Fluent treat it as new and run `prepare` again against
//   production data; reordering the `add` calls changes execution order. Neither is
//   caught by the compiler, and both are exactly the kind of tidy-up a refactor
//   invites. The literals below are the tripwire.
//
// SCOPE: no database is contacted and no migration is executed here. The local-database
// zero-apply proof (GS-C9(b)) belongs to atom A4, not to this test grounding.

/// The 12 registrations in `AIHOSAssetServer.main()`, in exact execution order.
///
/// Note that registration order already differs from declaration order:
/// `ActivateDecisionTraceGovernanceTriggers` is registered seventh but declared near
/// the end of the file, and `CreateLaneMetadataFoundation` is registered ninth but
/// declared last. Registration order is the only order that matters.
private let expectedMigrationRegistrationOrder: [String] = [
    "CreateAssetRecords",
    "CreateSubordinateTracks",
    "CreateOperationalStandards",
    "AddOperationalStandardsGovernanceFields",
    "CreateDecisionTraces",
    "AddObservationDecisionTraceTarget",
    "ActivateDecisionTraceGovernanceTriggers",
    "CreatePayloadTextStorage",
    "CreateLaneMetadataFoundation",
    "CreateGovernanceTriggers",
    "ActivateOperationalStandardsGovernanceTriggers",
    "CreateStandardStatusUpdates"
]

/// Miniature registration block used to prove the parser can fail.
private let migrationFixture = """
        app.migrations.add(CreateAssetRecords())
        app.migrations.add(CreateSubordinateTracks())
        app.migrations.add(CreateOperationalStandards())
"""

private let migrationFixtureOrder = ["CreateAssetRecords", "CreateSubordinateTracks", "CreateOperationalStandards"]

@Suite("Migration inventory and order")
struct MigrationInventoryTests {

    @Test("Exactly 12 migrations are registered, in exactly the pinned order")
    func registrationOrderIsExact() throws {
        let registrations = parseMigrationRegistrations(inSource: try serverSourceText())

        #expect(registrations.count == 12, "Found \(registrations.count) registrations: \(registrations)")
        #expect(registrations == expectedMigrationRegistrationOrder)
    }

    @Test("Exactly 12 AsyncMigration types are declared and they are the registered ones")
    func declaredTypesMatchRegistrations() throws {
        let declared = declaredStructNames(conformingTo: "AsyncMigration", inSource: try serverSourceText())

        #expect(declared.count == 12, "Declared migration types: \(declared.count) — \(declared)")
        #expect(Set(declared) == Set(expectedMigrationRegistrationOrder))
    }

    @Test("Declaration order deliberately differs from registration order")
    func declarationOrderDiffersFromRegistrationOrder() throws {
        let source = try serverSourceText()
        let declared = declaredStructNames(conformingTo: "AsyncMigration", inSource: source)
        let registered = parseMigrationRegistrations(inSource: source)

        // Pinned so nobody "fixes" the file layout and assumes the order followed it.
        #expect(declared != registered)
        #expect(declared.last == "CreateLaneMetadataFoundation")
        #expect(registered.last == "CreateStandardStatusUpdates")
    }

    @Test("Every registration is a distinct migration")
    func registrationsAreUnique() throws {
        let registrations = parseMigrationRegistrations(inSource: try serverSourceText())

        #expect(Set(registrations).count == registrations.count,
                "Duplicate migration registration: \(duplicatedSignatures(in: registrations))")
    }

    // MARK: Negative controls

    @Test("Positive control: the parser reads a known registration block")
    func parserReadsRegistrations() {
        #expect(parseMigrationRegistrations(inSource: migrationFixture) == migrationFixtureOrder)
    }

    @Test("Negative control: a renamed migration is detected")
    func renamedMigrationIsDetected() {
        let mutated = migrationFixture.replacingOccurrences(
            of: "CreateSubordinateTracks",
            with: "CreateSubordinateTrackTables"
        )

        let parsed = parseMigrationRegistrations(inSource: mutated)

        #expect(parsed != migrationFixtureOrder)
        #expect(parsed == ["CreateAssetRecords", "CreateSubordinateTrackTables", "CreateOperationalStandards"])
    }

    @Test("Negative control: a reordered registration is detected even though the set is unchanged")
    func reorderedMigrationIsDetected() {
        let mutated = """
                app.migrations.add(CreateSubordinateTracks())
                app.migrations.add(CreateAssetRecords())
                app.migrations.add(CreateOperationalStandards())
        """

        let parsed = parseMigrationRegistrations(inSource: mutated)

        // The set comparison stays clean — order is the only thing that catches this,
        // which is why the primary assertion above compares arrays and not sets.
        #expect(Set(parsed) == Set(migrationFixtureOrder))
        #expect(parsed != migrationFixtureOrder)
    }

    @Test("Negative control: a removed registration is detected")
    func removedMigrationIsDetected() {
        let mutated = migrationFixture.replacingOccurrences(
            of: "        app.migrations.add(CreateOperationalStandards())",
            with: ""
        )

        #expect(parseMigrationRegistrations(inSource: mutated).count == 2)
    }
}
