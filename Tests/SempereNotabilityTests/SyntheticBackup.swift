import Foundation
import ImportTestSupport
@testable import SempereNotability

/// A synthetic Notability backup at the scale of a real one, for stress tests (device check c23): many notes
/// split over several zips, with PDFs, images, typed text, recordings, odd names, deep folders, copies of
/// notes in other parts (identical, older, and with ink of their own), one huge note, corrupt entries and
/// zip variants. Every byte is generated from a seed; nothing comes from a real backup (never `data/`).
///
/// `expected` says what an import of all the parts into an empty vault must report.
struct SyntheticBackup {
    struct Config {
        /// Distinct notes (before copies).
        var notes = 300
        /// Zip parts the backup is split over (Notability's Google Drive backup comes in parts).
        var parts = 3
        var seed: UInt64 = 0x5EED
        /// Every nth note gets a PDF background of 1 to 3 pages, an image, typed text, a recording.
        var pdfEvery = 5
        var imageEvery = 4
        var textEvery = 3
        var recordingEvery = 13
        /// Every nth note has an identical copy in another part (skipped as a duplicate).
        var duplicateEvery = 7
        /// Every nth note has an older copy (a subset of its strokes) in another part (skipped).
        var olderEvery = 11
        /// Every nth note has a copy with a stroke of its own in another part (imported as a separate note).
        var extraVersionEvery = 17
        /// Strokes of the huge note (0: none); its points are spread over many pages.
        var hugeStrokes = 6_000
        /// Truncated `.note` entries (each fails, the rest import).
        var corrupt = 2
        /// Write the last part with zip64 records, and the first with stored (not deflated) entries.
        var zipVariants = true
        /// Also write each part's notes as a folder tree instead of zips (`folderCopy`).
        var folderCopy = false
    }

    struct Expected: Equatable {
        var sources = 0
        var imported = 0
        var skipped = 0
        var failed = 0
    }

    let config: Config
    /// The zip parts, in order.
    private(set) var parts: [URL] = []
    private(set) var expected = Expected()
    /// The odd titles used, so tests can find them after the import.
    private(set) var oddTitles: [String] = []

    /// Titles a real backup can hold: accents, emoji, right-to-left, a very long one, characters some file
    /// systems refuse, leading dots and spaces, and names that differ only by case.
    static let oddNames: [String] = [
        "Café ☕️ notes", "Ünïcödé — test", "مرحبا بالعالم", "日本語のノート", "👩🏽‍🔬 Lab 🧪",
        String(repeating: "Long title ", count: 20), "a:b?c*d<e>f|g", "  leading and trailing  ", ".hidden-looking",
        "Case Name", "case name", "back\\slash", "percent %20 and %s", "tab\tand\u{7}bell", "",
    ]

    /// Folders, some deep, some with odd names; the importer files a note under the path after `Notability/`.
    static let folders: [String] = [
        "Notability/Unfiled", "Notability/Research/Daily log", "Notability/École/Cours 1",
        "Notability/" + (1...12).map { "Level \($0)" }.joined(separator: "/"), "Notability/Ψ & Φ/Ω",
        "Notability/Spaces in  folder/x", "Backups/2026/Notability/Archive",
    ]

