import Age
import Foundation
import Sempere
import SempereAppCore
import TempDirSupport
import Testing

/// The model's tests run it on a host of their own (`AppModelHost`): the canvas of stored strokes (`TestCanvas`), the
/// headless services, and no-op steps for the extensions still in the app (wave 5b part 3), counted so a test can
/// see that a step ran.
enum TestHost: AppModelHost {
    typealias Canvas = TestCanvas
    typealias State = TestHostState

    static func makeState() -> TestHostState { TestHostState() }
    static func makeServices() -> AppModelServices { .headless() }

    static func willClose(_ model: AppModel) { model.appState.steps.append("willClose") }
    static func editorsChanged(_ model: AppModel) {}
    static func prepareEditor(_ editor: TestEditor, of note: UUID, in model: AppModel) {}
    static func unreadableText(_ editor: TestEditor) -> String { "unreadable" }
    static func closeWindowEditors(_ model: AppModel) async {}
    static func openWindowNote(_ id: UUID, in model: AppModel) async throws {}
    static func reopenWindowNote(_ id: UUID, in model: AppModel) async {}
}

/// What the test host's steps were asked.
@MainActor
final class TestHostState {
    var steps: [String] = []
}

/// The model the tests drive, as the app's `AppModel` is `AppModelCore<AppHost>`.
typealias AppModel = AppModelCore<TestHost>

/// The model's suites, one test at a time: each opens, lists and writes vaults on the main actor, and run all at
/// once beside the suites whose waits are bounded in wall time (`SyncCoordinatorTests`) they took the CPU from
/// them on the slower Linux runner (#18).
@Suite(.serialized)
enum AppModelSuites {}

/// The committed fixture vault (`Tests/SempereTests/Fixtures`, see its README): two notes, "Lecture" and one in
/// Recently Deleted, readable with `sample.key`.
enum ModelFixture {
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// `Tests/SempereTests/Fixtures`.
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("SempereTests/Fixtures", isDirectory: true)

    /// A private copy of the fixture vault, made off the main actor, and its key file.
    @concurrent static func vault() async throws -> (vault: URL, key: URL) {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("sample.sempere")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("sample.sempere"), to: vault)
        return (vault, fixtures.appendingPathComponent("sample.key"))
    }

    /// The key file's text.
    @concurrent static func keyText(_ key: URL) async throws -> String {
        try String(contentsOf: key, encoding: .utf8)
    }
}

/// The app suites' helpers (`SempereAppTests/TestSupport.swift`), for the suites that moved with the model: the
/// canvas strokes are the test canvas's (stored strokes).
enum TS {
    /// A wavy stroke of `n` control points starting at (`x`, `y`).
    static func stroke(x: Double = 40, y: Double = 60, n: Int = 24, tool: InkTool = .pen,
                       color: Sempere.Color = Sempere.Color(r: 0x1A, g: 0x2B, b: 0x3C, a: 0xFF),
                       width: Double = 3, transform: Transform? = nil) -> Stroke {
        let points = (0..<n).map { i -> StrokePoint in
            let d = Double(i)
            return StrokePoint(x: x + d * 3, y: y + 10 * sin(d / 3), t: d * 0.012, w: width + d.truncatingRemainder(dividingBy: 2),
                               h: width + d.truncatingRemainder(dividingBy: 2), o: 0.9, f: 0.2 + d / 100,
                               az: 0.4, al: 1.1)
        }
        return Stroke(ink: Ink(tool: tool, color: color, width: width), points: points, transform: transform)
    }

    /// A stroke as the (test) canvas reports it once drawn: the stored stroke itself.
    static func canvasStroke(_ s: Stroke, created: Date = Date()) -> Stroke { s }

    /// A temporary device-state file.
    static func deviceStateURL() -> URL {
        TestTemp.root.appendingPathComponent(UUID().uuidString).appendingPathComponent("device.json")
    }

