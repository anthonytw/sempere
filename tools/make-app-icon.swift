// Placeholder app icon (a fountain-pen nib), drawn from shapes only: no font glyphs.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let n = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha channel: App Store icons must be opaque.
let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!
}
// Background: deep ink blue, lighter toward the top.
let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x1F, 0x3A, 0x6B), rgb(0x0B, 0x16, 0x2E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(n)), end: CGPoint(x: 0, y: 0), options: [])

// A fountain-pen nib pointing down, centred, slightly tilted.
ctx.translateBy(x: 512, y: 560)
let cream = rgb(0xF4, 0xEB, 0xD6)
let nib = CGMutablePath()
nib.move(to: CGPoint(x: 0, y: -330))                       // tip
nib.addCurve(to: CGPoint(x: 190, y: 120), control1: CGPoint(x: 70, y: -200), control2: CGPoint(x: 200, y: -40))
nib.addLine(to: CGPoint(x: 150, y: 300))
nib.addLine(to: CGPoint(x: -150, y: 300))
nib.addLine(to: CGPoint(x: -190, y: 120))
nib.addCurve(to: CGPoint(x: 0, y: -330), control1: CGPoint(x: -200, y: -40), control2: CGPoint(x: -70, y: -200))
nib.closeSubpath()
ctx.addPath(nib); ctx.setFillColor(cream); ctx.fillPath()
// Slit and breather hole in the background colour.
ctx.setFillColor(rgb(0x14, 0x27, 0x4C))
ctx.fillEllipse(in: CGRect(x: -34, y: 30, width: 68, height: 68))
ctx.setStrokeColor(rgb(0x14, 0x27, 0x4C)); ctx.setLineWidth(14); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 0, y: 40)); ctx.addLine(to: CGPoint(x: 0, y: -300)); ctx.strokePath()
// Collar band.
ctx.setFillColor(rgb(0xC9, 0xA2, 0x5A))
ctx.fill(CGRect(x: -150, y: 300, width: 300, height: 46))
// An ink drop under the tip.
ctx.setFillColor(cream)
let tipX: CGFloat = 0, tipY: CGFloat = -330
ctx.fillEllipse(in: CGRect(x: tipX - 30, y: tipY - 110, width: 60, height: 60))

let image = ctx.makeImage()!
// Writes the 1024 px opaque placeholder icon: swift tools/make-app-icon.swift Apps/Sempere/SempereApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
precondition(CGImageDestinationFinalize(dest))
