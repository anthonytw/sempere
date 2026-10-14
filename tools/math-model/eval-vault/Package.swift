// swift-tools-version:6.0
import Foundation
import PackageDescription

// SwiftPM names a path dependency after its folder, whatever the repository is called.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let core = root.lastPathComponent

// Builds a throwaway vault with one note per sample of handwritten ink, so `sempere recognize-math` can be
// run on public ink (tools/math-model/eval.py). Not part of the app or the CLI.
let package = Package(
    name: "eval-vault",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../..")],
    targets: [
        .executableTarget(name: "eval-vault", dependencies: [
            .product(name: "Age", package: core),
            .product(name: "Sempere", package: core),
        ]),
    ]
)