    /// The summary-cache files in `dir` (the index; markers and other files aside).
    static func summaryFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".summaries") }
    }

    /// Another device writes `ops` into note `id`: a new revision file in the note's folder, off the main actor.
    @concurrent static func writeAsAnotherDevice(_ ops: [Op], to id: UUID, vault url: URL, key: URL) async throws {
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        _ = try vault.apply(ops, to: id, deviceState: deviceStateURL(), app: "other-device/1")
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    @MainActor
    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Lets already queued main-actor work run (a handler's follow-up task) without waiting on the wall clock.
    @MainActor
    static func yieldTurns(_ turns: Int = 30) async {
        for _ in 0..<turns { await Task.yield() }
    }
}

extension TS {
    /// The regular files below `dir`, as paths relative to it, sorted; `skipHidden` leaves out dot files.
    static func regularFiles(under dir: URL, skipHidden: Bool = false) -> [String] {
        let base = dir.standardizedFileURL.path
        let walker = FileManager.default.enumerator(atPath: base)
        var out: [String] = []
        while let rel = walker?.nextObject() as? String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + "/" + rel, isDirectory: &isDir), !isDir.boolValue,
               !(skipHidden && (rel as NSString).lastPathComponent.hasPrefix(".")) { out.append(rel) }
        }
        return out.sorted()
    }

    /// Every regular file below `dir` with its bytes, by relative path.
    static func fileSnapshot(of dir: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: regularFiles(under: dir).map {
            ($0, try Data(contentsOf: dir.standardizedFileURL.appendingPathComponent($0)))
        })
    }

    /// A new vault at `url` (format.md §15): `device` (a fresh one when nil) is its home, with a fresh recovery key,
    /// opened as that device.
    @discardableResult
    static func makeVault(at url: URL, device: DeviceKeys? = nil, name: String = "test device", label: String? = nil,
                          trust: (any EpochTrustStore)? = nil) throws -> (vault: Vault, device: DeviceKeys) {
        let device = try device ?? DeviceKeys.generate()
        let vault = try Vault.create(at: url, device: device, deviceName: name, kind: "ipad",
                                     recovery: try MLKEM768X25519Identity(), workFactor: 10, trust: trust, label: label)
        return (vault, device)
    }
}

/// Holds async work at a point until the test opens it.
actor Gate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    /// Closes the gate: later `pass()` calls wait for `open()`.
    func close() { isOpen = false }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters = []
    }

    /// Lets the oldest call waiting at the closed gate through; the gate stays closed for the calls after it.
    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func pass() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Waits until `count` calls have arrived at the gate.
    func waitForArrivals(_ count: Int) async {
        while arrivals < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// A page recognizer that reads every page as "fake <n strokes>" (the app's `FakeRecognizer`, whose suites that
/// need PencilKit stay in the app): records what it was asked, and may wait at a gate or fail.
final class FakeRecognizer: PageRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[UUID]] = []
    private var seenLanguages: [String?] = []
    let gate: Gate?
    let fail: Bool

    init(gate: Gate? = nil, fail: Bool = false) { self.gate = gate; self.fail = fail }

    var calls: [[UUID]] { lock.lock(); defer { lock.unlock() }; return seen }

    /// The `language` of each call.
    var languages: [String?] { lock.lock(); defer { lock.unlock() }; return seenLanguages }

    private func record(_ ids: [UUID], _ language: String?) {
        lock.lock(); seen.append(ids); seenLanguages.append(language); lock.unlock()
    }

    func recognize(strokes: [Stroke], language: String?) async throws -> Recognition {
        record(strokes.map(\.id), language)
        await gate?.pass()
        if fail { throw CocoaError(.fileReadUnknown) }
        return Recognition(engine: "fake-1", text: "fake \(strokes.count)",
                           words: [.init(text: "fake", box: .init(x: 1, y: 2, w: 3, h: 4))])
    }
}

extension TS {
    /// Opens a copy of the fixture vault, unlocked (the copy and the read run off the main actor).
    @concurrent static func unlockedFixture() async throws -> (Vault, URL) {
        let (url, key) = try await ModelFixture.vault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        return (try Vault.open(at: url, identities: [identity]), url)
    }
}

/// A `FileCoordinating` that records the URLs it was asked to coordinate (review of #28): the model's coordinated
/// reads of a provider's folder go through `services.files`, and nothing else does.
final class RecordingFiles: FileCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var readURLs: [URL] = []
    private var writeURLs: [URL] = []

    var reads: [URL] { lock.withLock { readURLs } }
    var writes: [URL] { lock.withLock { writeURLs } }

    func coordinateReading<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        lock.withLock { readURLs.append(url) }
        return try body()
    }

    func coordinateWriting<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        lock.withLock { writeURLs.append(url) }
        return try body()
    }

    /// Whether a read of `url` (standardized) was coordinated.
    func read(_ url: URL) -> Bool { reads.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path } }
}
