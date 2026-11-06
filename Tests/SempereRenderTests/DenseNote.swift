import Foundation
import Sempere

/// A page of dense random-walk ink: shared by the export tests that need a heavy page and by the render benchmarks
/// (`Tests/SempereRenderBenchmarks` compiles this file too, through a symlink).
enum DenseNote {
    static func make(strokes: Int, points: Int) -> NoteState {
        var state: UInt64 = 42
        func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let size = PageSize(width: 612, height: 792)
        var list: [Stroke] = []
        for _ in 0..<strokes {
            var x = 20 + unit() * 560, y = 20 + unit() * 740
            var heading = unit() * 2 * .pi
            var pts: [StrokePoint] = []
            for _ in 0..<points {
                heading += (unit() - 0.5) * 0.9
                x += cos(heading) * 0.8; y += sin(heading) * 0.8
                let w = 1.5 + unit()
                pts.append(StrokePoint(x: x, y: y, w: w, h: w, o: 1))
            }
            list.append(Stroke(ink: Ink(tool: .pen, color: .black, width: 2), points: pts, transform: nil))
        }
        return NoteState(meta: NoteMeta(title: "Test", created: Date(timeIntervalSince1970: 0), paper: .ruled, pageSize: size),
                         pages: [Page(order: "a0", strokes: list)])
    }
}
