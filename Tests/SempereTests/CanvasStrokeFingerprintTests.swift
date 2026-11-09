import Foundation
import XCTest
@testable import Sempere

/// The layout of a canvas stroke's fingerprint and its cheap "unchanged" test, from plain numbers
/// (`CanvasStrokeFingerprint.swift`). The app reads the numbers off a `PKStroke`; its own tests
/// (`StrokeLedgerEditSequenceTests`, `StrokeLedgerIncrementalTests`) check that against PencilKit.
final class CanvasStrokeFingerprintTests: XCTestCase {
    typealias Info = CanvasStrokeInfo
    typealias P = CanvasStrokeInfo.PathPoint

    /// A stroke as the app would read it.
    struct Canvas {
        var id = UUID()
        var ink = "PKInkTypePen"
        var color = Color(r: 10, g: 20, b: 30, a: 255)
        var transform = Transform(a: 1, b: 0, c: 0, d: 1, tx: 3, ty: 4)
        var created = 0.0
        var seed: UInt32 = 77
        var points: [P] = (0..<30).map { P(x: Double($0) * 2, y: Double($0 % 7), width: 3, time: Double($0) / 100, force: 0.5) }
        var ranges: [ClosedRange<Double>]?

        var bounds: CanvasStrokeInfo.Bounds { .init(minX: 0, minY: 0, maxX: 60, maxY: 10) }

        func info() -> Info {
            Info(ink: ink, color: color, transform: transform, created: created, seed: seed, count: points.count, ranges: ranges,
                 bounds: bounds, canvasID: id, point: { points[$0] })
        }

        func unchanged(_ info: Info) -> Bool {
            info.isUnchanged(id: id, ink: ink, color: { color }, transform: transform, created: created, seed: seed,
                             count: points.count, ranges: { ranges }, point: { points[$0] })
        }
    }

    func testSampledIndicesAreTheSortedSet() {
        for n in 0..<400 {
            let expected = n > 0 ? Set([0, n / 3, n / 2, (2 * n) / 3, n - 1]).sorted() : []
            XCTAssertEqual(Info.sampled(n), expected, "n = \(n)")
            XCTAssertEqual(Info.sampledCount(n), expected.count)
        }
    }

    func testTheKeyLayoutIsTheFamilyThenCountSeedSamplesAndMaskRanges() {
        var c = Canvas()
        c.created = 12.5
        let info = c.info()
        // 11 family values, count, seed, then 5 numbers per sampled point.
        XCTAssertEqual(Array(info.key.values.prefix(13)), [10, 20, 30, 255, 1, 0, 0, 1, 3, 4, 12.5, 30, 77])
        XCTAssertEqual(info.key.values.count, 13 + 5 * Info.sampledCount(30))
        XCTAssertEqual(Array(info.key.values[13..<18]), [0, 0, 3, 0, 0.5], "x, y, nib width, time, force of point 0")
        XCTAssertEqual(info.family.values, Array(info.key.values.prefix(10)) + [12.5])
        XCTAssertEqual(info.family.created, 12.5)
        XCTAssertEqual(info.key.ink, "PKInkTypePen")
        XCTAssertEqual(info.family.ink, "PKInkTypePen")
        XCTAssertEqual(info.pathSignature, [30, 0, 0, 58, Double(29 % 7)])
        XCTAssertEqual(info.canvasID, c.id)
        XCTAssertEqual(info.bounds, c.bounds)
        c.ranges = [0...10, 20...29]
        XCTAssertEqual(c.info().key.values.suffix(5), [-1, 0, 10, 20, 29])
    }

    func testAnEmptyStrokeHasAShortKeyAndSignature() {
        var c = Canvas()
        c.points = []
        let info = c.info()
        XCTAssertEqual(info.key.values.count, 13)
        XCTAssertEqual(info.pathSignature, [0])
        XCTAssertTrue(c.unchanged(info))
    }

    func testFingerprintsAreEqualForEqualStrokesAndDifferForEveryKeyedEdit() {
        let base = Canvas()
        XCTAssertEqual(base.info(), Canvas(id: base.id).info())
        func differs(_ edit: (inout Canvas) -> Void) -> Bool {
            var c = base
            edit(&c)
            return c.info().key != base.info().key
        }
        XCTAssertTrue(differs { $0.ink = "PKInkTypePencil" })
        XCTAssertTrue(differs { $0.color.r = 11 })
        XCTAssertTrue(differs { $0.transform.tx = 9 })
        XCTAssertTrue(differs { $0.created = 1 })
        XCTAssertTrue(differs { $0.seed = 78 })
        XCTAssertTrue(differs { $0.points.removeLast() })
        XCTAssertTrue(differs { $0.points[0].x = 1 })
        XCTAssertTrue(differs { $0.points[29].force = 0.1 })
        XCTAssertTrue(differs { $0.ranges = [0...29] })
        XCTAssertFalse(differs { $0.id = UUID() }, "the canvas id is not part of the key")
        XCTAssertFalse(differs { $0.points[1].x = 99 }, "points between the samples are not read")
    }

