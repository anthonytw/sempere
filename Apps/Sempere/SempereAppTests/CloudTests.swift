import Foundation
import Sempere
import SempereSync
import Testing
@testable import SempereApp

/// The app's half of iCloud Drive support (`CloudVault+Live.swift`): the live state of a file, the local fast path,
/// file coordination and the texts. (Placeholder names, the scan, progress and the download loop are the package's
/// `CloudScanTests`.)
struct CloudTests {
    @Test func progressTextCountsFiles() {
        #expect(CloudProgress(states: [.current, .missing, .stale, .gone, .failed("x"), .missing]).description
                == "Downloading from iCloud… 3/6 files")
        #expect(CloudProgress(total: 1, downloaded: 1).description == "Downloading from iCloud… 1/1 file")
    }

    /// Placeholders read as missing, real local files as current, a file whose stand-in went too as gone.
    @Test func liveStateReadsPlaceholdersAndLocalFiles() throws {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = CloudScan.Item(url: dir.appendingPathComponent("1-a-1.delta.age"), placeholder: false)
        try Data("x".utf8).write(to: local.url)
        let evicted = CloudScan.Item(url: dir.appendingPathComponent("2-a-2.delta.age"), placeholder: true)
        try Data("x".utf8).write(to: CloudPlaceholder.placeholderURL(for: evicted.url))
        #expect(CloudVault.state(of: local) == .current)
        #expect(CloudVault.state(of: evicted) == .missing)

        // "Downloading" a placeholder: the real file appears, the stand-in goes.
        try Data("x".utf8).write(to: evicted.url)
        try FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: evicted.url))
        #expect(CloudVault.state(of: evicted) == .current)
        // Deleted remotely meanwhile: nothing left to wait for.
        let deleted = CloudScan.Item(url: dir.appendingPathComponent("3-a-3.delta.age"), placeholder: true)
        #expect(CloudVault.state(of: deleted) == .gone)
    }

    @MainActor
    @Test func localVaultsSkipICloudEntirely() async throws {
        let (url, _) = try AppModelTests.fixtureVault()
        #expect(!CloudVault.isUbiquitous(url))
        let reported = Reported()
        let inCloud = try await CloudVault.download(vault: url, hooks: .live) { await reported.add($0) }
        #expect(!inCloud)
        #expect(await reported.all.isEmpty)
    }

    @Test func coordinatedAccessRunsTheBodyAndPassesErrorsThrough() throws {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(try CloudVault.coordinatedRead(dir) { 1 } == 1)
        #expect(try CloudVault.coordinatedRead(nil) { 2 } == 2)
        #expect(try CloudVault.coordinatedWrite(dir.appendingPathComponent("new")) { 3 } == 3)
        #expect(throws: VaultError.locked) { try CloudVault.coordinatedWrite(dir) { throw VaultError.locked } }
        #expect(throws: VaultError.locked) { try CloudVault.coordinatedRead(dir) { throw VaultError.locked } }
    }

    @Test func timeoutMessageSaysWhatIsMissing() {
        let e = CloudVault.CloudError.timedOut(CloudProgress(total: 10, downloaded: 4), seconds: 90)
        #expect(AppModel.describe(e).contains("6 of 10"))
        #expect(AppModel.describe(e).contains("90 seconds"))
    }
}

private actor Reported {
    var all: [CloudProgress] = []
    func add(_ p: CloudProgress) { all.append(p) }
}
