// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AIHOSAssetServer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.76.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AIHOSAssetServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "SQLKit", package: "sql-kit")
            ],
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "AIHOSAssetServerTests",
            dependencies: ["AIHOSAssetServer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