    func testIsUnchangedHoldsForTheSameStrokeWithOrWithoutAMask() {
        var c = Canvas()
        XCTAssertTrue(c.unchanged(c.info()))
        c.ranges = [0...12.5, 20...29]
        XCTAssertTrue(c.unchanged(c.info()))
    }

    func testIsUnchangedCatchesEachEditTheKeyCarries() {
        let base = Canvas()
        let info = base.info()
        func unchanged(_ edit: (inout Canvas) -> Void) -> Bool {
            var c = base
            edit(&c)
            return c.unchanged(info)
        }
        XCTAssertTrue(unchanged { _ in })
        XCTAssertFalse(unchanged { $0.id = UUID() }, "another canvas stroke")
        XCTAssertFalse(unchanged { $0.ink = "PKInkTypeMarker" })
        XCTAssertFalse(unchanged { $0.color.b = 31 }, "recolored")
        XCTAssertFalse(unchanged { $0.color.a = 200 })
        XCTAssertFalse(unchanged { $0.transform.ty = 5 }, "moved")
        XCTAssertFalse(unchanged { $0.transform.a = 2 }, "resized")
        XCTAssertFalse(unchanged { $0.created = 5 })
        XCTAssertFalse(unchanged { $0.seed = 1 })
        XCTAssertFalse(unchanged { $0.points.append(P(x: 1, y: 1, width: 1, time: 1, force: 1)) }, "longer")
        XCTAssertFalse(unchanged { $0.points[0].y = 8 }, "first point")
        XCTAssertFalse(unchanged { $0.points[29].width = 4 }, "last point")
        XCTAssertFalse(unchanged { $0.ranges = [0...29] }, "masked")
        XCTAssertTrue(unchanged { $0.points[1].x = 99 }, "a point between the samples is not read (the costly read)")
        XCTAssertTrue(unchanged { $0.points[15].time = 9 }, "nor is a sampled one in the middle: only the end points are compared")
    }

    func testAMaskedFingerprintFailsWhenTheRangesChangeOrTheMaskIsGone() {
        var c = Canvas()
        c.ranges = [0...10, 20...29]
        let info = c.info()
        var other = c
        other.ranges = [0...10, 20...28]
        XCTAssertFalse(other.unchanged(info))
        other.ranges = [0...10]
        XCTAssertFalse(other.unchanged(info), "fewer ranges")
        other.ranges = nil
        XCTAssertFalse(other.unchanged(info), "unmasked")
    }

    func testAFingerprintWithoutACanvasIdIsNeverUnchanged() {
        let c = Canvas()
        var info = c.info()
        info.canvasID = nil
        XCTAssertFalse(c.unchanged(info))
    }

    func testTheCostlyReadsHappenOnlyAfterTheCheapOnesPass() {
        let c = Canvas()
        let info = c.info()
        var colorReads = 0, rangeReads = 0
        func check(id: UUID, seed: UInt32) -> Bool {
            info.isUnchanged(id: id, ink: c.ink, color: { colorReads += 1; return c.color }, transform: c.transform,
                             created: c.created, seed: seed, count: c.points.count,
                             ranges: { rangeReads += 1; return nil }, point: { c.points[$0] })
        }
        XCTAssertFalse(check(id: UUID(), seed: c.seed))
        XCTAssertFalse(check(id: c.id, seed: 0))
        XCTAssertEqual(colorReads + rangeReads, 0, "a different id or seed is settled before the color or the mask is read")
        XCTAssertTrue(check(id: c.id, seed: c.seed))
        XCTAssertEqual(colorReads, 1)
        XCTAssertEqual(rangeReads, 1)
    }

    func testColorFromUnitComponentsRoundsAndClamps() {
        XCTAssertEqual(Color(unitRed: 0, green: 1, blue: 0.5, alpha: 1), Color(r: 0, g: 255, b: 128, a: 255))
        XCTAssertEqual(Color(unitRed: -1, green: 2, blue: 0.2, alpha: 0.3), Color(r: 0, g: 255, b: 51, a: 77))
    }
}