    init(writingTo dir: URL, _ config: Config = Config()) throws {
        self.config = config
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rng = SplitMix(config.seed)
        var perPart = [[TestZip.File]](repeating: [], count: max(config.parts, 1))
        let partCount = perPart.count
        func part(_ i: Int) -> Int { i % partCount }
        func other(_ i: Int) -> Int { (i + 1) % partCount }

        var exp = Expected()
        var oddUsed: [String] = []
        for i in 0..<config.notes {
            let uuid = String(format: "5A1E%04X-0000-4000-8000-%012X", i & 0xFFFF, i)
            let created = SyntheticNote.created.addingTimeInterval(Double(i) * 3_600)
            var name = "Note \(i)"
            if i % 9 == 0 {
                let odd = Self.oddNames[(i / 9) % Self.oddNames.count]
                name = odd
                oddUsed.append(odd)
            }
            let folder = Self.folders[i % Self.folders.count]
            let huge = i == 1 && config.hugeStrokes > 0
            let curves = huge ? Self.hugeCurves(config.hugeStrokes, &rng) : Self.curves(count: 3 + Int(rng.next() % 6), &rng)
            let entryName = Self.entryName(name, index: i)
            let note = Self.package(name: name, uuid: uuid, created: created, curves: curves, index: i, config: config, &rng)
            let dos = TestZip.dos(2026, 1 + i % 12, 1 + i % 28, 10, i % 60)
            let path = "\(folder)/\(entryName).note"
            perPart[part(i)].append(.init(path: path, data: note, dosTime: dos.0, dosDate: dos.1))
            exp.sources += 1
            exp.imported += 1

            // Copies in another part, under another folder (a re-organised backup).
            let copyFolder = Self.folders[(i + 3) % Self.folders.count]
            if config.duplicateEvery > 0, i % config.duplicateEvery == 0 {
                perPart[other(i)].append(.init(path: "\(copyFolder)/\(entryName) copy.note", data: note,
                                               dosTime: dos.0, dosDate: dos.1))
                exp.sources += 1; exp.skipped += 1
            }
            if config.olderEvery > 0, i % config.olderEvery == 0, curves.count > 1 {
                let older = Self.package(name: name, uuid: uuid, created: created, curves: Array(curves.dropLast()), index: i,
                                         config: config, modified: created.addingTimeInterval(1), &rng)
                perPart[other(i)].append(.init(path: "\(copyFolder)/\(entryName) older.note", data: older))
                exp.sources += 1; exp.skipped += 1
            }
            if config.extraVersionEvery > 0, i % config.extraVersionEvery == 0 {
                var more = curves
                more.append(Self.curves(count: 1, &rng)[0])
                let extra = Self.package(name: name, uuid: uuid, created: created, curves: more, index: i,
                                         config: config, modified: created.addingTimeInterval(-60), &rng)
                perPart[other(i)].append(.init(path: "\(copyFolder)/\(entryName) other.note", data: extra))
                exp.sources += 1; exp.imported += 1
            }
        }
        for c in 0..<config.corrupt {
            let whole = Self.package(name: "Broken \(c)", uuid: String(format: "BAD0%04X-0000-4000-8000-000000000000", c),
                                     created: SyntheticNote.created, curves: Self.curves(count: 3, &rng), index: c,
                                     config: config, &rng)
            perPart[(c * 2 + 1) % partCount].append(.init(path: "Notability/Broken/Broken \(c).note",
                                                          data: whole.prefix(whole.count / 2)))
            exp.sources += 1; exp.failed += 1
        }
        // Noise every backup has: folders, files that are not notes.
        perPart[0].append(.init(path: "Notability/", data: Data(), deflate: false))
        perPart[0].append(.init(path: "Notability/readme.txt", data: Data("not a note".utf8)))

        for (n, files) in perPart.enumerated() {
            let url = dir.appendingPathComponent("Notability Backup part \(n + 1) of \(partCount).zip")
            let stored = config.zipVariants && n == 0
            let zip64 = config.zipVariants && n == partCount - 1 && partCount > 1
            let data = TestZip.write(stored ? files.map { var f = $0; f.deflate = false; return f } : files, zip64: zip64)
            try data.write(to: url)
            parts.append(url)
            if config.folderCopy {
                let root = dir.appendingPathComponent("part \(n + 1)", isDirectory: true)
                for f in files where !f.path.hasSuffix("/") {
                    let u = root.appendingPathComponent(f.path)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try f.data.write(to: u)
                }
            }
        }
        expected = exp
        oddTitles = oddUsed
    }

