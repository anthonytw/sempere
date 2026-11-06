import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Rewrites the committed fixture vaults in the source tree (`Tests/SempereTests/Fixtures`; `Fixtures/README.md`).
/// Each test skips unless its environment variable asks (the tools of `scripts/bench.sh sempere -- --filter
/// FixtureRegeneration`); the generators themselves are `Tests/SempereTests/FixtureGenerators.swift`, which the
/// fixture tests read the results against (`testFixtureMatchesAFreshGeneration` and the others).
final class FixtureRegeneration: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    /// Rewrites Fixtures/sample.sempere in the source tree, reusing sample.key (the fixture device's key
    /// file) and sample-recovery.key, or creating them when they are missing or not of the key hierarchy.
    func testRegenerateFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_FIXTURE=1 to rewrite the fixture vault")
        }
        let dir = FixtureFiles.source
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent("sample.key"), recoveryURL = dir.appendingPathComponent("sample-recovery.key")
        if (try? DeviceKeys.parse(String(contentsOf: keyURL, encoding: .utf8))) == nil {
            // Keeps the age identity of an older sample.key, so stock-age commands in docs keep working.
            let old = (try? String(contentsOf: keyURL, encoding: .utf8)).flatMap { try? IdentityFile.parse($0) }
            let identity: MLKEM768X25519Identity
            if case .mlkem768x25519(let pq)? = old { identity = pq } else { identity = try MLKEM768X25519Identity() }
            let device = try DeviceKeys(identity: identity, signing: DeviceSigningKeys.generate())
            try ("# TEST-ONLY throwaway device key for Tests/SempereTests/Fixtures. Never use it for real notes.\n"
                + (try device.fileText(created: SampleFixture.at(0)))).write(to: keyURL, atomically: true, encoding: .utf8)
        }
        if (try? IdentityFile.parse(String(contentsOf: recoveryURL, encoding: .utf8))) == nil {
            try ("# TEST-ONLY throwaway recovery key for Tests/SempereTests/Fixtures. Never use it for real notes.\n"
                + IdentityFile.render(.mlkem768x25519(try MLKEM768X25519Identity()), created: SampleFixture.at(0)))
                .write(to: recoveryURL, atomically: true, encoding: .utf8)
        }
        let (device, recovery) = try SampleFixture.keys(in: dir)
        let vaultURL = dir.appendingPathComponent("sample.sempere")
        try? FileManager.default.removeItem(at: vaultURL)
        try SampleFixture.generate(at: vaultURL, identity: device.nativeIdentity, recovery: recovery)
    }


    /// Rewrites Fixtures/items.sempere only (the sample vault keeps its tagged manifest).
    func testRegenerateItemsFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_ITEMS_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_ITEMS_FIXTURE=1 to rewrite Fixtures/items.sempere")
        }
        let dir = FixtureFiles.source
        let (device, recovery) = try SampleFixture.keys(in: dir)
        let url = dir.appendingPathComponent("items.sempere")
        try? FileManager.default.removeItem(at: url)
        try ItemsFixture.generate(at: url, identity: device.nativeIdentity, recovery: recovery)
    }


    func testRegenerateEpochsFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_EPOCHS_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_EPOCHS_FIXTURE=1 to rewrite Fixtures/epochs.sempere")
        }
        let dir = FixtureFiles.source
        let (device, recovery) = try SampleFixture.keys(in: dir)
        let url = dir.appendingPathComponent("epochs.sempere")
        try? FileManager.default.removeItem(at: url)
        try EpochsFixture.generate(at: url, device: device, recovery: recovery)
    }


    /// Rewrites `Fixtures/newer.sempere` in the source tree from `sample.key`.
    func testRegenerateNewerFixture() throws {
        guard ProcessInfo.processInfo.environment["SEMPERE_REGENERATE_FIXTURE"] == "1" else {
            throw XCTSkip("set SEMPERE_REGENERATE_FIXTURE=1 to rewrite the fixture vault")
        }
        let target = FixtureFiles.source.appendingPathComponent("newer.sempere")
        try? FileManager.default.removeItem(at: target)
        try NewerFixture.generate(at: target, identity: try SampleFixture.keys(in: FixtureFiles.source).device.nativeIdentity)
    }

}
