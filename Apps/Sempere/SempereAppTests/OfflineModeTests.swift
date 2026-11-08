import Age
import Darwin
import Foundation
import Sempere
import SempereAppCore
import SempereSpeech
import SempereSync
import Testing
@testable import SempereApp

/// The "never online" test mode (`scripts/app.sh test-mac-offline`, docs/ci.md "Offline mode"): the Catalyst test
/// host is signed with `SempereOfflineTests.entitlements` (no `network.client`), so the sandbox refuses every
/// outbound connection, and `SEMPERE_OFFLINE_TEST=1` is set. These tests then check that the mode is in force (a
/// run that sets the variable without the entitlements fails), and walk journeys that must not need the network.
/// Without the variable they are skipped. The join over a drive, which needs no network either, is
/// `JoinThroughProviderTests.aDeviceJoinsThroughAFolderOnADrive` in `SempereAppCoreTests` (it runs in every mode).
@MainActor
struct OfflineModeTests {
    nonisolated static var offline: Bool { ProcessInfo.processInfo.environment["SEMPERE_OFFLINE_TEST"] == "1" }

    /// A raw TCP connect to a public address fails at once (the sandbox, not a timeout).
    @Test(.enabled(if: OfflineModeTests.offline)) func outboundConnectionsAreRefused() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(443).bigEndian
        addr.sin_addr.s_addr = inet_addr("1.1.1.1")
        let started = Date()
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(r != 0, "a connection to 1.1.1.1 was allowed: the offline mode is not in force")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// URLSession fails too (what the WebDAV client and the dormant math-model downloader use).
    @Test(.enabled(if: OfflineModeTests.offline)) func urlSessionRequestsFail() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: URL(string: "https://example.com/")!)
        }
    }

    /// A new vault in the store, a note with typed text and an equation, its search, a PDF export, a backup and a
    /// restore, and a folder target on a local folder: all with no connection.
    @Test(.enabled(if: OfflineModeTests.offline)) func coreJourneyWorksOffline() async throws {
        let root = try TestTemp.directory("offline-journey")
        let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.vaultStore = library.vaultStore
        model.folderWriteDelay = 0.05
        model.folderArrivalWait = 0.5
        let (vault, keyURL) = try AppModelTests.fixtureVault()
        let key = try String(contentsOf: keyURL, encoding: .utf8)
        try await model.copyIn(picked: vault, library: library)
        try await model.unlock(identityText: key)
        #expect(model.phase == .unlocked)
        #expect(!model.notes.isEmpty)
        // A local folder as a sync target ("a USB drive"): it syncs, with no network.
        let drive = try TestTemp.directory("offline-drive")
        let shared = drive.appendingPathComponent("Notes.sempere", isDirectory: true)
        let vaultID = try #require(model.vault?.vaultId)
        try model.addFolderTarget(shared, scope: drive, to: vaultID)
        await model.syncAllTargetsNow()
        #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("vault.json").path))
        let status = try #require(model.syncSessions.first?.status)
        #expect(!status.needsAttention, "\(status.headline)")
    }

    /// Transcription availability is asked without any download (Settings ▸ Transcription), and returns at once.
    @Test(.enabled(if: OfflineModeTests.offline)) func transcriptionAvailabilityAnswersOffline() async throws {
        let started = Date()
        let engines = await SpeechTranscription.availability(options: .init(language: "en-US"))
        #expect(!engines.isEmpty)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