    /// A zip entry's file name for a title: Notability writes the title, with `/` replaced; an empty title
    /// still needs a name.
    /// Entry paths are unique, also ignoring case (a zip with two entries of one path is refused whole, and a
    /// folder copy on a case-insensitive disk would merge them): a repeated title gets the note's index.
    static func entryName(_ title: String, index: Int) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
        if cleaned.isEmpty { return "Untitled \(index)" }
        return index < 9 * oddNames.count || !oddNames.contains(title) ? cleaned : "\(cleaned) \(index)"
    }

    static func curves(count: Int, _ rng: inout SplitMix) -> [SyntheticNote.CurveSpec] {
        (0..<count).map { _ in
            let x = Float(rng.next() % 500) + 50, y = Float(rng.next() % 800) + 50
            let dx = Float(rng.next() % 40) + 5
            return SyntheticNote.CurveSpec(points: [(x, y), (x + dx / 3, y - 4), (x + 2 * dx / 3, y + 4), (x + dx, y)],
                                           fw: [1, 0.8], width: 1.4,
                                           rgba: [UInt8(rng.next() % 200), UInt8(rng.next() % 200), UInt8(rng.next() % 200), 255],
                                           style: 3)
        }
    }

    /// Many strokes spread over many pages: a lecture note of a few hundred pages.
    static func hugeCurves(_ count: Int, _ rng: inout SplitMix) -> [SyntheticNote.CurveSpec] {
        (0..<count).map { k in
            let x = Float(rng.next() % 500) + 50
            let y = Float(k / 30) * 40 + 50
            return SyntheticNote.CurveSpec(points: [(x, y), (x + 5, y - 3), (x + 10, y + 3), (x + 15, y)],
                                           fw: [1, 1], width: 1.4, rgba: [0, 0, 0, 255], style: 3)
        }
    }

    static func package(name: String, uuid: String, created: Date, curves: [SyntheticNote.CurveSpec], index i: Int,
                        config: Config, modified: Date? = nil, _ rng: inout SplitMix) -> Data {
        let dir = "Synthetic note/"
        let pdfPages = config.pdfEvery > 0 && i % config.pdfEvery == 0 ? 1 + i % 3 : 0
        let image = config.imageEvery > 0 && i % config.imageEvery == 0
        let typed = config.textEvery > 0 && i % config.textEvery == 0 ? "Typed text \(i): \(name)\nSecond line ✓" : ""
        let recording = config.recordingEvery > 0 && i % config.recordingEvery == 0
        let imagePath = "Images/IMG-\(i).jpg"
        let session = SyntheticNote.session(typed: typed, curves: curves, pdfPages: pdfPages, created: created,
                                            media: image ? { a in
                                                [AttachmentFixtures.imageObject(&a, file: imagePath, origin: (40, 200),
                                                                                size: (300, 400), scale: 0.5)]
                                            } : nil,
                                            eventTokens: recording ? Array(repeating: 0, count: curves.count) : nil,
                                            name: name)
        var files: [(String, Data)] = [
            (dir + "Session.plist", session),
            (dir + "metadata.plist", SyntheticNote.metadata(subject: "Fixtures", tags: i % 2 == 0 ? "alpha, beta" : "",
                                                            uuid: uuid, created: created,
                                                            modified: modified ?? created.addingTimeInterval(60), name: name)),
            (dir + "thumb.png", SyntheticNote.png(width: 48, height: 63)),
        ]
        if pdfPages > 0 {
            files.append((dir + "PDFs/" + SyntheticNote.pdfName,
                          AttachmentFixtures.pdf(pages: Array(repeating: (612, 792), count: pdfPages),
                                                 texts: (1...pdfPages).map { "Page \($0) of note \(i)" })))
        }
        if image {
            files.append((dir + imagePath, AttachmentFixtures.jpeg(width: 400, height: 300, orientation: 1 + i % 8)))
        }
        if recording {
            let entry = "<key>name</key><string>Lecture \(i)</string><key>fileName</key><string>Recording 1.m4a</string>"
                + "<key>creationDate</key><date>2026-10-04T16:20:00Z</date><key>duration</key><real>12.5</real>"
            files.append((dir + "Recordings/library.plist", AttachmentFixtures.library([("rec-0", entry)])))
            files.append((dir + "Recordings/Recording 1.m4a", AttachmentFixtures.m4a(seconds: 12.5)))
        } else {
            files.append((dir + "Recordings/library.plist", SyntheticNote.recordingsLibrary()))
        }
        _ = rng.next()
        return TestZip.write([.init(path: dir, data: Data(), deflate: false)]
            + files.map { .init(path: $0.0, data: $0.1, deflate: !$0.0.hasSuffix(".png")) })
    }
}

/// A small seeded generator (SplitMix64), so a backup is the same on every run and platform.
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
