import Foundation
@testable import Sempere
import XCTest
@testable import SempereInsights

/// A topics file this device writes is one its readers accept (format.md §16.7, §16.8): a translated topic summary is held
/// to the topic length rule, every write passes the reader's checks, and this device's own file that fails only those
/// checks (as an earlier build could write it) is replaced rather than blocking topics for good.
extension InsightsUpdaterTests {
    /// A model whose translation is longer than a topics file may hold (about 4,100 characters).
    static func wordyTranslator() -> FakeModelProvider {
        var s = FakeModelProvider.Script()
        s.translation = { text, lang in "[\(lang)] " + text + " " + String(repeating: "palabra ", count: 512) }
        return FakeModelProvider(s)
    }

    var ownTopicsName: InsightsFileName {
        get throws { InsightsFileName(.topics, device: try XCTUnwrap(vault.writerDevice)) }
    }

    var ownTopicsFile: URL {
        get throws { vault.insightsURL.appendingPathComponent(try ownTopicsName.fileName) }
    }

    func testALongTranslatedTopicSummaryIsCutAndItsFileReads() async throws {
        try physicsAndKitchen()
        try InsightsSettingsWrite.setLanguage("es", vault: vault, now: now)
        let r = try await run(Self.wordyTranslator())
        XCTAssertEqual(r.failures, [:])
        XCTAssertEqual(r.topics.sorted(), ["notebook:Kitchen", "tag:physics"])
        guard case .topics(let f)? = try InsightsStore(vault: vault).read(try ownTopicsName) else { return XCTFail("no topics file") }
        XCTAssertEqual(f.topics.count, 2)
        for t in f.topics {
            XCTAssertLessThanOrEqual(t.gen.summary.count, TopicSummaries.maxCharacters)
            XCTAssertTrue(t.gen.summary.hasPrefix("[es]"), t.gen.summary)
            XCTAssertEqual(t.gen.outLang, "es")
        }
        XCTAssertNotNil(InsightsStore(vault: vault).snapshot().topics[try XCTUnwrap(vault.writerDevice)])
    }

    func testAWriteItsReadersWouldRejectIsRefused() throws {
        try physicsAndKitchen()
        let me = try XCTUnwrap(vault.writerDevice)
        let identity = GenerationIdentity(model: "fake", os: "27.0", prompt: 1)
        func topics(summary: String, outLang: String? = nil) -> InsightsFileContent {
            .topics(InsightsTopicsFile(device: me, written: 1, topics: [
                .init(scope: .init(tag: "physics"), members: 3, membersHash: "abc",
                      gen: .init(identity: identity, at: 1, summary: summary, outLang: outLang)),
            ]))
        }
        let name = try ownTopicsName
        XCTAssertNoThrow(try vault.sealInsights(topics(summary: "A short summary.", outLang: "es"), name: name))
        XCTAssertThrowsError(try vault.sealInsights(topics(summary: String(repeating: "a", count: InsightsLimits.maxTopicSummary + 1)),
                                                    name: name)) {
            XCTAssertEqual($0 as? InsightsFileError, .invalid("topic summary"))
        }
        XCTAssertThrowsError(try vault.sealInsights(topics(summary: "Short.", outLang: String(repeating: "e", count: 65)), name: name)) {
            XCTAssertEqual($0 as? InsightsFileError, .invalid("outLang"))
        }
    }

    /// The file an earlier build wrote (a topic summary past the limit, under the current key) every reader ignores: the
    /// next pass replaces it.
    func testOwnTopicsFileThatFailsOnlyItsContentChecksIsReplaced() async throws {
        try physicsAndKitchen()
        let me = try XCTUnwrap(vault.writerDevice)
        let name = try ownTopicsName
        let over = InsightsTopicsFile(device: me, written: 1, topics: [
            .init(scope: .init(tag: "physics"), members: 3, membersHash: "abc",
                  gen: .init(identity: GenerationIdentity(model: "fake", os: "27.0", prompt: 1), at: 1,
                             summary: String(repeating: "palabra ", count: 600))),
        ])
        let body = try BodyFraming.frame(json: try InsightsCodec.encode(.topics(over)), noteId: InsightsCodec.tagScope,
                                         filename: name.fileName, secret: try vault.requireSecret())
        try FileManager.default.createDirectory(at: vault.insightsURL, withIntermediateDirectories: true)
        try vault.encrypt(body).write(to: try ownTopicsFile)
        XCTAssertThrowsError(try InsightsStore(vault: vault).read(name)) {
            XCTAssertEqual($0 as? InsightsFileError, .invalid("topic summary"))
        }
        let r = try await run()
        XCTAssertEqual(r.failures, [:])
        XCTAssertEqual(r.topics.sorted(), ["notebook:Kitchen", "tag:physics"])
        XCTAssertNotNil(InsightsStore(vault: vault).snapshot().topics[me])
    }

    /// A file that does not open under the current key (damage, another key) still blocks the write: its scopes are kept.
    func testADamagedOwnTopicsFileIsStillNotReplaced() async throws {
        try physicsAndKitchen()
        let damaged = Data("not an age file".utf8)
        try FileManager.default.createDirectory(at: vault.insightsURL, withIntermediateDirectories: true)
        try damaged.write(to: try ownTopicsFile)
        let r = try await run()
        XCTAssertEqual(r.topics, [])
        XCTAssertTrue(r.failures.values.allSatisfy { $0.contains("cannot be read, so it is not replaced") }, "\(r.failures)")
        XCTAssertEqual(try Data(contentsOf: try ownTopicsFile), damaged)
    }
}
