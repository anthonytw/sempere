import Foundation
import PencilKit
import Sempere
import SempereRender
import Testing
import UIKit
import os
@testable import SempereApp

/// Baselines of `DensePerformanceTests`, measured on the Mac (Mac Catalyst) with the sizes below.
/// Update them with `SEMPERE_PERF_RECORD=1` (docs/ci.md "Performance tests"): the run prints a
/// `PERF-BASELINE "key": value,` line per metric, to paste here. They are the machine that wrote them; a test fails only when a value is more than
/// `PerfGate.factor` times its baseline (plus a small absolute allowance), so a slower or busier Mac does
/// not trip it, and a return to a per-frame cost that grows with the note does.
enum PerfBaselines {
    /// Worst of two runs on an Apple silicon Mac, 2026-10-19. Milliseconds, except `memory.*` (megabytes) and `*.over` (frames).
    static let mac: [String: Double] = [
        "memory.paged.afterScroll_mb": 265.13,
        "memory.paged.opened_mb": 227.03,
        "memory.pageless.afterScroll_mb": 212.22,
        "open.paged.firstScreen_ms": 77.15,
        "open.paged.read_ms": 2185.49,
        "open.pageless.firstScreen_ms": 536.41,
        "open.pageless.read_ms": 1219.72,
        "scroll.paged.framesOver": 0,
        "scroll.paged.hitchMax_ms": 1.27,
        "scroll.paged.hitchP95_ms": 1.10,
        "scroll.paged.secondPassHitchP95_ms": 1.15,
        "scroll.pageless.framesOver": 1,
        "scroll.pageless.paperLayers": 5,
        "scroll.pageless.hitchMax_ms": 57.10,
        "scroll.pageless.hitchP95_ms": 0.79,
        "zoom.paged.hitchMax_ms": 35.79,
        "zoom.paged.hitchP95_ms": 21.28,
        "zoom.pageless.hitchMax_ms": 1.24,
        "zoom.pageless.hitchP95_ms": 0.69,
    ]
}

/// Compares a measured value with its baseline, or records it.
enum PerfGate {
    /// A value may be this many times its baseline.
    static let factor = Double(ProcessInfo.processInfo.environment["SEMPERE_PERF_FACTOR"] ?? "") ?? 3
    static let record = ProcessInfo.processInfo.environment["SEMPERE_PERF_RECORD"] != nil

    /// Only Mac Catalyst has baselines: the simulator draws ink without the GPU (about 100 times slower).
    static let enforced: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return !record
        #endif
    }()

    /// Prints `PERF-REPORT key value` and, on the Mac, expects `value <= baseline * factor + slack`.
    static func check(_ key: String, _ value: Double, slack: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        print(String(format: "PERF-REPORT dense %@ %.2f", key, value))
        if record { print(String(format: "PERF-BASELINE \"%@\": %.2f,", key, value)) }
        guard enforced else { return }
        guard let base = PerfBaselines.mac[key] else {
            Issue.record("no baseline for \(key) (\(String(format: "%.2f", value))): run with SEMPERE_PERF_RECORD=1",
                         sourceLocation: sourceLocation)
            return
        }
        let limit = base * factor + slack
        #expect(value <= limit, "\(key): \(String(format: "%.2f", value)) against a baseline of \(base) (limit \(String(format: "%.2f", limit)))",
                sourceLocation: sourceLocation)
    }
}

/// Frame pacing of a scripted scroll or zoom: each frame is one step, its layout and Core Animation
/// commit, then the run loop runs (the background loads and canvas callbacks a real scroll lets in)
/// until the 60 Hz frame budget is over. What a frame costs beyond the budget is the hitch.
struct FramePacing {
    static let budget = 1000.0 / 60

    var hitches: [Double] = []

    /// Runs one frame: `step` moves the view, then the run loop turns until the budget ends.
    @MainActor
    mutating func frame(_ view: UIView, _ step: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = Date(timeIntervalSinceNow: Self.budget / 1000)
        step()
        view.layoutIfNeeded()
        CATransaction.flush()
        while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        hitches.append(max(ms - Self.budget, 0))
    }

    func percentile(_ p: Double) -> Double {
        let sorted = hitches.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    var worst: Double { hitches.max() ?? 0 }
    /// Frames that missed the budget by more than a frame (two or more dropped).
    var over: Double { Double(hitches.filter { $0 > Self.budget }.count) }
}

/// The owner's complaint on a dense note: scroll and zoom were jerky compared with Notability, and a
/// long note opened slowly. These tests open generated dense notes (`DenseNote`, what `sempere notes
/// dense` writes) through the app's real paths, script a scroll and a pinch, and compare open time,
/// frame hitches and memory with the baselines above (`PerfBaselines`). Mac Catalyst only enforces
/// them; they run in `scripts/app.sh test-mac-perf` (`local-ci.sh --testflight`), not in the PR gate.
/// Timings are also signposted (`Perf`, the `note.open` and `note.firstRender` intervals), so the same
/// phases show in Instruments.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(20)))
struct DensePerformanceTests {
    /// Strokes and pictures of the paged note: a long lecture's worth (the owner's largest real note
    /// has 15 554). The simulator draws ink without the GPU, so it gets a tenth.
    static let pages = 40
    static let strokes = InkFixture.scaled(30_000)
    static let images = 16

