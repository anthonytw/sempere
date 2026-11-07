import Foundation
import Sempere
import SempereSync
import TempDirSupport
import Testing

/// iCloud Drive support that can be checked without iCloud: placeholder names, which files a vault needs, progress,
/// and the download loop over fake provider hooks. (The live hooks, file coordination and the texts are the app's
/// `CloudTests`.)
struct CloudScanTests {
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
        #expect(CloudProgress(states: []).isComplete)
        #expect(CloudProgress(states: []).fractionCompleted == 1)
        #expect(CloudProgress(total: 2, downloaded: 5) == CloudProgress(total: 2, downloaded: 2))   // clamped
        #expect(CloudProgress(total: -1, downloaded: -1) == CloudProgress(total: 0, downloaded: 0))
    }

    /// A vault folder as iCloud shows it with some files evicted.
    static func evictedVault() throws -> URL {
        let fm = FileManager.default
        let root = TestTemp.root.appendingPathComponent(UUID().uuidString)
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
    }

    @Test func scanOfAVaultWithoutKeysOrNotesIsJustTheManifest() throws {
        let root = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("vault.json"))
        #expect(try CloudScan.items(inVault: root).map(\.url.lastPathComponent) == ["vault.json"])
        #expect(throws: (any Error).self) {
            try CloudScan.items(inVault: root.appendingPathComponent("nope"))
        }
    }

    /// The loop asks for every file that is not current, waits only for the missing ones, reports progress, and
    /// passes the provider's failure on with the file's name.
    @Test func downloadRequestsWaitsAndReportsProgress() async throws {
        let root = try Self.evictedVault()
        let provider = FakeProvider()
        let hooks = CloudVault.Hooks(isUbiquitous: { _ in true }, state: { provider.state($0) },
                                     request: { provider.request($0) })
        let reported = Reported()
        let inCloud = try await CloudVault.download(vault: root, hooks: hooks, pollInterval: .milliseconds(1)) {
            await reported.add($0)
        }
        #expect(inCloud)
        #expect(provider.requested.count == 4, "the four placeholders")
        let all = await reported.all
        #expect(all.first == CloudProgress(total: 4, downloaded: 0))
        #expect(all.last == CloudProgress(total: 4, downloaded: 4))

        provider.failing = true
        await #expect(throws: CloudVault.CloudError.failed(name: "vault.json", reason: "offline")) {
            try await CloudVault.download(items: [CloudScan.Item(url: root.appendingPathComponent("vault.json"), placeholder: true)],
                                          hooks: hooks, pollInterval: .milliseconds(1)) { _ in }
        }

        // Not in iCloud: nothing is asked.
        let local = CloudVault.Hooks(isUbiquitous: { _ in false }, state: { _ in .missing }, request: { _ in Issue.record("asked") })
        #expect(try await !CloudVault.download(vault: root, hooks: local) { _ in Issue.record("reported") })
    }
}

/// A provider whose placeholders become files on the poll after they are requested.
private final class FakeProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URL] = []
    private var polls: [URL: Int] = [:]
    var failing = false

    var requested: [URL] { lock.withLock { asked } }

    func request(_ item: CloudScan.Item) {
        lock.withLock { asked.append(item.url) }
    }

    func state(_ item: CloudScan.Item) -> CloudItemState {
        lock.withLock {
            if failing { return .failed("offline") }
            guard item.placeholder else { return .current }
            guard asked.contains(item.url) else { return .missing }
            polls[item.url, default: 0] += 1
            return polls[item.url]! > 1 ? .current : .missing
        }
    }
}

private actor Reported {
    var all: [CloudProgress] = []
    func add(_ p: CloudProgress) { all.append(p) }
}
