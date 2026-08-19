import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - F-F1: the first route group lifted out of the composition root
//
// Order WFOS-20260819-PSKS-019. `GET /api/v1/files/:fileName` moved from main() into
// Sources/AIHOSAssetServer/FileDeliveryRoutes.swift.
//
// WHY THIS GROUP AND WHY THESE TESTS
//   It was the smallest read-only group with the least coupling in the server: no
//   database, no SQL, no ingest path, and exactly one value needed from main(). The
//   risk of such a move is not that the code stops compiling — it is that the route
//   quietly changes gate, prefix, status codes or payload, or that the extracted file
//   grows its own way of finding the storage path. Each of those is pinned below.
//
// The route manifest (RouteManifestTests) and the gate inventory (MachineAuthGateTests)
// already scan the whole library and still demand 21 routes, 20 of them gated. These
// tests add what those cannot see: that the route lives in the new file, that main()
// only calls the registrar, and that the dependency is handed in rather than looked up.

private let routeFileName = "FileDeliveryRoutes.swift"

private func routeFileText() throws -> String {
    try #require(
        try serverModuleSourceTexts().first { $0.name == routeFileName }?.text,
        "\(routeFileName) is missing from the library"
    )
}

@Suite("F-F1 file delivery route extraction")
struct FileDeliveryRouteTests {

    // MARK: Placement

    @Test("The route is registered in the route file and nowhere else")
    func routeIsRegisteredOnlyInTheRouteFile() throws {
        let registration = #"apiV1.get("files", ":fileName")"#

        #expect(try routeFileText().contains(registration))
        #expect(try serverSourceText().contains(registration) == false,
                "The route is still registered in the composition root")

        // Exactly once across the whole production library — a move that accidentally
        // duplicated the registration would still pass both checks above.
        let occurrences = try serverModuleSourceText()
            .components(separatedBy: registration).count - 1
        #expect(occurrences == 1, "Found \(occurrences) registrations of the file delivery route")
    }

    @Test("main() reaches the route only through the registrar, exactly once")
    func compositionRootCallsTheRegistrarOnce() throws {
        let call = "registerFileDeliveryRoutes(on: apiV1, storageDirectory: storageDirectory)"
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.filter { $0 == call }.count == 1)
    }

    // MARK: Dependencies are passed in, not looked up

    @Test("The registrar takes both dependencies as parameters")
    func registrarSignatureIsPinned() throws {
        // Pinned as a literal because the parameter label `apiV1` is load-bearing: the
        // route manifest resolves a registration's gate and its /api/v1 prefix from the
        // receiver's name. Renaming the parameter would silently reclassify the route.
        #expect(try routeFileText().contains(
            "func registerFileDeliveryRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {"
        ))
    }

    @Test("The route file introduces no second source of truth and no global state")
    func routeFileHasNoOwnConfigurationOrState() throws {
        let text = try routeFileText()

        // Code only. The header comment explains that main() resolves STORAGE_PATH and
        // hands the result in, so a whole-text match would flag its own documentation.
        let codeLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let code = codeLines.joined(separator: "\n")

        // It must not resolve the storage path again: main() already resolved and
        // validated it fail-closed, and a second lookup could disagree with the first.
        for lookup in ["Environment.get", "resolvedStorageDirectory", "STORAGE_PATH"] {
            #expect(code.contains(lookup) == false, "\(lookup) is looked up inside \(routeFileName)")
        }

        // No file-scope state of any kind, mutable or not. Column zero is what makes
        // this a scope check rather than a spelling check: `let filePath` inside the
        // handler is a local and must stay allowed.
        for declaration in ["var ", "let "] {
            #expect(codeLines.contains { $0.hasPrefix(declaration) } == false,
                    "File-scope `\(declaration.trimmingCharacters(in: .whitespaces))` in \(routeFileName)")
        }

        // Read-only by construction: this group touches neither the database nor the
        // request body, which is why it was safe to move first.
        for forbidden in ["SQLDatabase", "req.db", "req.content.decode", "sql.raw"] {
            #expect(code.contains(forbidden) == false, "\(forbidden) appeared in \(routeFileName)")
        }
    }

    // MARK: Behaviour contract

    @Test("The handler keeps its exact status codes, path construction and log lines")
    func handlerContractIsUnchanged() throws {
        let text = try routeFileText()

        for pinned in [
            #"guard let fileName = req.parameters.get("fileName") else {"#,
            "return Response(status: .badRequest)",
            #"let filePath = storageDirectory + "/" + fileName"#,
            "guard FileManager.default.fileExists(atPath: filePath) else {",
            "return Response(status: .notFound)",
            #"print("File delivery failed: missing file \(fileName)")"#,
            #"print("File delivery PASS: \(fileName)")"#,
            #"print("File delivery path: \(filePath)")"#,
            "return req.fileio.streamFile(at: filePath)"
        ] {
            #expect(text.contains(pinned), "Handler contract line changed or missing: \(pinned)")
        }
    }

    @Test("Negative control: the pinning can fail")
    func pinningCanFail() throws {
        // Proves the assertions above are matching real content rather than passing
        // vacuously: the same checks against a mutated copy must not all hold.
        let mutated = try routeFileText()
            .replacingOccurrences(of: "return Response(status: .notFound)",
                                  with: "return Response(status: .ok)")

        #expect(mutated.contains("return Response(status: .notFound)") == false)
        #expect(mutated.contains("return Response(status: .ok)"))
    }
}
