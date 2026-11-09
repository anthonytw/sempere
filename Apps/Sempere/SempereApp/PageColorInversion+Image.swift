import CoreGraphics
import Foundation
import SempereAppCore

extension PageColorInversion {
    /// `image` with every pixel's lightness inverted (alpha kept), or nil when it cannot be
    /// read. One pass over the pixels; call it off the main actor for large pictures.
    static func invertedImage(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 1 << 15, height <= 1 << 15 else { return nil }
        let bytesPerRow = width * 4
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        // Most pixels of a text box are transparent or one of a few ink colors: remember the last.
        var lastIn: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var lastOut: (UInt8, UInt8, UInt8) = (0, 0, 0)
        for i in stride(from: 0, to: bytesPerRow * height, by: 4) {
            let a = pixels[i + 3]
            guard a > 0 else { continue }
            let key = (pixels[i], pixels[i + 1], pixels[i + 2], a)
            if key != lastIn {
                // Premultiplied: divide by alpha, convert, multiply again.
                let alpha = Double(a) / 255
                let c = invert(r: Double(key.0) / 255 / alpha, g: Double(key.1) / 255 / alpha, b: Double(key.2) / 255 / alpha)
                lastIn = key
                lastOut = (byte(c.r * alpha), byte(c.g * alpha), byte(c.b * alpha))
            }
            pixels[i] = lastOut.0
            pixels[i + 1] = lastOut.1
            pixels[i + 2] = lastOut.2
        }
        return context.makeImage()
    }
}
