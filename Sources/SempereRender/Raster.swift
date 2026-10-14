import Foundation

/// An RGBA8 image (straight, non-premultiplied alpha, row-major, top row first)
/// with an anti-aliased non-zero-winding polygon filler.
///
/// Coverage is exact horizontally and sampled `subRows` times vertically per
/// pixel, so edges get `subRows * (pixel width)` distinct levels. Overlapping
/// polygons in one `fill` call are a union (non-zero rule), exactly like a
/// single PDF `f` operator, so an overlapping ribbon is blended once.
struct Raster {
    /// Vertical samples per pixel row.
    static let subRows = 8

    let width: Int
    let height: Int
    /// `width * height * 4` bytes; starts fully transparent.
    private(set) var pixels: [UInt8]
    /// `fill`'s working arrays, kept between calls (a page fills once per
    /// stroke, and allocating and zeroing two rows each time cost more than
    /// small strokes' scanlines).
    private var scratch = Scratch()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    private struct Edge {
        var x0: Double, y0: Double, slope: Double
        var jStart: Int, jEnd: Int
        var dir: Int
    }

    /// A class so that copying a `Raster` does not copy the rows; `fill`
    /// replaces it when a copy shares it. `acc` and `delta` are all zero
    /// between calls (`fill` clears every entry it touches).
    private final class Scratch {
        var edges: [Edge] = []
        var acc: [Double] = []
        var delta: [Double] = []
        var active: [Int] = []
        var crossings: [(x: Double, dir: Int)] = []
    }

    /// Fills the union of `polygons` (device pixel coordinates, implicitly
    /// closed) with `paint`, blended "over" the existing pixels.
    mutating func fill(_ polygons: [[Point]], paint: Paint) {
        fill(polygons, shader: SolidShader(paint: paint))
    }

    /// Fills the union of `polygons` with the colour `shader` gives each
    /// pixel, scaled by the pixel's coverage, blended "over".
    mutating func fill<S: RasterShader>(_ polygons: [[Point]], shader: S) {
        guard width > 0, height > 0 else { return }
        let ss = Self.subRows
        let limit = Double(height * ss)
        if !isKnownUniquelyReferenced(&scratch) { scratch = Scratch() }
        let scratch = self.scratch
        scratch.edges.removeAll(keepingCapacity: true)
        for poly in polygons where poly.count >= 3 {
            for i in poly.indices {
                var a = poly[i], b = poly[(i + 1) % poly.count]
                guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, a.y != b.y else { continue }
                var dir = 1
                if a.y > b.y { swap(&a, &b); dir = -1 }
                // Sub-rows j whose sample line y = (j + 0.5) / ss lies in [a.y, b.y).
                let lo = max((a.y * Double(ss) - 0.5).rounded(.up), 0)
                let hi = min((b.y * Double(ss) - 0.5).rounded(.up), limit)
                guard lo < hi else { continue }
                scratch.edges.append(Edge(x0: a.x, y0: a.y, slope: (b.x - a.x) / (b.y - a.y),
                                  jStart: Int(lo), jEnd: Int(hi), dir: dir))
            }
        }
        guard !scratch.edges.isEmpty else { return }
        scratch.edges.sort { $0.jStart < $1.jStart }
        if scratch.acc.count != width + 1 {
            scratch.acc = [Double](repeating: 0, count: width + 1)
            scratch.delta = [Double](repeating: 0, count: width + 1)
        }
        // Moved out for the loop (no class access per pixel) and moved back at the end.
        let edges = scratch.edges
        var acc = scratch.acc, delta = scratch.delta
        var active = scratch.active, crossings = scratch.crossings
        scratch.acc = []; scratch.delta = []; scratch.active = []; scratch.crossings = []
        defer {
            active.removeAll(keepingCapacity: true)
            scratch.acc = acc; scratch.delta = delta; scratch.active = active; scratch.crossings = crossings
        }

        let inv = 1.0 / Double(ss)
        let w = Double(width)
        var rowMin = Int.max, rowMax = -1
        var next = 0
        var j = edges[0].jStart
        var row = j / ss

        func flush(_ r: Int) {
            guard rowMax >= 0 else { return }
            var run = 0.0
            for px in rowMin...rowMax {
                run += delta[px]
                let cov = min(acc[px] + run, 1)
                acc[px] = 0; delta[px] = 0
                if px < width, cov > 1.0 / 1024 { blend(x: px, y: r, color: shader.color(x: px, y: r), coverage: cov) }
            }
            rowMin = Int.max; rowMax = -1
        }

        while true {
            if active.isEmpty {
                guard next < edges.count else { break }
                j = max(j, edges[next].jStart)
            }
            if j / ss != row { flush(row); row = j / ss }
            while next < edges.count, edges[next].jStart <= j { active.append(next); next += 1 }
            active.removeAll { edges[$0].jEnd <= j }
            if !active.isEmpty {
                let ys = (Double(j) + 0.5) * inv
                crossings.removeAll(keepingCapacity: true)
                for e in active { crossings.append((edges[e].x0 + (ys - edges[e].y0) * edges[e].slope, edges[e].dir)) }
                crossings.sort { $0.x < $1.x }
                var winding = 0
                var start = 0.0
                for c in crossings {
                    let before = winding
                    winding += c.dir
                    if before == 0, winding != 0 { start = c.x }
                    else if before != 0, winding == 0 {
                        let xa = min(max(start, 0), w), xb = min(max(c.x, 0), w)
                        guard xb > xa else { continue }
                        let ia = Int(xa), ib = Int(xb)
                        if ia == ib {
                            acc[ia] += (xb - xa) * inv
                        } else {
                            acc[ia] += (Double(ia + 1) - xa) * inv
                            acc[ib] += (xb - Double(ib)) * inv
                            if ib > ia + 1 { delta[ia + 1] += inv; delta[ib] -= inv }
                        }
                        rowMin = min(rowMin, ia); rowMax = max(rowMax, ib)
                    }
                }
            }
            j += 1
            if j >= height * ss { break }
        }
        flush(row)
    }

