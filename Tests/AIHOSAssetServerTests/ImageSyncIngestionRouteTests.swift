import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-H2: the image sync ingestion route, and the end of the route series
//
// Order WFOS-20260821-PSKS-005. `POST /api/v1/sync` moved from main() into
// Sources/AIHOSAssetServer/ImageSyncIngestionRoutes.swift. It is the last route to
// leave the composition root.
//
// WHY THESE TESTS
//   This is the primary ingest path — the route by which most observations enter the
//   record at all. It shares four properties with /audio (rejections before the write,
//   a refused millisecond timestamp, shared observation identity, a two-sided rollback)
//   and adds one of its own: a deliberate forced-failure branch used to prove rollback
//   against a real database.
//
//   That branch is the thing worth guarding most carefully. It is a test door into the
//   primary ingest path, and it is safe only because it is exactly one full-equality
//   comparison against one literal file name. Widening it to a prefix, a suffix, a
//   contains-check or an environment flag would turn it into a way to corrupt real
//   ingestion — and every one of those would compile.

private let routeFileName = "ImageSyncIngestionRoutes.swift"

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

@Suite("F-H2 image sync ingestion route extraction")
struct ImageSyncIngestionRouteTests {

    // MARK: Placement, and the end state of the series

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.on(.POST, "sync", body: .collect(maxSize: "10mb"))"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the sync ingestion route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerImageSyncIngestionRoutes(on: apiV1, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    @Test("The composition root now registers no route of any kind")
    func compositionRootIsFreeOfRoutes() throws {
        // The end state of the whole F series, asserted from this side too: main()
        // resolves configuration, runs migrations and calls registrars. Every route
        // lives in a route file, and the full manifest still holds 21 of them.
        #expect(parseRouteRegistrations(inSource: try serverSourceText()).isEmpty)
        #expect(parseRouteRegistrations(inSource: try serverModuleSourceText()).count == 21)

        // The boot-time gate coverage check stays where it runs once.
        #expect(try serverSourceText().contains("try verifyMachineGateCoverage(routes: app.routes.all)"))
    }

