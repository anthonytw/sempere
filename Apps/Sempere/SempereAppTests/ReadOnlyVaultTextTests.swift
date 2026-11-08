import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// The words of a read-only vault (format.md §7.3). Opening the newer fixture and refusing every write are
/// `ReadOnlyVaultTests` in `SempereAppCoreTests`.
@MainActor
struct ReadOnlyVaultTextTests {
    /// A private copy of the newer fixture and the text of its key (for the app's suites that need a read-only vault).
    static func newerVault() throws -> (vault: URL, keyText: String) {
        let bundle = Bundle(for: ReadOnlyBundleToken.self)
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Fixtures missing from test bundle"])
        }
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("newer.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("newer.sempere"), to: vault)
        return (vault, try String(contentsOf: fixtures.appendingPathComponent("sample.key"), encoding: .utf8))
    }


    /// The banner and the editor's line name the newer format, from the model's typed reasons.
    @Test func theBannerAndTheEditorSayWhy() {
        let reasons = ReadOnlyReasons(vaultFormat: "sempere/2", unknownFeatures: [], newerNotes: [])
        #expect(AppModel.readOnlyText(reasons).contains("sempere/2"))
        #expect(NoteReadOnly.newerVersion(summary: "3 changes").text.contains("newer version"))
    }

    /// The banner's reasons are the app's own localized strings, not the CLI's English
    /// (`ReadOnlyReasons.descriptions`), which left an English clause inside the Spanish banner.
    @Test func bannerReasonsAreTheAppsLocalizedStrings() {
        let format = "sempere/2", current = SempereFormat.identifier, features = "a, b", count = 2
        let reasons = ReadOnlyReasons(vaultFormat: format, unknownFeatures: ["a", "b"], newerNotes: [UUID(), UUID()])
        let details = AppModel.readOnlyDetails(reasons)
        // The same catalog keys as the app's (interpolated, not literal), so this holds in any language.
        #expect(details == [
            String(localized: "the vault uses format \(format), newer than this version's \(current)"),
            String(localized: "the vault uses format extensions this version does not know: \(features)"),
            String(localized: "\(count) notes hold revisions written by a newer version"),
        ])
        #expect(!details.contains { $0.isEmpty })
        #expect(AppModel.readOnlyText(reasons).contains("a, b"))
        #expect(AppModel.readOnlyDetails(ReadOnlyReasons()).isEmpty)
    }

}

private final class ReadOnlyBundleToken {}
