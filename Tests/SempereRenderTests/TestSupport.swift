import Foundation
import Sempere
@testable import SempereRender

enum T {
    static func pt(_ x: Double, _ y: Double, w: Double = 2, o: Double = 1) -> StrokePoint {
        StrokePoint(x: x, y: y, w: w, h: w, o: o)
    }

    static func stroke(_ pts: [StrokePoint], tool: InkTool = .pen, width: Double = 2,
                       color: Color = .black, transform: Transform? = nil) -> Stroke {
        Stroke(ink: Ink(tool: tool, color: color, width: width), points: pts, transform: transform)
    }

    static func meta(title: String = "Test", paper: Paper = .ruled, size: PageSize = PageSize(width: 200, height: 300)) -> NoteMeta {
        NoteMeta(title: title, created: Date(timeIntervalSince1970: 0), paper: paper, pageSize: size)
    }

    static func note(pages: [[Stroke]], meta: NoteMeta = meta()) -> NoteState {
        NoteState(meta: meta, pages: pages.enumerated().map { Page(order: "a\($0.offset)", strokes: $0.element) })
    }

    /// Source-tree fixtures directory (used only to rewrite the golden file).
    static var fixtureSourceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    /// Fixture from the test bundle (`resources: [.copy("Fixtures")]`).
    static func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return url
    }

    static func loadSampleNote() throws -> NoteState {
        let data = try Data(contentsOf: fixtureURL("sample-note.json"))
        return try InkJSON.decoder().decode(NoteState.self, from: data)
    }

    // Byte-level search helpers: PDFs are binary, so never index them as String.

    /// Index of the first occurrence of `needle` in `hay` at or after `from`.
    static func find(_ hay: [UInt8], _ needle: String, from: Int = 0, backwards: Bool = false) -> Int? {
        let n = Array(needle.utf8)
        guard let first = n.first, from >= 0, hay.count >= n.count else { return nil }
        let last = hay.count - n.count
        guard from <= last else { return nil }
        func matches(_ i: Int) -> Bool { hay[i] == first && hay[i..<(i + n.count)].elementsEqual(n) }
        if backwards {
            var i = last
            while i >= from { if matches(i) { return i }; i -= 1 }
        } else {
            var i = from
            while i <= last { if matches(i) { return i }; i += 1 }
        }
        return nil
    }

    static func contains(_ d: Data, _ needle: String) -> Bool { find([UInt8](d), needle) != nil }

    static func count(_ d: Data, _ needle: String) -> Int {
        let b = [UInt8](d)
        var c = 0, i = 0
        while let j = find(b, needle, from: i) { c += 1; i = j + needle.utf8.count }
        return c
    }

    static func ascii(_ s: ArraySlice<UInt8>) -> String { String(decoding: s, as: UTF8.self) }
}
