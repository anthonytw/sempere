import ArgumentParser
import Foundation
import Sempere

/// `sempere pages draw`: adds strokes given as JSON (format.md §5.6) to a note's pages in one delta,
/// so ink made elsewhere (a generator, another tool) can be scripted into a vault.
struct PagesDraw: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draw",
        abstract: "Add strokes from a JSON file to a note's pages (one delta).",
        discussion: """
            FILE (- is standard input, at most 64 MiB) is {"strokes": [...]} or a bare array of strokes in \
            the form of format.md §5.6: {"ink": {"tool", "color", "width"}, "points": [[x, y, t, w, h, o, f, \
            az, al], ...], "transform"?, "page"?}. tool is one of format.md's inks. A point may stop after y: t \
            defaults to 0, w to the ink's width, h to w, o to 1, f to 0, az to 0 and al to pi/2. A transform must \
            be the identity. "page" (1-based, default --page) puts a stroke \
            on another page. Ids in the file are ignored: every stroke gets a new id. All strokes go into one \
            delta of addStroke ops, in file order. With --json prints the note, the file written and the \
            number of strokes per page.
            """
    )

    @Argument(help: ArgumentHelp("Note id, id prefix or title.", valueName: "id|title"))
    var note: String

    @Option(name: .long, help: ArgumentHelp("The strokes' JSON (- for standard input).", valueName: "file"))
    var file: String

    @Option(name: .long, help: ArgumentHelp("The page of strokes without their own \"page\" (1-based).", valueName: "n"))
    var page = 1

    @Flag(name: .long, help: "Check the file and say what would be added; write nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    static let maxBytes = 64 << 20

    struct Result: Encodable {
        struct PageCount: Encodable { var page: Int; var pageId: String; var strokes: Int }
        var note: String
        var dryRun: Bool
        var strokes: Int
        var pages: [PageCount]
        var file: String?
    }

    func run() throws {
        let data: Data
        if file == "-" {
            do { data = try FileHandle.standardInput.read(upToCount: Self.maxBytes + 1) ?? Data() } catch {
                throw CLIError.failure("cannot read standard input: \(error.localizedDescription)")
            }
            if data.count > Self.maxBytes { throw CLIError.failure("the strokes are larger than the 64 MiB limit") }
        } else {
            data = try readInput(file, limit: Self.maxBytes, what: "strokes file")
        }
        let input: [DrawnStroke]
        do { input = try DrawnStroke.parse(data) } catch let e as DrawnStroke.Problem {
            throw CLIError.failure("\(file): \(e.message)")
        } catch {
            throw CLIError.failure("\(file): not a strokes file (\(CLIError.from(error).message))")
        }
        guard !input.isEmpty else { throw CLIError.failure("\(file): no strokes") }

        let vault = try access.openVault(.required)
        let id = try vault.resolveNote(note)
        let state = try vault.reconstruct(noteId: id)
        try requireLive(state)
        var pageIDs: [Int: Page] = [:]
        var ops: [Op] = []
        var counts: [Int: Int] = [:]
        for s in input {
            let number = s.page ?? page
            let target: Page
            if let p = pageIDs[number] { target = p } else { target = try pageNumbered(number, of: state); pageIDs[number] = target }
            ops.append(.addStroke(page: target.id, stroke: s.stroke))
            counts[number, default: 0] += 1
        }
        var written: String?
        if !dryRun {
            written = try vault.apply(ops, to: id, deviceState: DeviceState.defaultURL(), app: appName).name.filename
        }
        let pages = counts.keys.sorted().map { n in
            Result.PageCount(page: n, pageId: pageIDs[n]?.id.uuidString.lowercased() ?? "", strokes: counts[n] ?? 0)
        }
        if output.json {
            try output.emitJSON(Result(note: id.uuidString.lowercased(), dryRun: dryRun, strokes: ops.count, pages: pages,
                                       file: written))
        } else {
            let where_ = pages.map { "page \($0.page): \($0.strokes)" }.joined(separator: ", ")
            output.info("\(dryRun ? "Would add" : "Added") \(ops.count) stroke(s) (\(where_))")
        }
    }
}

/// One stroke of a `pages draw` file, checked: finite coordinates within the renderers' extent, sane
/// widths and opacity, a bounded number of points.
struct DrawnStroke {
    var stroke: Stroke
    var page: Int?

    struct Problem: Error { var message: String }

    static let maxStrokes = 200_000
    static let maxPoints = 20_000