    /// The footprint in MB, after the allocator gave back what an earlier test freed (each test's own
    /// growth is what is compared, not what the process held from the one before).
    static func footprintMB() -> Double {
        malloc_zone_pressure_relief(nil, 0)
        return Double(InkPathBenchmarkTests.footprint()) / 1_048_576
    }
    static func ms(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// A dense note written into a copy of the fixture vault.
    static func make(pageless: Bool, strokes: Int = strokes, pages: Int = pages, images: Int = images) throws
        -> (vault: Vault, note: UUID, pages: [UUID]) {
        let (vault, _) = try TS.unlockedFixture()
        var spec = DenseNote(title: "Dense")
        spec.pages = pages; spec.strokes = strokes; spec.images = images; spec.imageSize = 256; spec.pageless = pageless
        spec.seed = 7
        let written = try spec.write(to: vault, deviceState: TS.deviceStateURL(), app: "perf/1")
        return (vault, written.note, written.pages)
    }

    static func open(_ vault: Vault, _ note: UUID) async throws -> NoteEditor {
        try await NoteEditor.open(vault: vault, noteID: note, clock: try DeviceClock(url: TS.deviceStateURL()),
                                  debounce: .seconds(600))
    }

    /// Waits for every shown canvas of the stack to have its ink.
    static func settle(_ stack: PageStackHost, timeout: Duration = .seconds(180)) async -> Bool {
        await TS.waitUntil(timeout: timeout) {
            stack.slots.values.allSatisfy { !$0.host.isPreparing && !$0.coordinator.isLoading }
        }
    }

    // MARK: Open

    /// Opening the dense paged note: the editor (read, decrypt, reduce) and the first screen of the stack
    /// (the visible pages' canvases with their ink and pictures). Median of three.
    @Test func openingADensePagedNote() async throws {
        let made = try Self.make(pageless: false)
        var read: [Double] = [], first: [Double] = []
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let editor = try await Self.open(made.vault, made.note)
            read.append(Self.ms(since: t0))
            #expect(editor.pages.count == Self.pages)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let (window, stack) = StackTS.stack(editor)
            #expect(await Self.settle(stack))
            first.append(Self.ms(since: t1))
            #expect(stack.slots.count < Self.pages, "pages are made lazily: \(stack.slots.count) canvases")
            window.isHidden = true
            await editor.close()
        }
        PerfGate.check("open.paged.read_ms", Self.median(read), slack: 200)
        PerfGate.check("open.paged.firstScreen_ms", Self.median(first), slack: 200)
    }

    /// The same for one long pageless page.
    @Test func openingADensePagelessNote() async throws {
        let made = try Self.make(pageless: true, strokes: InkFixture.denseStrokes, images: 8)
        var read: [Double] = [], first: [Double] = []
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let editor = try await Self.open(made.vault, made.note)
            read.append(Self.ms(since: t0))
            let t1 = DispatchTime.now().uptimeNanoseconds
            let i = try InkInjector(editor: editor)
            #expect(await i.ready(timeout: .seconds(180)))
            first.append(Self.ms(since: t1))
            #expect(i.strokes.count == InkFixture.denseStrokes)
            i.close()
            await editor.close()
        }
        PerfGate.check("open.pageless.read_ms", Self.median(read), slack: 200)
        PerfGate.check("open.pageless.firstScreen_ms", Self.median(first), slack: 200)
    }

    // MARK: Scroll and zoom, paged

