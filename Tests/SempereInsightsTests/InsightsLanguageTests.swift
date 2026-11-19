import Foundation
import Sempere
import VaultTestSupport
import XCTest
@testable import SempereInsights

/// The insight language (`insights.language`, docs/settings-sync.md §5.1, format.md §16.2 `outLang`): summaries and
/// voice-note titles in a fixed language, "Same as note" (nil) by default.
extension InsightsUpdaterTests {
    func testTheDefaultWritesInTheNotesOwnLanguage() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let model = FakeModelProvider()
        _ = try await run(model) { $0.force = true }
        XCTAssertFalse(model.log.contains("translate"), "Same as Note never calls for a translation")
        let gen = try XCTUnwrap(InsightsStore(vault: vault).snapshot().bestGen(for: id, hash: nil)?.gen)
        XCTAssertNil(gen.outLang)
        XCTAssertFalse(gen.summary?.hasPrefix("[") ?? true)
        XCTAssertEqual(InsightsSettings.read(vault).language, nil)
    }

    /// A fixed language: the summary and the slug are made in the note's language, checked, then put into the chosen one;
    /// the title derived from the slug follows; keywords stay.
    func testAFixedLanguageTranslatesTheSummaryAndTheTitle() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        try InsightsSettingsWrite.setLanguage("es", vault: vault, now: now)
        XCTAssertEqual(InsightsSettings.read(vault).language, "es")
        let model = FakeModelProvider()
        let r = try await run(model) { $0.force = true }
        XCTAssertEqual(r.titled, [id.uuidString.lowercased()])
        XCTAssertTrue(model.log.contains("translate"))
        let snap = InsightsStore(vault: vault).snapshot()
        let gen = try XCTUnwrap(snap.bestGen(for: id, hash: nil)?.gen)
        XCTAssertEqual(gen.outLang, "es")
        XCTAssertTrue(try XCTUnwrap(gen.summary).hasPrefix("[es] "))
        XCTAssertTrue(try XCTUnwrap(gen.slug).hasPrefix("[es] "))
        XCTAssertFalse(gen.keywords.contains { $0.t.hasPrefix("[") }, "keywords stay as the note has them")
        let title = try XCTUnwrap(snap.bestTitle(for: id, hash: nil, language: "es"))
        XCTAssertTrue(title.contains("[es] Spring"), title)
        XCTAssertEqual(snap.notes[id]?.values.first?.title?.lang, "es")
    }

    /// Changing the setting makes what was written in another language be made again, then settles.
    func testChangingTheLanguageRegeneratesOnceThenSettles() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try note("Other", Self.physics[0])
        try enable()
        let first = try await run { $0.force = true }
        XCTAssertEqual(first.titled, [id.uuidString.lowercased()])
        let plain = try await run { $0.ignoreSettle = true }
        XCTAssertEqual(plain.generated + plain.titled, [], "settled before the change")
        try InsightsSettingsWrite.setLanguage("fr", vault: vault, now: now)
        let again = try await run { $0.ignoreSettle = true }
        XCTAssertEqual(Set(again.generated).count, 2, "both notes are made again in French")
        XCTAssertEqual(again.titled, [id.uuidString.lowercased()], "and the voice note's title for French is derived")
        let snap = InsightsStore(vault: vault).snapshot()
        XCTAssertTrue(try XCTUnwrap(snap.bestTitle(for: id, hash: nil, language: "fr")).contains("[fr]"))
        XCTAssertNotNil(snap.bestTitle(for: id, hash: nil, language: nil), "a reader that names another language still gets a title")
        let settled = try await run { $0.ignoreSettle = true }
        XCTAssertEqual(settled.generated + settled.titled, [])
        // Back to Same as Note: made again once more.
        try InsightsSettingsWrite.setLanguage(nil, vault: vault, now: now)
        XCTAssertNil(InsightsSettings.read(vault).language)
        let back = try await run { $0.ignoreSettle = true }
        XCTAssertEqual(Set(back.generated).count, 2)
        XCTAssertNil(try XCTUnwrap(InsightsStore(vault: vault).snapshot().bestGen(for: id, hash: nil)?.gen).outLang)
    }

    /// A model that cannot translate fails the generation (a back-off), never a half-translated note.
    func testAModelThatCannotTranslateWritesNothingInAFixedLanguage() async throws {
        _ = try note("A", Self.physics[0])
        try enable()
        try InsightsSettingsWrite.setLanguage("de", vault: vault, now: now)
        final class NoTranslate: ModelProvider, @unchecked Sendable {
            let inner = FakeModelProvider()
            var identity: GenerationIdentity { inner.identity }
            var availability: ModelAvailability { inner.availability }
            var contextTokens: Int { inner.contextTokens }
            func supports(language: String?) -> Bool { inner.supports(language: language) }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction { try await inner.extract(text, language: language) }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
                try await inner.summarize(topic: topic, summaries: summaries, language: language)
            }
            func title(transcript: String, language: String?) async throws -> String { try await inner.title(transcript: transcript, language: language) }
        }
        let r = try await InsightsUpdater(vault: vault, model: NoTranslate(), embedder: nil, deviceState: state, app: "test/1")
            .run({ var o = InsightsUpdateOptions(); o.now = now; o.platform = .init(platform: "mac", os: "macOS 27.2"); o.force = true; return o }(),
                 notes: try inputs())
        XCTAssertEqual(r.generated, [])
        XCTAssertEqual(r.failures.count, 1, "the failure is reported, not hidden")
    }

    func testTheSettingValidatesTagsAndSharesTheVault() throws {
        let spec = try XCTUnwrap(SharedSettingsCatalog.spec(named: "insights.language"))
        XCTAssertEqual(spec.defaultValue, .null)
        for ok in ["es", "pt-BR", "zh-Hans", "en"] { XCTAssertNotNil(spec.validated(.string(ok)), ok) }
        XCTAssertNotNil(spec.validated(.null))
        for bad in ["", "e s", "es_ES", "1x", "waytoolongprimary", "es-", String(repeating: "a", count: 40)] {
            XCTAssertNil(spec.validated(.string(bad)), bad)
        }
        XCTAssertEqual(spec.parse("same"), .null)
        XCTAssertEqual(spec.parse("es"), .string("es"))
        XCTAssertThrowsError(try InsightsSettingsWrite.setLanguage("not a tag", vault: vault, now: now))
        // Vault-wide: any device reads the same value from the shared file.
        try InsightsSettingsWrite.setLanguage("it", vault: vault, now: now)
        // A block for one kind of device does not change it: the vault's devices all write the same language.
        try vault.updateSharedSettings { s in
            try s.write(spec, .string("ja"), block: "mac", type: nil, now: now)
        }
        for type in [nil, SettingsDeviceType.mac, .iphone, .ipad] {
            XCTAssertEqual(InsightsSettings.read(vault, type: type).language, "it", "\(String(describing: type))")
        }
    }
}
