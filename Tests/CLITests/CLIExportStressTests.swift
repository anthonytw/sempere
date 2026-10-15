import Age
import CLITestSupport
import Foundation
import FuzzSupport
import Sempere
import XCTest

/// Synthetic vaults for export and backup stress tests: notes with many pages, an image per page (or a shared one),
/// odd titles and notebooks. Every byte is generated; nothing comes from a real vault.
enum StressVault {
    /// A PNG of one colour (stored deflate blocks, so no zlib is needed): `rgb` makes each image distinct.
    static func png(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> Data {
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                c ^= UInt32(b)
                for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            return ~c
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let tb = Array(type.utf8) + body
            return be32(UInt32(body.count)) + tb + be32(crc(tb))
        }
        var raw: [UInt8] = []
        for _ in 0..<height {
            raw.append(0)
            for _ in 0..<width { raw += [rgb.0, rgb.1, rgb.2] }
        }
        // zlib stream of stored blocks.
        var z: [UInt8] = [0x78, 0x01]
        var i = 0
        while i < raw.count {
            let n = min(65_535, raw.count - i)
            let last: UInt8 = i + n == raw.count ? 1 : 0
            z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8 & 0xFF)] + raw[i..<(i + n)]
            i += n
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65_521; b = (b + a) % 65_521 }
        z += be32(b << 16 | a)
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, 2, 0, 0, 0])
        out += chunk("IDAT", z)
        out += chunk("IEND", [])
        return Data(out)
    }

    static func stroke(page k: Int) -> Stroke {
        var pts: [StrokePoint] = []
        let dx = Double(k % 20)
        for i in 0..<6 {
            let f = Double(i)
            pts.append(StrokePoint(x: 60 + f * 15 + dx, y: 120 + f * 7, t: f * 0.02, w: 2.5, h: 2.5))
        }
        return Stroke(ink: Ink(tool: .pen, color: .black, width: 2.5), points: pts)
    }

    /// Writes one note of `pages` pages with ink on each, and an image on each when `images` (pages in
    /// `sharedImagePages` reuse the first of them's image). Returns the note id.
    @discardableResult
    static func addNote(_ vault: Vault, id: UUID = UUID(), title: String, notebook: String? = nil, pages: Int,
                        images: Bool = true, sharedImagePages: Set<Int> = [], deviceState: URL) throws -> UUID {
        let first = UUID()
        var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: notebook, pageId: first)
        var order = PageOrder.between(nil, nil)
        var shared: BlobRef?
        for p in 0..<pages {
            var page = first
            if p > 0 {
                page = UUID()
                order = PageOrder.between(order, nil)
                ops.append(.addPage(Page(id: page, order: order)))
            }
            ops.append(.addStroke(page: page, stroke: stroke(page: p)))
            guard images else { continue }
            let ref: BlobRef
            if sharedImagePages.contains(p), let s = shared {
                ref = s
            } else {
                let rgb = (UInt8(p * 37 % 256), UInt8(p * 91 % 256), UInt8(200 - p % 100))
                ref = try vault.writeBlob(note: id, png(width: 24, height: 16, rgb: rgb), type: "image/png")
                if sharedImagePages.contains(p) { shared = ref }
            }
            ops.append(.addItem(page: page, item: .image(id: UUID(), blob: ref, pixelSize: Size(w: 24, h: 16),
                                                         frame: Rect(x: 72, y: 300, w: 240, h: 160), z: "a0")))
        }
        try vault.apply(ops, to: id, deviceState: deviceState, app: "stress/1")
        return id
    }
}

/// Device checks c10, c21, c36 and the export half of c8 through the binary, under stress: long notes, an image
/// per page, odd titles, broken notes, interrupted and repeated runs (docs/cli.md "export").
final class CLIExportStressTests: CLITestCase {
    var keyPath = ""
    var vaultPath = ""
    var state: URL { tmp.appendingPathComponent("stress-device.json") }
    var args: [String] { ["--vault", vaultPath, "--identity", keyPath] }

    func newVault() throws -> Vault {
        let id = try NativeIdentity.generate(.postQuantum)
        keyPath = path("stress.key")
        try IdentityFile.render(id, created: Date()).write(toFile: keyPath, atomically: true, encoding: .utf8)
        vaultPath = path("stress-\(UUID().uuidString.prefix(6)).sempere")
        return try Vault.create(at: URL(fileURLWithPath: vaultPath), recipients: [id.recipient], identities: [id])
    }