    /// Composites a rasterized PDF page: every device pixel whose centre
    /// maps (through the inverse of `device`, effective page → device) into
    /// the crop and the page is sampled bilinearly from the image and blended
    /// over. Work is bounded by the frame's device bounding box.
    mutating func draw(_ r: RasterBackground, toDevice device: Affine) {
        guard width > 0, height > 0, let inv = device.inverse, inv.isFinite else { return }
        let c = r.crop
        let corners = [Point(x: c.x, y: c.y), Point(x: c.x + c.w, y: c.y), Point(x: c.x + c.w, y: c.y + c.h),
                       Point(x: c.x, y: c.y + c.h)].map(device.apply)
        guard let x0 = corners.map(\.x).min(), let x1 = corners.map(\.x).max(),
              let y0 = corners.map(\.y).min(), let y1 = corners.map(\.y).max(),
              x0.isFinite, x1.isFinite, y0.isFinite, y1.isFinite else { return }
        let px0 = max(0, Int(max(x0, -1).rounded(.down))), px1 = min(width - 1, Int(min(x1, Double(width)).rounded(.up)))
        let py0 = max(0, Int(max(y0, -1).rounded(.down))), py1 = min(height - 1, Int(min(y1, Double(height)).rounded(.up)))
        guard px0 <= px1, py0 <= py1 else { return }
        let img = r.image
        let kx = Double(img.width) / r.width, ky = Double(img.height) / r.height
        let lo = (x: max(c.x, 0), y: max(c.y, 0)), hi = (x: min(c.x + c.w, r.width), y: min(c.y + c.h, r.height))
        for py in py0...py1 {
            for px in px0...px1 {
                let e = inv.apply(Point(x: Double(px) + 0.5, y: Double(py) + 0.5))
                guard e.x >= lo.x, e.x < hi.x, e.y >= lo.y, e.y < hi.y else { continue }
                let (rgba, a) = Self.sample(img, x: e.x * kx - 0.5, y: e.y * ky - 0.5)
                guard a > 0 else { continue }
                blend(x: px, y: py, color: ShadedColor(r: Double(rgba.0), g: Double(rgba.1), b: Double(rgba.2), a: a), coverage: 1)
            }
        }
    }

    /// Bilinear sample (edge pixels extended); colour weighted by alpha.
    static func sample(_ img: RGBAImage, x: Double, y: Double) -> ((UInt8, UInt8, UInt8), Double) {
        let fx = min(max(x, 0), Double(img.width - 1)), fy = min(max(y, 0), Double(img.height - 1))
        let ix = Int(fx), iy = Int(fy)
        let jx = min(ix + 1, img.width - 1), jy = min(iy + 1, img.height - 1)
        let tx = fx - Double(ix), ty = fy - Double(iy)
        var acc = [0.0, 0.0, 0.0, 0.0]
        for (xx, yy, w) in [(ix, iy, (1 - tx) * (1 - ty)), (jx, iy, tx * (1 - ty)), (ix, jy, (1 - tx) * ty), (jx, jy, tx * ty)]
        where w > 0 {
            let i = (yy * img.width + xx) * 4
            let a = Double(img.pixels[i + 3]) / 255 * w
            acc[0] += Double(img.pixels[i]) * a; acc[1] += Double(img.pixels[i + 1]) * a
            acc[2] += Double(img.pixels[i + 2]) * a; acc[3] += a
        }
        guard acc[3] > 0 else { return ((0, 0, 0), 0) }
        func ch(_ v: Double) -> UInt8 { UInt8(min(max((v / acc[3]).rounded(), 0), 255)) }
        return ((ch(acc[0]), ch(acc[1]), ch(acc[2])), min(acc[3], 1))
    }

