import Foundation
import Sempere
import Testing
@testable import SempereApp

/// iCloud Drive support that can be checked without iCloud: placeholder
/// names, which files a vault needs, progress, and the local fast path.
struct CloudTests {
    @Test func placeholderNamesMapBothWays() {
        #expect(CloudPlaceholder.realName(of: ".vault.json.icloud") == "vault.json")
        #expect(CloudPlaceholder.realName(of: ".17596320000000003-a1b2c3d4-1.delta.age.icloud")
                == "17596320000000003-a1b2c3d4-1.delta.age")
        #expect(CloudPlaceholder.realName(of: "..hidden.icloud") == ".hidden")
        for notPlaceholder in ["vault.json", ".icloud", "..icloud", "x.icloud", ".x.ICLOUD", ".sempere-tmp-1", ""] {
            #expect(CloudPlaceholder.realName(of: notPlaceholder) == nil, "\(notPlaceholder)")
        }
        #expect(CloudPlaceholder.placeholderName(for: "vault.json") == ".vault.json.icloud")
        let url = URL(fileURLWithPath: "/v/notes/n/a.delta.age")
        #expect(CloudPlaceholder.placeholderURL(for: url).path == "/v/notes/n/.a.delta.age.icloud")
        #expect(CloudPlaceholder.realName(of: CloudPlaceholder.placeholderName(for: "a b.age")) == "a b.age")
    }

    @Test func progressAggregatesStates() {
        let p = CloudProgress(states: [.current, .missing, .stale, .gone, .failed("x"), .missing])
        #expect(p == CloudProgress(total: 6, downloaded: 3))
        #expect(!p.isComplete)
        #expect(p.fractionCompleted == 0.5)
        #expect(p.description == "Downloading from iCloud… 3/6 files")
        #expect(CloudProgress(total: 1, downloaded: 1).description == "Downloading from iCloud… 1/1 file")
        #expect(CloudProgress(states: []).isComplete)
        #expect(CloudProgress(states: []).fractionCompleted == 1)
        #expect(CloudProgress(total: 2, downloaded: 5) == CloudProgress(total: 2, downloaded: 2))   // clamped
        #expect(CloudProgress(total: -1, downloaded: -1) == CloudProgress(total: 0, downloaded: 0))
    }

    /// A vault folder as iCloud shows it with some files evicted.
    static func evictedVault() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Notes.sempere")
        let note = root.appendingPathComponent("notes/11111111-1111-4111-8111-111111111111")
        let other = root.appendingPathComponent("notes/22222222-2222-4222-8222-222222222222")
        for dir in [root.appendingPathComponent("keys"), note, other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for path in [".vault.json.icloud", "README.txt", ".DS_Store", "keys/.age1abc.key.age.icloud",
                     "notes/11111111-1111-4111-8111-111111111111/1-a-1.delta.age",
                     "notes/11111111-1111-4111-8111-111111111111/.2-a-2.delta.age.icloud",
                     "notes/11111111-1111-4111-8111-111111111111/.sempere-tmp-123",
                     "notes/22222222-2222-4222-8222-222222222222/.3-b-1.snapshot.age.icloud",
                     // Both the file and a stale placeholder: the file wins.
                     "notes/22222222-2222-4222-8222-222222222222/4-b-2.delta.age",
                     "notes/22222222-2222-4222-8222-222222222222/.4-b-2.delta.age.icloud"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    @Test func scanFindsVaultFilesAndMapsPlaceholders() throws {
        let root = try Self.evictedVault()
        let items = try CloudScan.items(inVault: root)
        let found = items.map { ($0.url.path.replacingOccurrences(of: root.path + "/", with: ""), $0.placeholder) }
        #expect(found.map(\.0) == ["vault.json", "keys/age1abc.key.age",
                                   "notes/11111111-1111-4111-8111-111111111111/1-a-1.delta.age",
                                   "notes/11111111-1111-4111-8111-111111111111/2-a-2.delta.age",
                                   "notes/22222222-2222-4222-8222-222222222222/3-b-1.snapshot.age",
                                   "notes/22222222-2222-4222-8222-222222222222/4-b-2.delta.age"])
        #expect(found.map(\.1) == [true, true, false, true, true, false])

        // Placeholders read as missing, real local files as current.
        let states = items.map(CloudVault.state(of:))
        #expect(states == [.missing, .missing, .current, .missing, .missing, .current])
        #expect(CloudProgress(states: states) == CloudProgress(total: 6, downloaded: 2))

        // "Downloading" a placeholder: the real file appears, the stand-in goes.
        let evicted = items[3]
        try Data("x".utf8).write(to: evicted.url)
        try FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: evicted.url))
        #expect(CloudVault.state(of: evicted) == .current)
        // Deleted remotely meanwhile: nothing left to wait for.
        try FileManager.default.removeItem(at: CloudPlaceholder.placeholderURL(for: items[4].url))
        #expect(CloudVault.state(of: items[4]) == .gone)
    }

    @Test func scanOfAVaultWithoutKeysOrNotesIsJustTheManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("vault.json"))
        #expect(try CloudScan.items(inVault: root).map(\.url.lastPathComponent) == ["vault.json"])
        #expect(throws: (any Error).self) {
            try CloudScan.items(inVault: root.appendingPathComponent("nope"))
        }
    }

    @MainActor
    @Test func localVaultsSkipICloudEntirely() async throws {
        let (url, _) = try AppModelTests.fixtureVault()
        #expect(!CloudVault.isUbiquitous(url))
        let reported = Reported()
        let inCloud = try await CloudVault.download(vault: url) { await reported.add($0) }
        #expect(!inCloud)
        #expect(await reported.all.isEmpty)
    }

    @Test func coordinatedAccessRunsTheBodyAndPassesErrorsThrough() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(try CloudVault.coordinatedRead(dir) { 1 } == 1)
        #expect(try CloudVault.coordinatedRead(nil) { 2 } == 2)
        #expect(try CloudVault.coordinatedWrite(dir.appendingPathComponent("new")) { 3 } == 3)
        #expect(throws: VaultError.locked) { try CloudVault.coordinatedWrite(dir) { throw VaultError.locked } }
        #expect(throws: VaultError.locked) { try CloudVault.coordinatedRead(dir) { throw VaultError.locked } }
    }

    @MainActor
    @Test func modelOpensLocalVaultWithoutCloudState() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        #expect(!model.isCloudVault)
        #expect(model.coordinationURL == nil)
        #expect(model.cloudProgress == nil)
        try await model.reload()
        #expect(model.cloudProgress == nil)
        model.cancelCloudDownload()   // nothing running: harmless
        #expect(model.phase == .unlocked)
    }

    @Test func timeoutMessageSaysWhatIsMissing() {
        let e = CloudVault.CloudError.timedOut(CloudProgress(total: 10, downloaded: 4), seconds: 90)
        #expect(e.description.contains("6 of 10"))
        #expect(e.description.contains("90 seconds"))
    }
}

private actor Reported {
    var all: [CloudProgress] = []
    func add(_ p: CloudProgress) { all.append(p) }
}