    func tool(_ name: String, _ arguments: [String]) throws -> String? {
        let candidates = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func pdfPageCount(_ file: String) throws -> Int? {
        guard let info = try tool("pdfinfo", [file]) else { return nil }
        return info.split(separator: "\n").first { $0.hasPrefix("Pages:") }
            .flatMap { Int($0.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: c10 — HTML, an image per page

    func testHTMLExportShowsEveryPagesOwnImage() throws {
        let vault = try newVault()
        // 50 pages, pages 10 and 11 share one image (deduplicated, still shown on both).
        let note = try StressVault.addNote(vault, title: "Images: one per page", pages: 50, sharedImagePages: [10, 11],
                                           deviceState: state)
        let outDir = path("out dir é ☕️")
        let r = try cli(["export", note.uuidString, "--format", "html", "--out", outDir] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let files = FileTree.regularFiles(under: URL(fileURLWithPath: outDir), skipHidden: true)
        let page = try XCTUnwrap(files.first { $0.hasSuffix(".html") && $0 != "index.html" }, "\(files)")
        let html = try String(contentsOfFile: outDir + "/" + page, encoding: .utf8)
        // One embedded image per distinct blob.
        let images = html.components(separatedBy: "<image ").count - 1
        XCTAssertEqual(images, 49, "one image definition per distinct picture")
        // Each page references an image, and only pages 10 and 11 reference the same one.
        let pages = html.components(separatedBy: "<svg").dropFirst().filter { $0.contains("<use") }
        XCTAssertEqual(pages.count, 50)
        let refs = pages.map { page -> String in
            guard let r = page.range(of: "href=\"#") else { return "" }
            return String(page[r.upperBound...].prefix { $0 != "\"" })
        }
        XCTAssertFalse(refs.contains(""))
        XCTAssertEqual(Set(refs).count, 49)
        XCTAssertEqual(refs[10], refs[11])
        // Every embedded picture decodes as a PNG (data URI), and they differ.
        let uris = html.components(separatedBy: "data:image/png;base64,").dropFirst().map { String($0.prefix { $0 != "\"" }) }
        XCTAssertEqual(uris.count, 49)
        XCTAssertEqual(Set(uris).count, 49)
        for u in uris { XCTAssertEqual(Data(base64Encoded: u)?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47])) }
        // Re-run over the same file: same bytes.
        XCTAssertEqual(try cli(["export", note.uuidString, "--format", "html", "--out", outDir] + args).status, 0)
        XCTAssertEqual(try String(contentsOfFile: outDir + "/" + page, encoding: .utf8), html)
    }

    // MARK: c21 — a long note to PDF

    func testALongNoteExportsEveryPageToPDF() throws {
        let vault = try newVault()
        let note = try StressVault.addNote(vault, title: "Long lecture", pages: 200, deviceState: state)
        let out = path("long.pdf")
        let started = Date()
        let r = try cli(["export", note.uuidString, "--format", "pdf", "--out", out] + args)
        XCTAssertEqual(r.status, 0, r.err)
        print("STRESS c21: 200-page PDF in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
              + "\((try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0) bytes")
        if let pages = try pdfPageCount(out) { XCTAssertEqual(pages, 200) }
        else { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out)).count > 0, true) }
        if let list = try tool("pdfimages", ["-list", out]) {
            let rows = list.split(separator: "\n").dropFirst(2)
            let pagesWithImage = Set(rows.compactMap { Int($0.split(separator: " ", omittingEmptySubsequences: true).first ?? "") })
            XCTAssertEqual(pagesWithImage, Set(1...200), "every page carries its picture")
        }
        // PNG pages too, then a re-run over existing files.
        let pngs = path("long-png")
        for _ in 0..<2 {
            let p = try cli(["export", note.uuidString, "--format", "png", "--dpi", "18", "--out", pngs] + args)
            XCTAssertEqual(p.status, 0, p.err)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: pngs).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(files.count, 200)
    }

    // MARK: c8, c36 — bulk export with odd titles, broken notes, interruptions

    static let oddTitles = ["Café ☕️", "a/b", "a:b?c*d", "", "  spaced  ", String(repeating: "Long ", count: 60), "../escape",
                            ".hidden", "Same", "same", "Same", "مرحبا", "日本語", "tab\tand\u{7}bell", "NUL-less %s %@"]

    func bulkVault(count: Int) throws -> (Vault, [UUID]) {
        let vault = try newVault()
        var ids: [UUID] = []
        for i in 0..<count {
            let title = Self.oddTitles[i % Self.oddTitles.count]
            let notebook = i % 3 == 0 ? nil : ["School/Physics", "../up", "Ψ/Ω", " A//B "][i % 4]
            ids.append(try StressVault.addNote(vault, title: title, notebook: notebook, pages: 1 + i % 4, images: i % 2 == 0,
                                               deviceState: state))
        }
        return (vault, ids)
    }