    private mutating func blend(x: Int, y: Int, color: ShadedColor, coverage: Double) {
        let sa = color.a * coverage
        guard sa > 0 else { return }
        let i = (y * width + x) * 4
        let da = Double(pixels[i + 3]) / 255
        let outA = sa + da * (1 - sa)
        guard outA > 0 else { return }
        let src = (color.r, color.g, color.b)
        for c in 0..<3 {
            let sc = c == 0 ? src.0 : c == 1 ? src.1 : src.2
            let v = (sc * sa + Double(pixels[i + c]) * da * (1 - sa)) / outA
            pixels[i + c] = UInt8(min(max(v.rounded(), 0), 255))
        }
        pixels[i + 3] = UInt8(min(max((outA * 255).rounded(), 0), 255))
    }
}

/// A colour with components 0...255 and alpha 0...1 (straight).
struct ShadedColor {
    var r: Double, g: Double, b: Double, a: Double
}

/// The colour of each pixel a `Raster.fill` covers.
protocol RasterShader {
    func color(x: Int, y: Int) -> ShadedColor
}

/// One paint everywhere.
struct SolidShader: RasterShader {
    let c: ShadedColor
    init(paint: Paint) { c = ShadedColor(r: Double(paint.r), g: Double(paint.g), b: Double(paint.b), a: paint.alpha) }
    @inline(__always) func color(x: Int, y: Int) -> ShadedColor { c }
}

/// An image sampled through an inverse map (device pixel centre → image
/// pixel coordinates): bilinear, in premultiplied alpha, edges clamped.
struct ImageShader: RasterShader {
    let image: RGBAImage
    /// Device pixel coordinates → coordinates in `image` (pixel `i` spans `[i, i + 1)`).
    let inverse: Affine

    func color(x: Int, y: Int) -> ShadedColor {
        let p = inverse.apply(Point(x: Double(x) + 0.5, y: Double(y) + 0.5))
        let w = image.width, h = image.height
        let fx = min(max(p.x - 0.5, 0), Double(w - 1)), fy = min(max(p.y - 0.5, 0), Double(h - 1))
        guard fx.isFinite, fy.isFinite else { return ShadedColor(r: 0, g: 0, b: 0, a: 0) }
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        image.pixels.withUnsafeBufferPointer { px in
            @inline(__always) func add(_ xx: Int, _ yy: Int, _ wgt: Double) {
                let i = (yy * w + xx) * 4
                let al = Double(px[i + 3]) / 255 * wgt
                r += Double(px[i]) * al; g += Double(px[i + 1]) * al; b += Double(px[i + 2]) * al
                a += al
            }
            add(x0, y0, (1 - tx) * (1 - ty)); add(x1, y0, tx * (1 - ty))
            add(x0, y1, (1 - tx) * ty); add(x1, y1, tx * ty)
        }
        guard a > 0 else { return ShadedColor(r: 0, g: 0, b: 0, a: 0) }
        return ShadedColor(r: r / a, g: g / a, b: b / a, a: min(a, 1))
    }
}

extension RGBAImage {
    /// The image reduced by an integer `factor` (≥ 2) per axis by averaging
    /// each `factor × factor` box (alpha-weighted); edge boxes are partial.
    func boxReduced(by factor: Int) -> RGBAImage {
        guard factor >= 2 else { return self }
        let ow = (width + factor - 1) / factor, oh = (height + factor - 1) / factor
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        for oy in 0..<oh {
            for ox in 0..<ow {
                var r = 0, g = 0, b = 0, a = 0, n = 0
                for y in (oy * factor)..<min((oy + 1) * factor, height) {
                    for x in (ox * factor)..<min((ox + 1) * factor, width) {
                        let i = (y * width + x) * 4
                        let al = Int(pixels[i + 3])
                        r += Int(pixels[i]) * al; g += Int(pixels[i + 1]) * al; b += Int(pixels[i + 2]) * al
                        a += al; n += 1
                    }
                }
                let o = (oy * ow + ox) * 4
                if a > 0 {
                    out[o] = UInt8((r + a / 2) / a); out[o + 1] = UInt8((g + a / 2) / a); out[o + 2] = UInt8((b + a / 2) / a)
                }
                out[o + 3] = UInt8((a + n / 2) / max(n, 1))
            }
        }
        // ow, oh ≥ 1 and out has ow·oh·4 bytes, so the initializer cannot fail.
        return (try? RGBAImage(width: ow, height: oh, pixels: out)) ?? self
    }
}
