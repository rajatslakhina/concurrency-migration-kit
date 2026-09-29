// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConcurrencyMigrationKit",
    // Only the platforms CI actually builds: Linux (via swift build/test, which needs no
    // platform clause) plus iOS/macOS for the demo app's `xcodebuild` job. Declaring
    // watchOS/tvOS/visionOS here would be a claim no job verifies.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ConcurrencyMigrationKit", targets: ["ConcurrencyMigrationKit"]),
        .library(name: "ConcurrencyMigrationKitUI", targets: ["ConcurrencyMigrationKitUI"]),
    ],
    targets: [
        .target(
            name: "ConcurrencyMigrationKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConcurrencyMigrationKitUI",
            dependencies: ["ConcurrencyMigrationKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConcurrencyMigrationKitTests",
            dependencies: ["ConcurrencyMigrationKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
