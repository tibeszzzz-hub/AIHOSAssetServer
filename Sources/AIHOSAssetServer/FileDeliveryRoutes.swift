import Vapor
import Foundation

// MARK: - File delivery route
//
// F-F1, the first route group lifted out of the composition root. Chosen because it
// is the smallest read-only group with the least coupling in the whole server: it
// reads no database, issues no SQL, touches no ingest path and needs exactly one
// value from main() — the resolved storage directory.
//
// The dependency is passed in as a parameter rather than read from a global or from
// the environment a second time. main() resolves STORAGE_PATH once, fail-closed, and
// hands the already-validated value here; resolving it again would have created a
// second source of truth for the same setting.
//
// The parameter is deliberately named `apiV1` so the registration below reads exactly
// as it did inside main(). That keeps the route's gated status, its /api/v1 prefix and
// its manifest signature spelled identically to before the move.

/// Registers `GET /api/v1/files/:fileName` on the machine-gated `/api/v1` group.
///
/// - Parameters:
///   - apiV1: the gated `/api/v1` route group; gating is unchanged by this move.
///   - storageDirectory: the validated storage root resolved once in `main()`.
func registerFileDeliveryRoutes(on apiV1: MachineGatedRoutes, storageDirectory: String) {
    apiV1.get("files", ":fileName") { req async throws -> Response in
        guard let fileName = req.parameters.get("fileName") else {
            return Response(status: .badRequest)
        }

        let filePath = storageDirectory + "/" + fileName

        guard FileManager.default.fileExists(atPath: filePath) else {
            print("File delivery failed: missing file \(fileName)")
            return Response(status: .notFound)
        }

        print("File delivery PASS: \(fileName)")
        print("File delivery path: \(filePath)")
        return req.fileio.streamFile(at: filePath)
    }
}
