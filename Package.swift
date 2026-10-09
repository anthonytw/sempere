// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Notability importer is optional: delete `Sources/SempereNotability` (and `Tests/SempereNotabilityTests`)
// and this manifest drops its targets, so everything else builds unchanged (docs/import-notability.md "Structure").
let hasNotability = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/SempereNotability").path)

let package = Package(
    name: "sempere-core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Age", targets: ["Age"]),
        .library(name: "Sempere", targets: ["Sempere"]),
        .library(name: "SempereRender", targets: ["SempereRender"]),
        .library(name: "SempereImport", targets: ["SempereImport"]),
        .library(name: "SemperePDF", targets: ["SemperePDF"]),
        .library(name: "SempereWebDAV", targets: ["SempereWebDAV"]),
        .library(name: "SempereSpeech", targets: ["SempereSpeech"]),
        .executable(name: "sempere", targets: ["SempereCLI"]),
    ] + (hasNotability ? [.library(name: "SempereNotability", targets: ["SempereNotability"])] : []),
    dependencies: [
        // 4.0 adds X-Wing (ML-KEM-768 + X25519) and HPKE with it, for the
        // post-quantum age recipient (Sources/Age/MLKEM768X25519.swift).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]
        ),
        .target(
            name: "Age",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            // scrypt and X25519 are ~70x slower unoptimized: debug-build tests that
            // unlock a passphrase-wrapped key took minutes on CI (docs/HANDOFF.md "CI").
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "Sempere",
            dependencies: ["Age", "CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        // Minimal PDF reader for untrusted files (docs/attachments.md §10): Foundation + zlib only.
        .target(
            name: "SemperePDF",
            dependencies: ["CZlib"]
        ),
        .target(
            name: "SempereRender",
            dependencies: ["Sempere", "SemperePDF", "CZlib"],
            // The rasterizer is 10-30x slower unoptimized: debug-build tests and
            // fuzz cases hit their timeouts (see Age above, docs/HANDOFF.md "CI").
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        // The generic half of importing: zip, property-list and keyed-archive readers (all untrusted
        // input, format.md §9). Nothing here names an app that is imported from.
        .target(
            name: "SempereImport",
            dependencies: ["Sempere", "SemperePDF", "SempereRender", "CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        // The only target allowed network code (CLAUDE.md).
        .target(
            name: "SempereWebDAV",
            dependencies: ["Sempere", .product(name: "Crypto", package: "swift-crypto")]
        ),
        // On-device transcription (Speech framework where it exists; empty elsewhere).
        .target(name: "SempereSpeech", dependencies: ["Sempere"]),
        // Noto fonts for text in CLI exports (OFL 1.1); the app does not link them.
        .target(name: "SempereFonts", resources: [.copy("Fonts")]),
        .executableTarget(
            name: "SempereCLI",
            dependencies: [
                "Age", "Sempere", "SemperePDF", "SempereRender", "SempereImport", "SempereWebDAV", "SempereFonts", "SempereSpeech",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ] + (hasNotability ? ["SempereNotability"] : [])
        ),
        // Seeded mutation fuzzer shared by the test targets (Foundation only).
        .target(name: "FuzzSupport", path: "Tests/FuzzSupport"),
        // The base class of the tests that need a scratch directory (XCTest).
        .target(name: "TempDirSupport", path: "Tests/TempDirSupport"),
        // The base class of the CLI tests (a subprocess driver, fixture vaults); shared with the importers' CLI tests.
        .target(name: "CLITestSupport", dependencies: ["Age", "Sempere", "TempDirSupport"], path: "Tests/CLITestSupport"),
        // Plist, keyed-archive and zip writers for the importers' tests (Foundation and zlib only).
        .target(name: "ImportTestSupport", dependencies: ["CZlib"], path: "Tests/ImportTestSupport"),
        .testTarget(name: "AgeTests", dependencies: ["Age", "CZlib", "FuzzSupport", "TempDirSupport"],
                    resources: [.copy("Vectors")]),
        .testTarget(name: "SempereTests",
                    dependencies: ["Sempere", "FuzzSupport", "TempDirSupport", .product(name: "Crypto", package: "swift-crypto")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SempereRenderTests", dependencies: ["SempereRender", "SempereFonts", "Age", "FuzzSupport", "TempDirSupport"],
                    exclude: ["generate_sample_note.py", "generate_qr_vectors.py", "generate_image_fixtures.py", "generate_legacy_image_fixtures.py", "generate_shaping_fixtures.py"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SemperePDFTests", dependencies: ["SemperePDF", "FuzzSupport"],
                    exclude: ["generate_fixtures.py"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SempereImportTests",
                    dependencies: ["SempereImport", "Sempere", "SempereRender", "Age", "CZlib", "FuzzSupport", "TempDirSupport", "ImportTestSupport"]),
        .testTarget(name: "SempereWebDAVTests", dependencies: ["SempereWebDAV", "Sempere", "Age", "FuzzSupport", "TempDirSupport"]),
        .testTarget(name: "CLITests", dependencies: ["Age", "Sempere", "CLITestSupport"]),
    ] + (hasNotability ? [
        // The Notability importer (docs/import-notability.md "Structure"). Optional: delete this directory
        // (and Tests/SempereNotabilityTests) and everything else still builds.
        .target(
            name: "SempereNotability",
            dependencies: ["Sempere", "SemperePDF", "SempereRender", "SempereImport", "CZlib", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(name: "SempereNotabilityTests",
                    dependencies: ["SempereNotability", "SempereImport", "Sempere", "SempereRender", "Age", "CZlib", "FuzzSupport",
                                   "TempDirSupport", "ImportTestSupport", "CLITestSupport"],
                    exclude: ["Fixtures"]),
    ] : []),
    swiftLanguageModes: [.v6]
)
