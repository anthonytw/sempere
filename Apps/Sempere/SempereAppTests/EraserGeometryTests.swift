import Foundation
import Testing
@testable import SempereApp

/// The object eraser's hit-testing (pure geometry, no PencilKit).
struct EraserGeometryTests {
    typealias S = StrokeHitShape.Sample

    /// A horizontal line from (0, 0) to (100, 0), sampled every `step`, half-width `r`.
    static func line(step: Double = 2, r: Double = 1) -> StrokeHitShape {
        StrokeHitShape(runs: [stride(from: 0.0, through: 100, by: step).map { S(x: $0, y: 0, radius: r) }])
    }

    static func p(_ x: Double, _ y: Double) -> EraserPoint { EraserPoint(x: x, y: y) }

    @Test func pointSegmentDistance() {
        #expect(EraserGeometry.distanceSquared(point: Self.p(5, 3), segment: Self.p(0, 0), Self.p(10, 0)) == 9)
        #expect(EraserGeometry.distanceSquared(point: Self.p(-3, 4), segment: Self.p(0, 0), Self.p(10, 0)) == 25)
        #expect(EraserGeometry.distanceSquared(point: Self.p(3, 4), segment: Self.p(0, 0), Self.p(0, 0)) == 25)
    }

    @Test func segmentDistanceIsZeroWhenSegmentsCross() {
        #expect(EraserGeometry.distanceSquared(segment: Self.p(0, -5), Self.p(0, 5), segment: Self.p(-5, 0), Self.p(5, 0)) == 0)
        #expect(EraserGeometry.distanceSquared(segment: Self.p(0, 0), Self.p(10, 0), segment: Self.p(0, 2), Self.p(10, 2)) == 4)
        // Collinear, overlapping.
        #expect(EraserGeometry.distanceSquared(segment: Self.p(0, 0), Self.p(10, 0), segment: Self.p(5, 0), Self.p(20, 0)) == 0)
    }

    @Test func tapHitsWithinRadiusPlusInkWidth() {
        let line = Self.line(r: 1)
        #expect(line.intersects(sweepFrom: Self.p(50, 4.9), to: Self.p(50, 4.9), radius: 4))
        #expect(!line.intersects(sweepFrom: Self.p(50, 5.1), to: Self.p(50, 5.1), radius: 4))
        #expect(line.intersects(sweepFrom: Self.p(50, 16.9), to: Self.p(50, 16.9), radius: 16))
        // Past the end cap.
        #expect(!line.intersects(sweepFrom: Self.p(106, 0), to: Self.p(106, 0), radius: 4))
        #expect(line.intersects(sweepFrom: Self.p(104.5, 0), to: Self.p(104.5, 0), radius: 4))
    }

    @Test func fastSwipeAcrossTheStrokeHitsBetweenSamples() {
        // Two touch samples far above and below the line: the swept capsule
        // crosses it although neither sample is near it.
        let line = Self.line()
        #expect(line.intersects(sweepFrom: Self.p(50, -200), to: Self.p(50, 200), radius: 4))
        #expect(!line.intersects(sweepFrom: Self.p(150, -200), to: Self.p(150, 200), radius: 4))
    }

    @Test func sparseStrokeSamplesStillHitBetweenThem() {
        // Samples 50 pt apart: a tap midway between them is on the segment.
        let line = StrokeHitShape(runs: [[S(x: 0, y: 0, radius: 1), S(x: 50, y: 0, radius: 1), S(x: 100, y: 0, radius: 1)]])
        #expect(line.intersects(sweepFrom: Self.p(25, 2), to: Self.p(25, 2), radius: 4))
    }

    @Test func maskedRunsLeaveGapsUnhittable() {
        // A stroke whose middle was pixel-erased: two runs with a gap at 40...60.
        let shape = StrokeHitShape(runs: [
            stride(from: 0.0, through: 40, by: 2).map { S(x: $0, y: 0, radius: 1) },
            stride(from: 60.0, through: 100, by: 2).map { S(x: $0, y: 0, radius: 1) },
        ])
        #expect(!shape.intersects(sweepFrom: Self.p(50, 0), to: Self.p(50, 0), radius: 4))
        #expect(shape.intersects(sweepFrom: Self.p(30, 0), to: Self.p(30, 0), radius: 4))
    }

