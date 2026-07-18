// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DriveMapper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DriveMapperCore", targets: ["DriveMapperCore"]),
        .executable(name: "driveatlas", targets: ["DriveMapperCLI"]),
        .executable(name: "DriveMapperApp", targets: ["DriveMapperApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "DriveMapperCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "DriveMapperCLI",
            dependencies: ["DriveMapperCore"]
        ),
        .executableTarget(
            name: "DriveMapperApp",
            dependencies: ["DriveMapperCore"]
        ),
        .testTarget(
            name: "DriveMapperCoreTests",
            dependencies: ["DriveMapperCore"]
        )
    ]
)
