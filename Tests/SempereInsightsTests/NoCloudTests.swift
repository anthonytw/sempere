import Foundation
import XCTest

/// The ban on cloud models, by source scan (docs/design/1.2-note-insights.md §8; Linux-safe, every `swift test`):
///
/// - no Swift file under `Sources/` or `Apps/` names Private Cloud Compute, conforms to `LanguageModel`, or names a
///   hosted model's vendor (`bannedNames`, a maintained list);
/// - `FoundationModels` is imported only in `SempereInsightsApple`, whose only model is `SystemLanguageModel.default`
///   (no other initializer, no adapters);
/// - `SempereInsights` and `SempereInsightsApple` have no network code and do not depend on `SempereWebDAV`;
/// - neither target uses Core Spotlight or App Intents.
final class NoCloudTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Names no source may contain (case-insensitive): hosted models and their vendors.
    static let bannedNames = ["PrivateCloudCompute", "ChatGPT", "openai", "anthropic", "gemini"]

    static func swiftFiles(under folder: String) -> [(path: String, text: String)] {
        let root = repo.appendingPathComponent(folder)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        while let url = e.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((String(url.path.dropFirst(repo.path.count + 1)), text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    func testNoCloudModelIsNamedAnywhere() {
        let files = Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Apps")
        XCTAssertGreaterThan(files.count, 100, "the scan found the sources")
        for (path, text) in files {
            let lower = text.lowercased()
            for name in Self.bannedNames where lower.contains(name.lowercased()) { XCTFail("\(path) names \(name)") }
            // A conformance to `LanguageModel` (a custom model) anywhere.
            for line in text.split(separator: "\n") where line.contains(": LanguageModel") || line.contains(", LanguageModel") {
                XCTFail("\(path) conforms to LanguageModel: \(line)")
            }
        }
    }

    func testFoundationModelsOnlyInTheAppleTargetAndOnlyTheSystemModel() {
        let files = Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Apps")
        var importers: [String] = []
        for (path, text) in files where text.contains("import FoundationModels") { importers.append(path) }
        XCTAssertEqual(importers, ["Sources/SempereInsightsApple/AppleProviders.swift"])
        for (path, text) in Self.swiftFiles(under: "Sources/SempereInsightsApple") {
            for line in text.split(separator: "\n") where line.contains("LanguageModel") {
                let allowed = line.contains("SystemLanguageModel.default") || line.contains("LanguageModelSession")
                    || line.trimmingCharacters(in: .whitespaces).hasPrefix("//") || line.contains("SystemLanguageModel(")
                XCTAssertTrue(allowed, "\(path): \(line)")
                XCTAssertFalse(line.contains("SystemLanguageModel(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                               "\(path): only SystemLanguageModel.default, never another model or an adapter: \(line)")
            }
            XCTAssertFalse(text.contains("Adapter"), "\(path) loads an adapter")
            XCTAssertFalse(text.contains("tools: ["), "\(path) gives the model tools")
        }
    }

    func testNoNetworkSpotlightOrIntentsInTheInsightsTargets() throws {
        for folder in ["Sources/SempereInsights", "Sources/SempereInsightsApple"] {
            let files = Self.swiftFiles(under: folder)
            XCTAssertFalse(files.isEmpty, folder)
            for (path, text) in files {
                for banned in ["import Network", "URLSession", "FoundationNetworking", "CoreSpotlight", "CSSearchableIndex",
                               "AppIntents", "import SempereWebDAV"] where text.contains(banned) {
                    XCTFail("\(path) uses \(banned)")
                }
            }
        }
        // Neither target depends on SempereWebDAV (Package.swift).
        let manifest = try String(contentsOf: Self.repo.appendingPathComponent("Package.swift"), encoding: .utf8)
        for target in ["SempereInsights", "SempereInsightsApple"] {
            let line = manifest.split(separator: "\n").first { $0.contains(".target(name: \"\(target)\"") }
            XCTAssertNotNil(line, target)
            XCTAssertFalse(line?.contains("SempereWebDAV") ?? true, target)
        }
    }
}