    /// Scrolls the whole dense paged note top to bottom and back at reading speed (80 points a frame is
    /// 4800 points a second), then pinches in and out, as a person does; frame hitches and the memory the
    /// note holds are compared with the baselines. A second pass must not grow the footprint (canvases are
    /// recycled, `PageStackHost.spareLimit`).
    @Test func scrollingAndZoomingADensePagedNote() async throws {
        let made = try Self.make(pageless: false)
        let before = Self.footprintMB()
        let editor = try await Self.open(made.vault, made.note)
        let (window, stack) = StackTS.stack(editor)
        defer { window.isHidden = true }
        #expect(await Self.settle(stack))
        let opened = Self.footprintMB() - before
        let scroller = stack.scroller
        let far = max(scroller.contentSize.height - scroller.bounds.height, 0)
        #expect(far > scroller.bounds.height * 20, "a long note: \(far) points")

        func pass() async -> FramePacing {
            var pacing = FramePacing()
            var y: CGFloat = 0
            while y < far {
                pacing.frame(stack) { scroller.contentOffset = CGPoint(x: 0, y: y) }
                y += 80
            }
            while y > 0 {
                pacing.frame(stack) { scroller.contentOffset = CGPoint(x: 0, y: y) }
                y -= 80
            }
            _ = await Self.settle(stack)
            return pacing
        }
        let first = await pass()
        let afterFirst = Self.footprintMB() - before
        let second = await pass()
        let afterSecond = Self.footprintMB() - before
        PerfGate.check("scroll.paged.hitchP95_ms", first.percentile(0.95), slack: 6)
        PerfGate.check("scroll.paged.hitchMax_ms", first.worst, slack: 60)
        PerfGate.check("scroll.paged.framesOver", first.over, slack: 20)
        PerfGate.check("scroll.paged.secondPassHitchP95_ms", second.percentile(0.95), slack: 6)
        #expect(stack.slots.count <= 12, "canvases are recycled, not kept for every page: \(stack.slots.count)")

        // A pinch out to 2x and back below the fit: the scroll view's transform per frame, the baked scale at its end.
        var zoom = FramePacing()
        scroller.contentOffset = CGPoint(x: 0, y: far / 2)
        var steps: [CGFloat] = []
        for k in 0..<30 { steps.append(CGFloat(1 + Double(k) / 30)) }
        for k in 0..<30 { steps.append(CGFloat(2 - 1.5 * Double(k) / 30)) }
        for z in steps { zoom.frame(stack) { scroller.zoomScale = z } }
        stack.bake()
        #expect(scroller.zoomScale == 1)
        #expect(await Self.settle(stack))
        PerfGate.check("zoom.paged.hitchP95_ms", zoom.percentile(0.95), slack: 6)
        PerfGate.check("zoom.paged.hitchMax_ms", zoom.worst, slack: 60)

        PerfGate.check("memory.paged.opened_mb", max(opened, 0), slack: 60)
        PerfGate.check("memory.paged.afterScroll_mb", max(afterFirst, 0), slack: 60)
        // The second pass over the same pages holds no more than the first (recycling, caches bounded).
        #expect(afterSecond - afterFirst < max(40, afterFirst * 0.25),
                "a second pass grew the footprint from \(afterFirst) to \(afterSecond) MB")
        await editor.close()
    }

    // MARK: Scroll and zoom, pageless

    /// The owner's note: one long pageless ruled page of tens of thousands of strokes (an import from
    /// Notability), scrolled and pinched. The ruling is drawn only near the screen (PR #38,
    /// `thePaperIsDrawnNearTheScreenOnly` checks its layers): a return to one layer per note is a hitch of
    /// hundreds of milliseconds a frame here.
    @Test func scrollingAndZoomingADensePagelessNote() async throws {
        let made = try Self.make(pageless: true, strokes: InkFixture.denseStrokes, images: 8)
        let before = Self.footprintMB()
        let editor = try await Self.open(made.vault, made.note)
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        i.host.apply(paper: CanvasZoomScrollTests.ruled, pageSize: editor.pageSize)
        i.host.layoutIfNeeded()
        #expect(await i.ready(timeout: .seconds(180)))
        let canvas = i.host.canvas
        let fit = CanvasZoomScrollTests.fit(i.host)
        let far = max(canvas.contentSize.height - canvas.bounds.height, 0)
        #expect(far > canvas.bounds.height * 8, "a long page: \(far)")
        var scroll = FramePacing()
        var y: CGFloat = 0
        let paper = canvas.subviews.compactMap { $0 as? PaperView }.first
        var layers = 0   // the most ruling layers any screen of the scroll held (deterministic, unlike a time)
        while y < far {
            scroll.frame(i.host) { canvas.contentOffset = CGPoint(x: 0, y: y) }
            layers = max(layers, paper?.shapeLayerCount ?? 0)
            y += 80
        }
        var zoom = FramePacing()
        var steps: [CGFloat] = []
        for k in 0..<30 { steps.append(fit * (1 + CGFloat(k) / 30)) }
        for k in 0..<30 { steps.append(fit * (2 - 1.4 * CGFloat(k) / 30)) }
        for z in steps { zoom.frame(i.host) { canvas.zoomScale = z } }
        PerfGate.check("scroll.pageless.paperLayers", Double(layers), slack: 4)
        PerfGate.check("scroll.pageless.hitchP95_ms", scroll.percentile(0.95), slack: 6)
        PerfGate.check("scroll.pageless.hitchMax_ms", scroll.worst, slack: 60)
        PerfGate.check("scroll.pageless.framesOver", scroll.over, slack: 20)
        PerfGate.check("zoom.pageless.hitchP95_ms", zoom.percentile(0.95), slack: 6)
        PerfGate.check("zoom.pageless.hitchMax_ms", zoom.worst, slack: 60)
        PerfGate.check("memory.pageless.afterScroll_mb", max(Self.footprintMB() - before, 0), slack: 60)
        await editor.close()
    }
}