    @Test("/audio stays in its own file and the two payload types are not mixed")
    func audioIsSeparate() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"apiV1.on(.POST, "audio""#) == false,
                "/audio was absorbed into \(routeFileName)")
        #expect(code.contains("MultipartSyncPayload"))
        #expect(code.contains("MultipartAudioPayload") == false)
    }

    // MARK: Dependencies and limits

    @Test("The registrar takes the group and storageDirectory, and the 10 MB limit is kept")
    func registrarAndLimitArePinned() throws {
        #expect(try routeFileText().contains(
            "func registerImageSyncIngestionRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {"
        ))

        let codeLines = try routeFileCodeLines()
        let code = codeLines.joined(separator: "\n")

        #expect(code.contains(#"body: .collect(maxSize: "10mb")"#))
        #expect(code.contains(#""20mb""#) == false, "The image route picked up the audio body limit")

        for lookup in ["Environment.get", "STORAGE_PATH", "resolvedStorageDirectory",
                       "OPERATIONS_TIMEZONE", "operationsTimeZone", "AIHOS_"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }
        for declaration in ["var ", "let ", "struct ", "actor "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }
        #expect(codeLines.filter { $0.hasPrefix("func ") }.count == 1,
                "A helper was declared alongside the registrar in \(routeFileName)")
    }

    // MARK: Nothing is written until everything is accepted

    @Test("Every rejection runs before the file is written and before the transaction")
    func rejectionsPrecedeAnyWrite() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        for rejection in [
            #"print("Multipart parsing failed: \(error)")"#,
            #"print("Metadata decode failed: \(error)")"#,
            #"print("Capture timestamp rejected: not a 10-digit Unix epoch in seconds")"#,
            #"print("Lane validation failed")"#,
            #"print("Invalid observationID received: \(rawObservationID)")"#
        ] {
            #expect(code.contains(rejection), "Rejection reason changed or missing: \(rejection)")
        }
        #expect(code.components(separatedBy: "return .badRequest").count - 1 == 5)

        let idGuard = try #require(code.range(of: "guard let parsedObservationID = UUID(uuidString: rawObservationID)")?.lowerBound)
        let fileWrite = try #require(code.range(of: "try Data(buffer: payload.image.data).write(to:")?.lowerBound)
        let transaction = try #require(code.range(of: "try await req.db.transaction { database in")?.lowerBound)

        #expect(idGuard < fileWrite, "A malformed observation id is accepted before the file is written")
        #expect(fileWrite < transaction)

        #expect(code.contains("guard isCanonicalCaptureTimestamp(metadata.captureTimestamp) else {"))
        let tsGuard = try #require(code.range(of: "isCanonicalCaptureTimestamp(metadata.captureTimestamp)")?.lowerBound)
        #expect(tsGuard < fileWrite)
        for normalising in ["/ 1000", "* 1000", "dropLast(3)", "prefix(10)"] {
            #expect(code.contains(normalising) == false,
                    "A millisecond timestamp is normalised instead of refused: \(normalising)")
        }
    }

    // MARK: The forced-failure test door

    @Test("The forced-failure branch is exactly one full-equality match on one literal name")
    func forcedFailureDoorStaysNarrow() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        // Full equality against one literal, evaluated once, from the stored file name.
        #expect(code.contains(
            #"let forceTransactionalFailure = storedFileName == "test-force-transaction-failure.jpg""#
        ))
        #expect(code.components(separatedBy: "test-force-transaction-failure.jpg").count - 1 == 1,
                "The reserved name appears more than once")
        #expect(code.components(separatedBy: "forceTransactionalFailure").count - 1 == 2,
                "The flag is read somewhere other than its single branch")

        // None of these would be caught by the compiler, and each widens a test door
        // into the primary ingest path.
        for widening in [
            "forceTransactionalFailure =", "hasPrefix(\"test-force", "hasSuffix(\"test-force",
            "contains(\"test-force", "Environment.get(\"FORCE", "AIHOS_FORCE"
        ] where widening != #"let forceTransactionalFailure = storedFileName == "test-force-transaction-failure.jpg""# {
            let hits = code.components(separatedBy: widening).count - 1
            let allowed = widening == "forceTransactionalFailure =" ? 1 : 0
            #expect(hits == allowed, "The forced-failure door was widened: \(widening)")
        }

        // What the branch does: insert a file row against a record id that was never
        // created, so the foreign key fails and the transaction rolls back.
        #expect(code.contains(#"print("Intentional transactional failure requested")"#))
        #expect(code.contains("let missingRecordID = UUID()"))
        #expect(code.contains(#"VALUES (\(bind: fileID), \(bind: missingRecordID), \(bind: storedFileName));"#))

        // And it is inside the transaction, so the whole unit is what fails.
        let transaction = try #require(code.range(of: "try await req.db.transaction { database in")?.lowerBound)
        let branch = try #require(code.range(of: "if forceTransactionalFailure {")?.lowerBound)
        #expect(transaction < branch, "The forced failure runs outside the transaction it is meant to fail")
    }

    // MARK: Shared identity and the two-sided rollback

    @Test("A repeated observation id joins the existing observation")
    func sharedObservationIdentityIsPreserved() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("let recordID = sharedObservationID ?? UUID()"))
        #expect(code.contains("ON CONFLICT (id) DO NOTHING;"))
        #expect(code.contains(#"print("SHARED OBSERVATION IDENTITY: NEW asset_record CREATED: \(recordID.uuidString)")"#))
        #expect(code.contains(#"print("SHARED OBSERVATION IDENTITY: EXISTING asset_record REUSED: \(recordID.uuidString)")"#))
    }

    @Test("A failed transaction deletes the file already written, and says so")
    func rollbackIsTwoSided() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains("try FileManager.default.removeItem(atPath: storedFilePath)"))
        #expect(code.contains(#"print("Rollback cleanup PASS: saved payload file deleted")"#))
        #expect(code.contains(#"print("Rollback cleanup PASS: no saved payload file found")"#))
        #expect(code.contains(#"print("Rollback cleanup FAILED: saved payload file could not be deleted: \(error)")"#))
        #expect(code.contains(#"print("Transactional payload fixation failed: \(error)")"#))
        #expect(code.contains("return .internalServerError"))
    }

    @Test("The transaction contents and the default extension are unchanged")
    func transactionContentsAreUnchanged() throws {
        let code = try routeFileCodeLines().joined(separator: "\n")

        #expect(code.contains(#"INSERT INTO asset_records (id, "captureTimestamp", "sourceTag", lane_key)"#))
        #expect(code.contains(#"INSERT INTO asset_files (id, "assetRecordID", "fileName")"#))
        #expect(code.contains("INSERT INTO asset_payload_texts"))
        #expect(code.contains("let resolvedPayloadText = payload.payloadText ?? metadata.payloadText"))
        #expect(code.contains(#"let payloadTextSourceTag = metadata.payloadTextSourceTag ?? "[S]""#))

        // .jpg here, .m4a in the audio route.
        #expect(code.contains(#"let storedFileName = metadata.fileName ?? "\(UUID().uuidString).jpg""#))
        #expect(code.contains(#"print("[M] Payload fixed transactionally. Tid: \(metadata.captureTimestamp). Bildstorlek: \(imageSize) bytes.")"#))
        #expect(code.contains("return .ok"))
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        let mutated = try routeFileText()
            .replacingOccurrences(of: #"storedFileName == "test-force-transaction-failure.jpg""#,
                                  with: #"storedFileName.hasPrefix("test-force")"#)

        #expect(mutated.contains(#"storedFileName == "test-force-transaction-failure.jpg""#) == false)
        #expect(try routeFileText().contains(#"storedFileName == "test-force-transaction-failure.jpg""#))
    }
}
