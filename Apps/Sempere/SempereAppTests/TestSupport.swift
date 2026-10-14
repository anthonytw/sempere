import Foundation
import Sempere
import PencilKit
@testable import SempereApp

/// Test helpers shared by the app test suites.
enum TS {
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

    /// A stroke as the canvas would report it once drawn.
    static func canvasStroke(_ s: Stroke, created: Date = Date()) -> PKStroke {
        let path = PKStrokePath(controlPoints: s.points.map { $0.pkStrokePoint(tool: s.ink.tool) }, creationDate: created)
        return PKStroke(ink: PKInk(s.ink.tool.pkInkType, color: s.ink.color.uiColor), path: path,
                        transform: (s.transform ?? .identity).cgAffineTransform)
    }

    /// Ledger items for canvas strokes.
    static func items(_ strokes: [PKStroke]) -> [StrokeLedger.Item] {
        StrokeLedger.items(for: PKDrawing(strokes: strokes), tool: nil)
    }

    /// A temporary device-state file.
    static func deviceStateURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("device.json")
    }

    /// The summary-cache files in `dir` (the index; markers and other files aside).
    static func summaryFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".summaries") }
    }

    /// Another device writes `ops` into note `id`: a new revision file in the
    /// note's folder, as iCloud Drive delivers it.
    static func writeAsAnotherDevice(_ ops: [Op], to id: UUID, vault url: URL, key: URL) throws {
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

    /// Opens the fixture vault copy, unlocked.
    @MainActor
    static func unlockedFixture() throws -> (Vault, URL) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        return (try Vault.open(at: url, identities: [identity]), url)
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

    /// Lets the oldest call waiting at the closed gate through; the gate
    /// stays closed for the calls after it.
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
