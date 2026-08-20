import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-B: the production source layout after the library/runner split
//
// Order WFOS-20260818-PSKS-011, binding correction GS-4.
//
// F-B split the server into a library target that holds all behaviour and an
// executable target that holds nothing but the entry point. That split is what made
// `swift test -c release` possible: a module with a program entry point cannot be
// imported by the test bundle.
//
// A split is also the classic way for a file to end up outside the safety net, so the
// layout itself is pinned here: the library must still be exactly its two files, the
// runner must exist where it is expected, and the runner must stay an entry point
// rather than becoming a second, untested home for logic.
//
// The runner's text is deliberately not duplicated in a literal. Asserting structural
// properties keeps the test stable when a comment is reworded.

@Suite("F-B production source layout")
struct ProductionSourceLayoutTests {

    @Test("The library target is exactly its twenty-four files, in the unchanged directory")
    func libraryLayoutUnchanged() throws {
        let module = try serverModuleSourceTexts()

        // F-C1, F-C2 and F-C3 each added a file by extraction. The set is pinned rather
        // than counted so a further file cannot appear unnoticed.
        #expect(module.map(\.name) == [
            "AIHOSAssetServer.swift",
            "APIContentDTOs.swift",
            "DatabaseHealthRoutes.swift",
            "FileDeliveryRoutes.swift",
            "ImmutabilityDiagnosticRoutes.swift",
            "LaneValidationHelpers.swift",
            "MachineAuthGate.swift",
            "MechanicalGapReadRoutes.swift",
            "NightPhotoStandardRoutes.swift",
            "ObservationDecisionTraceReadRoutes.swift",
            "ObservationRecordReadRoutes.swift",
            "ObservationWindowHelpers.swift",
            "OperationalPulseReadRoutes.swift",
            "OperationalStandardHelpers.swift",
            "OperationalStandardReadRoutes.swift",
            "OperationsTimeHelpers.swift",
            "PayloadTextReadRoutes.swift",
            "RuntimeConfigurationHelpers.swift",
            "SchemaMigrations.swift",
            "ShiftHandoverReadRoutes.swift",
            "StandardStatusTimelineReadRoutes.swift",
            "TimestampDiagnostics.swift",
            "TimestampFormattingHelpers.swift",
            "TriggerMigrations.swift"
        ])
        #expect(serverModuleDirectoryURL.lastPathComponent == "AIHOSAssetServer")
    }

    @Test("Sources holds exactly the two known target directories")
    func sourcesSubdirectoriesArePinned() throws {
        // GS-6: enumerated mechanically, so the next target directory cannot fall
        // silently outside the safety net the way a new file inside a scanned
        // directory never could.
        #expect(try sourcesSubdirectoryNames() == ["AIHOSAssetServer", "AIHOSAssetServerRun"])
    }

    @Test("Every production source across both targets is inside the scan")
    func productionScanCoversAllFour() throws {
        #expect(try productionSourceTexts().map(\.name) == [
            "AIHOSAssetServer.swift",
            "APIContentDTOs.swift",
            "DatabaseHealthRoutes.swift",
            "FileDeliveryRoutes.swift",
            "ImmutabilityDiagnosticRoutes.swift",
            "LaneValidationHelpers.swift",
            "MachineAuthGate.swift",
            "MechanicalGapReadRoutes.swift",
            "NightPhotoStandardRoutes.swift",
            "ObservationDecisionTraceReadRoutes.swift",
            "ObservationRecordReadRoutes.swift",
            "ObservationWindowHelpers.swift",
            "OperationalPulseReadRoutes.swift",
            "OperationalStandardHelpers.swift",
            "OperationalStandardReadRoutes.swift",
            "OperationsTimeHelpers.swift",
            "PayloadTextReadRoutes.swift",
            "RuntimeConfigurationHelpers.swift",
            "SchemaMigrations.swift",
            "ShiftHandoverReadRoutes.swift",
            "StandardStatusTimelineReadRoutes.swift",
            "TimestampDiagnostics.swift",
            "TimestampFormattingHelpers.swift",
            "TriggerMigrations.swift",
            "main.swift"
        ])
    }

    @Test("The locked main file resolves at its original path")
    func mainFilePathUnchanged() throws {
        // ServerSourceInventory must keep finding the file without a path change: every
        // A0/A1a/A1b characterization test reads through it.
        #expect(serverSourceURL.path.hasSuffix("Sources/AIHOSAssetServer/AIHOSAssetServer.swift"))
        #expect(FileManager.default.fileExists(atPath: serverSourceURL.path))
        #expect(try serverSourceText().isEmpty == false)
    }

    @Test("The runner exists at the expected path and is one file")
    func runnerExists() throws {
        let runner = try runnerSourceTexts()

        #expect(runnerDirectoryURL.lastPathComponent == "AIHOSAssetServerRun")
        #expect(runner.map(\.name) == ["main.swift"])
    }

    @Test("The runner is a minimal start adapter and nothing more")
    func runnerIsMinimal() throws {
        let runner = try #require(try runnerSourceTexts().first)
        let lines = executableLines(in: runner.text)

        // Two statements: import the library, start the server. The bound is loose
        // enough to survive formatting and tight enough that logic cannot hide here.
        #expect(lines.count <= 4, "Runner has grown beyond an entry point: \(lines)")
        #expect(lines.contains("import AIHOSAssetServer"))
        #expect(lines.contains { $0.contains("AIHOSAssetServer.main()") })
    }

    @Test("No server behaviour may live in the runner")
    func runnerCarriesNoLogic() throws {
        let runner = try runnerSourceTexts()

        // Each of these would mean production code that no test can reach — the exact
        // situation the split was made to end.
        for forbidden in [
            #"\bapp\.(get|post|put|patch|delete|on|group|grouped)\("#,
            #"\bsql\.raw\("#,
            #"\bSELECT\b|\bINSERT\b|\bUPDATE\b|\bDELETE FROM\b"#,
            #"MachineAuthGate|MachineGatedRoutes|MachineCredential"#,
            #"AsyncMigration|migrations\.add"#,
            #"Environment\.get\("#
        ] {
            let hits = matchCount(ofPattern: forbidden, options: [.regularExpression], in: runner)
            #expect(hits == 0, "Runner contains server logic matching \(forbidden): \(hits) hit(s)")
        }
    }

    @Test("The entry point lives only in the runner, never in the library")
    func entryPointOnlyInRunner() throws {
        // This is what lets the test bundle import the library at all. If `@main` ever
        // comes back into the module, `swift test -c release` breaks again.
        #expect(matchCount(ofPattern: #"^@main\b"#, options: [.regularExpression], in: try serverModuleSourceTexts()) == 0)

        let library = try serverSourceText()
        #expect(library.contains("public struct AIHOSAssetServer {"))
        #expect(library.contains("public static func main() async throws {"))
    }

    @Test("The module's public surface stays the type and its start access only")
    func publicSurfaceIsMinimal() throws {
        let module = try serverModuleSourceTexts()

        // Exactly two public declarations, both in the split's remit. Making a
        // migration, DTO or Content type public would widen the module's contract well
        // beyond what the runner needs.
        //
        // GS-7: matched wherever `public` stands in the declaration, not only at line
        // start, so `final public func` or an attribute in front of it cannot widen the
        // surface without failing here.
        let declarations = publicDeclarations(in: module)

        #expect(declarations == [
            "public struct AIHOSAssetServer {",
            "public static func main() async throws {"
        ], "Public surface widened: \(declarations)")
    }
}