    @Test func emptyAndSinglePointShapes() {
        #expect(!StrokeHitShape(runs: []).intersects(sweepFrom: Self.p(0, 0), to: Self.p(0, 0), radius: 100))
        #expect(!StrokeHitShape(runs: [[]]).intersects(sweepFrom: Self.p(0, 0), to: Self.p(0, 0), radius: 100))
        let dot = StrokeHitShape(runs: [[S(x: 10, y: 10, radius: 2)]])
        #expect(dot.intersects(sweepFrom: Self.p(0, 10), to: Self.p(20, 10), radius: 1))
        #expect(!dot.intersects(sweepFrom: Self.p(0, 14), to: Self.p(20, 14), radius: 1))
    }

    @Test func hitsReportsEveryTouchedShape() {
        let a = Self.line()
        let b = StrokeHitShape(runs: [[S(x: 0, y: 50, radius: 1), S(x: 100, y: 50, radius: 1)]])
        let c = StrokeHitShape(runs: [[S(x: 0, y: 100, radius: 1), S(x: 100, y: 100, radius: 1)]])
        #expect(EraserGeometry.hits([a, b, c], sweepFrom: Self.p(20, -10), to: Self.p(20, 60), radius: 2) == [0, 1])
    }

    @Test func sizePresetsPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "EraserGeometryTests-\(UUID().uuidString)"))
        #expect(ObjectEraserSize.load(from: defaults) == ObjectEraserSize.defaultRadius)
        ObjectEraserSize.save(32, to: defaults)
        #expect(ObjectEraserSize.load(from: defaults) == 32)
        defaults.set(5.5, forKey: ObjectEraserSize.defaultsKey)   // not a preset
        #expect(ObjectEraserSize.load(from: defaults) == ObjectEraserSize.defaultRadius)
        #expect(ObjectEraserSize.radii == ObjectEraserSize.radii.sorted())
        #expect(ObjectEraserSize.radii.contains(ObjectEraserSize.defaultRadius))
    }
}

/// `StrokeBoundsGrid`: every box that overlaps a query is a candidate.
struct StrokeBoundsGridTests {
    typealias Box = StrokeBoundsGrid.Box

    static func overlaps(_ a: Box, _ q: Box) -> Bool {
        !(a.maxX < q.minX || a.minX > q.maxX || a.maxY < q.minY || a.minY > q.maxY)
    }

    @Test func candidatesIncludeEveryOverlappingBox() {
        var rng = SystemRandomNumberGenerator()
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }
        var boxes: [Box] = (0..<500).map { _ in
            let x = r(-100, 900), y = r(-100, 1200)
            return Box(minX: x, minY: y, maxX: x + r(0, 300), maxY: y + r(0, 80))
        }
        // Boxes the grid cannot bucket: empty (CGRect.null), not finite, inverted, huge, far away.
        boxes += [Box(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity),
                  Box(minX: .nan, minY: 0, maxX: 10, maxY: 10),
                  Box(minX: 50, minY: 50, maxX: 40, maxY: 60),
                  Box(minX: -1e9, minY: -1e9, maxX: 1e9, maxY: 1e9),
                  Box(minX: 1e300, minY: 0, maxX: 1e300, maxY: 1)]
        let grid = StrokeBoundsGrid(boxes)
        for _ in 0..<300 {
            let x = r(-200, 1000), y = r(-200, 1300), w = r(0, 120)
            let q = Box(minX: x, minY: y, maxX: x + w, maxY: y + w)
            let found = grid.candidates(q)
            #expect(found == found.sorted() && Set(found).count == found.count)
            let wanted = boxes.indices.filter { Self.overlaps(boxes[$0], q) }
            #expect(Set(wanted).isSubset(of: Set(found)))
            #expect(found.contains(boxes.count - 5) && found.contains(boxes.count - 4), "boxes that are not finite always are")
        }
        #expect(grid.candidates(Box(minX: .nan, minY: 0, maxX: 1, maxY: 1)) == Array(boxes.indices))
    }
}
