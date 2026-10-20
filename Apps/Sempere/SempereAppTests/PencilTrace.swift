import Foundation
import PencilKit
import Sempere
import UIKit
@testable import SempereApp

/// Synthetic Apple Pencil input at PencilKit level: control points with the force, azimuth, altitude,
/// opacity and timing a Pencil reports (sizes as PencilKit records them for the tool), the way a
/// stroke arrives at `canvasViewDrawingDidChange`; for tests that check the app saves and renders
/// what the pen did (`InkRoundTripTests`, `RecordingRelaunchTests`). Seeded, so a run repeats. Fed to
/// the canvas by `InkInjector.drawCanvas`.
struct PencilTrace {
    var tool: InkTool = .pen
    var color = UIColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1)
    /// The tool's nominal width, as the palette sets it.
    var width: Double = 3
    var points = 48
    var start = CGPoint(x: 80, y: 120)
    /// Point spacing along x, and the amplitude of the vertical wave.
    var step: Double = 3.5
    var amplitude: Double = 14
    var seed: UInt64 = 1
    /// The creation date of the path (what a recording link is stamped from).
    var created = Date()

    /// The `PKInkingTool` the palette would hold for this trace.
    var inkingTool: PKInkingTool { PKInkingTool(tool.pkInkType, color: color, width: CGFloat(width)) }

    func stroke() -> PKStroke {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var t = 0.0
        var pts: [PKStrokePoint] = []
        for i in 0..<points {
            let u = Double(i) / Double(points - 1)
            // A pressure ramp up and down, a pen that turns (azimuth sweeps half a turn) and tilts (altitude
            // 0.6 to 1.3 rad), samples 6 to 10 ms apart, as a 120 Hz Pencil delivers them.
            let force = 0.08 + 0.9 * sin(u * .pi)
            t += 0.006 + Double(next() % 5) / 1000
            let size = CGFloat(width * (0.6 + 0.8 * force)) / 2 + 2
            let location = CGPoint(x: start.x + Double(i) * step, y: start.y + amplitude * sin(u * 5 * .pi))
            pts.append(PKStrokePoint(location: location, timeOffset: t, size: CGSize(width: size, height: size),
                                     opacity: CGFloat(0.5 + 0.5 * force), force: CGFloat(force),
                                     azimuth: CGFloat(u * .pi - .pi / 2), altitude: CGFloat(0.6 + 0.7 * u)))
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: created)
        return PKStroke(ink: PKInk(tool.pkInkType, color: color), path: path)
    }
}
