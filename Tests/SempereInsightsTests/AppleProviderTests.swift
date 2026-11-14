import Foundation
import Sempere
import XCTest
@testable import SempereInsights
import SempereInsightsApple

/// The real providers (docs/design/1.2-note-insights.md §9 "Mac"), skipped unless this machine has them: the sentence
/// embedder's determinism and canaries, and Apple's on-device model on three short notes (shape and bounds, never exact
/// text), a 300-word note within 20 s and a fact-checked topic summary.
final class AppleProviderTests: XCTestCase {
    func embedder() throws -> any EmbeddingProvider {
        guard let e = AppleInsightsProviders.embedder(), !e.supportedRevisions(language: "en").isEmpty,
              (try? e.embed("probe", language: "en", revision: e.supportedRevisions(language: "en")[0])) != nil else {
            throw XCTSkip("no NaturalLanguage sentence embedding here")
        }
        return e
    }

    func model() throws -> any ModelProvider {
        guard let m = AppleInsightsProviders.model(), m.availability.isAvailable else {
            throw XCTSkip("Apple's on-device model is not available: \(AppleInsightsProviders.unavailableReason)")
        }
        return m
    }

    func testTheEmbedderIsDeterministicAndPassesItsOwnCanaries() throws {
        let e = try embedder()
        let rev = try XCTUnwrap(e.supportedRevisions(language: "en").min())
        let a = try XCTUnwrap(try Canaries.vectors(e, language: "en", revision: rev))
        let b = try XCTUnwrap(try Canaries.vectors(e, language: "en", revision: rev))
        XCTAssertEqual(a, b, "bit-identical across calls [M]")
        let key = e.key(language: "en", revision: rev)
        let stored = InsightsCanaries(set: Canaries.set, vectors: a).vectors(dimension: a[0].count) ?? []
        XCTAssertTrue(Canaries.compatible(mine: a, myKey: key, theirs: stored, theirKey: key), "Float16 keeps cosine ≥ 0.999")
        XCTAssertEqual(e.model, "nl-sentence")
    }

    static let notes = [
        "Lecture 4. Free vibration of a damped spring mass system. The damping ratio zeta = c / (2 sqrt(k m)) decides the motion: "
            + "under damped systems oscillate with a decaying amplitude, critically damped ones return fastest without oscillating, "
            + "over damped ones creep back. The logarithmic decrement measures the decay between two peaks.",
        "Sourdough: feed the starter with equal weights of flour and water, wait until it doubles, mix 500 g flour, 350 g water, "
            + "100 g starter and 10 g salt. Stretch and fold four times, proof overnight in the fridge, bake at 250 C in a covered pot.",
        "Meeting with the thesis committee. Chapter two needs a clearer statement of the hypothesis and the sampling method. "
            + "Professor Lee asked for the survey response rate. Next meeting in March; send the draft two weeks before.",
    ]

    func testExtractOnThreeNotes() async throws {
        let m = try model()
        for text in Self.notes {
            let gen = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: m, merger: nil)
            XCTAssertLessThanOrEqual(gen.keywords.count, TermNormalizer.maxKeywords)
            XCTAssertLessThanOrEqual(gen.concepts.count, TermNormalizer.maxConcepts)
            XCTAssertFalse(gen.keywords.isEmpty, text)
            XCTAssertLessThanOrEqual(gen.summary?.count ?? 0, 600)
            XCTAssertEqual(gen.model, "afm-ondevice")
        }
    }

    func testA300WordNoteWithin20Seconds() async throws {
        let m = try model()
        let text = Array(repeating: Self.notes[0], count: 6).joined(separator: "\n\n").split(separator: " ").prefix(300).joined(separator: " ")
        let start = Date()
        _ = try await InsightsGenerator.generate(text: text, hash: InsightsText.hash(text), language: "en", model: m, merger: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    func testATopicSummaryIsFactChecked() async throws {
        let m = try model()
        let members = Self.notes.enumerated().map { i, t in
            TopicSummaries.Member(note: UUID(), hash: String(i), summary: String(t.prefix(200)), keywords: [])
        }
        let s = try await TopicSummaries.generate(name: "notebook:Mixed", members: members, language: "en", model: m, merger: nil)
        if let s { XCTAssertLessThanOrEqual(InsightsChunker.sentences(s).count, TopicSummaries.maxSentences) }
    }
}
