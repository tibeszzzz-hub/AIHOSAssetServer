// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AIHOSAssetServer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // The built binary keeps its name and location: .build/<config>/AIHOSAssetServer.
        // Deployment refers to that path, so the split below must not be visible from
        // the outside.
        .executable(name: "AIHOSAssetServer", targets: ["AIHOSAssetServerRun"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.76.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.0.0")
    ],
    targets: [
        // The server itself, as a library so it can be imported by tests. An executable
        // target carries a program entry point, which is what previously made the test
        // bundle unable to run in release configuration.
        //
        // The directory and the module name are unchanged, so `@testable import
        // AIHOSAssetServer` and every source path keep working exactly as before.
        .target(
            name: "AIHOSAssetServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "SQLKit", package: "sql-kit")
            ],
            // The frameworks stay with the target that actually calls them: the Speech
            // and Vision actors live in the library, not in the runner.
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("Vision")
            ]
        ),
        // Nothing but the program entry point. It holds no server logic of its own so
        // that everything worth testing stays inside the library above.
        .executableTarget(
            name: "AIHOSAssetServerRun",
            dependencies: ["AIHOSAssetServer"]
        ),
        .testTarget(
            name: "AIHOSAssetServerTests",
            dependencies: [
                "AIHOSAssetServer",
                // Test-only product of the vapor package already used by the server target.
                // Needed to exercise real routing/middleware behaviour in tests.
                .product(name: "VaporTesting", package: "vapor")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