    func testBulkExportOfOddTitlesStaysInsideAndReRunsSkip() throws {
        let (_, ids) = try bulkVault(count: 45)
        let out = path("bulk out")
        let r = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--out", out, "--json"] + args)
        XCTAssertEqual(r.status, 0, r.err)
        let files = FileTree.regularFiles(under: URL(fileURLWithPath: out), skipHidden: true)
        XCTAssertEqual(files.count, ids.count, "\(files)")
        XCTAssertEqual(Set(files).count, ids.count, "no two notes share a file")
        XCTAssertTrue(files.allSatisfy { !$0.contains("..") }, "\(files)")
        let outside = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(outside, [], "nothing escaped the folder")
        let again = try cli(["export", "--all", "--format", "pdf", "--layout", "notebooks", "--out", out] + args)
        XCTAssertTrue(again.out.contains("0 note(s) exported, \(ids.count) unchanged"), again.out)
        let zip = path("bulk.zip")
        XCTAssertEqual(try cli(["export", "--all", "--format", "pdf", "--zip", "--out", zip] + args).status, 0)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: zip)[.size] as? Int) ?? 0, 1000)
    }

    /// Damages a note on disk the ways a sync or a disk can: a truncated revision, a revision of garbage, or one of
    /// its attachments (c36: "How do I break it to test this?" — this is how).
    enum Damage { case truncateRevision, garbageRevision, attachment }

    func damage(_ note: UUID, _ how: Damage) throws {
        let dir = URL(fileURLWithPath: vaultPath).appendingPathComponent("notes/\(note.uuidString.lowercased())")
        let fm = FileManager.default
        switch how {
        case .truncateRevision, .garbageRevision:
            let rev = try XCTUnwrap(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".age") }.sorted().first)
            let url = dir.appendingPathComponent(rev)
            let data = try Data(contentsOf: url)
            try (how == .truncateRevision ? data.prefix(data.count / 2) : Data(repeating: 0x41, count: data.count)).write(to: url)
        case .attachment:
            let att = dir.appendingPathComponent("att")
            let blob = try XCTUnwrap(try fm.contentsOfDirectory(atPath: att.path).sorted().first)
            var bytes = try Data(contentsOf: att.appendingPathComponent(blob))
            bytes[bytes.count - 20] ^= 0xFF
            try bytes.write(to: att.appendingPathComponent(blob))
        }
    }

    func testBrokenNotesAreReportedAndTheRestExported() throws {
        let (_, ids) = try bulkVault(count: 12)
        // Broken first and last (by export order), one in the middle, and one with only an attachment damaged.
        let order = ids.sorted { $0.uuidString < $1.uuidString }
        try damage(order.first!, .truncateRevision)
        try damage(order.last!, .garbageRevision)
        try damage(order[5], .truncateRevision)
        let imageNote = ids.enumerated().first { $0.offset % 2 == 0 && ![order.first!, order.last!, order[5]].contains($0.element) }!.element
        try damage(imageNote, .attachment)

        let out = path("separate")
        let r = try cli(["export", "--all", "--format", "pdf", "--out", out, "--no-cache"] + args)
        XCTAssertEqual(r.status, 1, "a broken note fails the command: \(r.out)\n\(r.err)")
        for broken in [order.first!, order.last!, order[5]] {
            XCTAssertTrue(r.err.lowercased().contains(broken.uuidString.lowercased()), "\(broken) named: \(r.err)")
        }
        let written = FileTree.regularFiles(under: URL(fileURLWithPath: out), skipHidden: true)
        XCTAssertEqual(written.count, 9, "the note with a damaged picture is exported")
        // ...but never silently as if whole: its picture becomes a placeholder and a warning names the note.
        XCTAssertTrue(r.err.contains("warning: \(imageNote.uuidString.prefix(8).lowercased()): image item drawn as a placeholder"), r.err)

        // Every note broken: nothing written, every one reported, still no crash.
        let (_, all) = try bulkVault(count: 4)
        for id in all { try damage(id, .garbageRevision) }
        let none = try cli(["export", "--all", "--format", "pdf", "--out", path("none"), "--no-cache"] + args)
        XCTAssertEqual(none.status, 1)
        XCTAssertTrue(none.out.contains("0 note(s) exported") || none.err.contains("4 note(s) could not be exported"),
                      none.out + none.err)
    }

    func testAnInterruptedBulkExportLeavesNoHalfFilesAndResumes() throws {
        let (_, ids) = try bulkVault(count: 60)
        let out = path("interrupted")
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = ["export", "--all", "--format", "pdf", "--out", out] + args
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SEMPERE_") }
        env["XDG_STATE_HOME"] = path("state")
        env["XDG_CACHE_HOME"] = path("cache")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning, Date() < deadline,
              FileTree.regularFiles(under: URL(fileURLWithPath: out), skipHidden: true).count < 5 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        p.interrupt()
        p.waitUntilExit()
        let partial = FileTree.regularFiles(under: URL(fileURLWithPath: out), skipHidden: true)
        for f in partial {
            XCTAssertTrue(f.hasSuffix(".pdf"), "a temporary file was left: \(f)")
            if let n = try pdfPageCount(out + "/" + f) { XCTAssertGreaterThan(n, 0, "\(f) is a whole PDF") }
        }
        let rest = try cli(["export", "--all", "--format", "pdf", "--out", out] + args)
        XCTAssertEqual(rest.status, 0, rest.err)
        let all = FileTree.regularFiles(under: URL(fileURLWithPath: out), skipHidden: true)
        XCTAssertEqual(all.count, ids.count)
        XCTAssertTrue(all.allSatisfy { $0.hasSuffix(".pdf") }, "\(all)")
    }
}