    static func parse(_ data: Data) throws -> [DrawnStroke] {
        let root = try JSONSerialization.jsonObject(with: data, options: [])
        let list: [Any]
        if let a = root as? [Any] { list = a } else if let o = root as? [String: Any], let a = o["strokes"] as? [Any] {
            list = a
        } else { throw Problem(message: "expected {\"strokes\": [...]} or an array of strokes") }
        if list.count > maxStrokes { throw Problem(message: "more than \(maxStrokes) strokes") }
        return try list.enumerated().map { i, any in
            do { return try one(any) } catch let p as Problem { throw Problem(message: "stroke \(i + 1): \(p.message)") }
        }
    }

    private static func number(_ any: Any?, _ what: String) throws -> Double {
        // JSONSerialization's booleans are NSNumbers too; their objCType is "c", never a JSON number's.
        guard let n = any as? NSNumber, String(cString: n.objCType) != "c" else {
            throw Problem(message: "\(what) is not a number")
        }
        let v = n.doubleValue
        guard v.isFinite else { throw Problem(message: "\(what) is not finite") }
        return v
    }

    private static func one(_ any: Any) throws -> DrawnStroke {
        guard let o = any as? [String: Any] else { throw Problem(message: "not an object") }
        guard let inkObj = o["ink"] as? [String: Any] else { throw Problem(message: "no ink") }
        guard let toolName = inkObj["tool"] as? String, let tool = InkTool(rawValue: toolName) else {
            throw Problem(message: "ink tool is not one of \(InkTool.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let hex = inkObj["color"] as? String, let color = Color(hex: hex) else {
            throw Problem(message: "ink color is not #RRGGBB or #RRGGBBAA")
        }
        let width = try number(inkObj["width"], "ink width")
        guard width > 0, width <= 200 else { throw Problem(message: "ink width must be in (0, 200]") }
        guard let raw = o["points"] as? [Any], !raw.isEmpty else { throw Problem(message: "no points") }
        if raw.count > maxPoints { throw Problem(message: "more than \(maxPoints) points") }
        let limit = ItemFrames.maxExtent
        let points: [StrokePoint] = try raw.map { p in
            guard let a = p as? [Any], (2...9).contains(a.count) else {
                throw Problem(message: "a point is not an array of 2 to 9 numbers")
            }
            let v = try a.enumerated().map { try number($1, "point value \($0 + 1)") }
            func at(_ i: Int, _ d: Double) -> Double { i < v.count ? v[i] : d }
            let pt = StrokePoint(x: v[0], y: v[1], t: at(2, 0), w: at(3, width), h: at(4, at(3, width)), o: at(5, 1),
                                 f: at(6, 0), az: at(7, 0), al: at(8, .pi / 2))
            guard abs(pt.x) <= limit, abs(pt.y) <= limit else { throw Problem(message: "a point is beyond \(Int(limit))") }
            guard pt.w >= 0, pt.w <= 400, pt.h >= 0, pt.h <= 400 else { throw Problem(message: "a point's size is outside 0...400") }
            guard (0...1).contains(pt.o) else { throw Problem(message: "a point's opacity is outside 0...1") }
            guard pt.t >= 0, pt.t < 86_400 else { throw Problem(message: "a point's time is outside 0...86400") }
            guard (0...10).contains(pt.f) else { throw Problem(message: "a point's force is outside 0...10") }
            guard abs(pt.az) <= 2 * .pi else { throw Problem(message: "a point's azimuth is outside -2pi...2pi") }
            guard (0...(Double.pi / 2 + 0.001)).contains(pt.al) else {
                throw Problem(message: "a point's altitude is outside 0...pi/2")
            }
            return pt
        }
        // Only the identity transform: any other can move or scale the stroke beyond what renderers draw (a
        // page with such a stroke does not export at all) or make it vanish. Give the points in page coordinates.
        if let t = o["transform"] {
            guard let a = t as? [Any], a.count == 6 else { throw Problem(message: "transform is not 6 numbers") }
            let v = try a.map { try number($0, "transform value") }
            guard Transform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).isIdentity else {
                throw Problem(message: "only the identity transform [1, 0, 0, 1, 0, 0] is accepted: give the points in page coordinates")
            }
        }
        var page: Int?
        if let p = o["page"] {
            let v = try number(p, "page")
            guard v >= 1, v <= 100_000, v == v.rounded() else { throw Problem(message: "page must be a whole number from 1") }
            page = Int(v)
        }
        let stroke = Stroke(ink: Ink(tool: tool, color: color, width: width), points: points)
        return DrawnStroke(stroke: stroke, page: page)
    }
}
