// swift-tools-version: 6.0
import PackageDescription

// The real-CloudKit test driver (docs/design/1.4-cloudkit.md §10.2, docs/io.md "The CloudKit target"). Apple only, a separate package
// so that `swift build` and `swift test` at the repository root never build it: `scripts/app.sh test-cloudkit` builds it, bundles
// and signs it (tools/cloudkit-live/run.sh) and runs it against the development environment of the container.
let package = Package(
    name: "cloudkit-live",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "sempere-core", path: "../..")],
    targets: [
        .executableTarget(
            name: "cloudkit-live",
            dependencies: [.product(name: "SempereSync", package: "sempere-core"), .product(name: "SempereCloudKit", package: "sempere-core")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
