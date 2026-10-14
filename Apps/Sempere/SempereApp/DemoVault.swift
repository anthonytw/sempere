#if DEBUG
import Age
import Foundation
import Sempere

/// A synthetic vault for the App Store screenshots (`docs/appstore/screenshots.md`,
/// `scripts/screenshots.sh`): a few notebooks, tags and notes written in code,
/// never from anyone's real notes. Every note is written through `NoteWriter`
/// with a `DeviceClock` of its own, exactly as the app writes, at fixed dates, so
/// the note list looks the same on every run. Pure Foundation + Sempere + Age.
enum DemoVault {
    /// The vault's folder is `My Notes.sempere`; the sidebar shows "My Notes".
    static let folderName = "My Notes.sempere"
    /// The newest note's date, noon UTC. Notes are dated fractions of a day
    /// before it, so their day depends on the time zone: the screenshot tests
    /// run the app in UTC (`ScreenshotTests`).
    static let anchor: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12)) ?? Date(timeIntervalSince1970: 1_791_201_600)
    }()
    static let ruled = Paper(kind: .ruled)
    static let margin = Paper(kind: .marginRuled)
    static let grid = Paper(kind: .grid, spacing: 18)
    static let dots = Paper(kind: .dot, spacing: 18, background: Paper.cream)
    static let cornell = Paper(kind: .cornell, spacing: 24)

    /// What `build` made.
    struct Built: Sendable {
        let url: URL
        /// The `age-keygen` style text of the vault's throwaway key.
        let identityText: String
        /// Note ids by `Spec.key`.
        let notes: [String: UUID]
    }

    /// One demo note.
    struct Spec: Sendable {
        let key: String
        let title: String
        let notebook: String?
        let tags: [String]
        let paper: Paper
        /// How long before `anchor` it was last edited.
        let daysAgo: Double
        /// Draws page 1; further pages are drawn by `more`.
        let draw: @Sendable (inout DemoSheet) -> Void
        var more: [@Sendable (inout DemoSheet) -> Void] = []
    }

    /// FNV-1a: a stable seed from a name (`hashValue` differs on every launch).
    static func seed(_ name: String) -> UInt64 {
        name.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }

    /// The id of the note with this key: the same on every run.
    static func noteID(_ key: String) -> UUID {
        var rng = DemoRandom(seed: seed("note/" + key))
        return rng.uuid()
    }

    /// Creates the vault in `directory` (replacing an older copy), with a
    /// fresh post-quantum key, and writes every demo note. With a
    /// `passphrase` the key is also stored in the vault's `keys/` (scrypt work
    /// factor 15, the lowest a writer allows), so it unlocks the way a user
    /// unlocks a real vault: the passphrase typed into the unlock sheet.
    static func build(in directory: URL, specs: [Spec] = DemoVault.specs, passphrase: String? = nil) async throws -> Built {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = try NativeIdentity.generate(.postQuantum)
        let vaultURL = directory.appendingPathComponent(folderName, isDirectory: true)
        let vault = try Vault.create(at: vaultURL, recipients: [identity.recipient], labels: ["Demo key"],
                                     identities: [identity], created: anchor.addingTimeInterval(-40 * 86_400))
        let text = IdentityFile.render(identity, created: anchor.addingTimeInterval(-40 * 86_400))
        if let passphrase {
            try vault.writeIdentityFile(identity, passphrase: passphrase, workFactor: 15,
                                        created: anchor.addingTimeInterval(-40 * 86_400))
        }
        let clock = try DeviceClock(url: directory.appendingPathComponent("device.json"))
        var ids: [String: UUID] = [:]
        for spec in specs {
            let id = noteID(spec.key)
            ids[spec.key] = id
            try await NoteWriter.append(ops(for: spec, id: id), to: id, vault: vault, clock: clock,
                                        wall: anchor.addingTimeInterval(-spec.daysAgo * 86_400))
        }
        return Built(url: vaultURL, identityText: text, notes: ids)
    }

    /// The ops that create `spec`'s note: its pages, metadata, tags and ink.
    static func ops(for spec: Spec, id: UUID) -> [Op] {
        var rng = DemoRandom(seed: seed("page/" + spec.key))
        let firstPage = rng.uuid()
        var ops = NoteOps.newNote(title: spec.title, paper: spec.paper, notebook: spec.notebook, tags: spec.tags,
                                  pageId: firstPage)
        var sheet = DemoSheet(seed: seed("ink/" + spec.key))
        spec.draw(&sheet)
        ops += sheet.strokes.map { .addStroke(page: firstPage, stroke: $0) }
        var previous = PageOrder.between(nil, nil)
        for (index, draw) in spec.more.enumerated() {
            let page = rng.uuid()
            let order = PageOrder.between(previous, nil)
            previous = order
            ops.append(.addPage(Page(id: page, order: order)))
            var more = DemoSheet(seed: seed("ink/\(spec.key)/\(index + 2)"))
            draw(&more)
            ops += more.strokes.map { .addStroke(page: page, stroke: $0) }
        }
        return ops
    }

    // MARK: The notes

    /// Baseline of line `k` of ruled paper with 24-point spacing.
    private static func base(_ k: Int) -> Double { Double(k) * 24 - 5 }

    /// A title in large blue with a double rule, then one line of writing per entry.
    static func plain(_ title: String, _ lines: [String], x: Double = 60, spacing: Double = 24,
                      first: Double = 72, into sheet: inout DemoSheet) {
        sheet.write(title, x: x, baseline: first, pen: DemoPen.blue.scaled(1.7), maxWidth: 470)
        sheet.underline(x0: x, x1: x + min(sheet.width(of: title, pen: DemoPen.blue.scaled(1.7)), 470), y: first + 8,
                        pen: .blue, double: true)
        for (i, line) in lines.enumerated() {
            sheet.write(line, x: x, baseline: first + spacing * (Double(i) + 2), maxWidth: 500)
        }
    }

    /// The hero note: lecture notes on ruled paper with a margin, a diagram, highlights.
    static func respiration(_ s: inout DemoSheet) {
        let x0 = 84.0
        s.write("Lecture 4  -  Oct 1", x: 410, baseline: base(1), pen: DemoPen.green.scaled(0.85))
        let title = DemoPen.blue.scaled(1.8)
        s.write("Cellular Respiration", x: x0, baseline: base(3), pen: title)
        s.underline(x0: x0, x1: x0 + s.width(of: "Cellular Respiration", pen: title), y: base(3) + 9, pen: .blue, double: true)

        s.write("Glucose + O2 -> CO2 + H2O + ATP", x: x0, baseline: base(5), pen: DemoPen.red)
        s.write("Three stages", x: x0, baseline: base(7))
        s.underline(x0: x0, x1: x0 + s.width(of: "Three stages", pen: .ink), y: base(7) + 6, pen: .red)
        s.write("* Glycolysis - cytoplasm, 2 ATP", x: x0 + 12, baseline: base(8))
        s.write("* Krebs cycle - matrix, makes NADH", x: x0 + 12, baseline: base(9))
        let prefix = "* Electron transport - "
        let px = x0 + 12 + s.width(of: prefix, pen: .ink) + 6
        s.highlight(x0: px, x1: px + s.width(of: "34 ATP", pen: .ink) + 4, y: base(10) - 4)
        s.write(prefix + "34 ATP", x: x0 + 12, baseline: base(10))

        // Mitochondrion: two membranes and the folds (cristae) between them.
        let green = DemoPen.green
        s.ellipse(cx: 270, cy: 372, rx: 138, ry: 64, pen: green, tilt: -0.04)
        s.ellipse(cx: 270, cy: 372, rx: 116, ry: 46, pen: .red, tilt: -0.04)
        var folds: [(Double, Double)] = []
        for i in 0..<10 {
            folds.append((172 + Double(i) * 19, 372 + (i % 2 == 0 ? -29 : 29)))
        }
        s.addCurve(folds, pen: .blue, spacing: 2.2)
        s.write("matrix", x: 96, baseline: 424, pen: DemoPen.blue.scaled(0.9))
        s.arrow(from: (150, 414), to: (196, 388), pen: .blue)
        s.write("outer membrane", x: 430, baseline: 318, pen: DemoPen.green.scaled(0.9))
        s.arrow(from: (462, 326), to: (396, 346), pen: .green)
        s.write("cristae", x: 450, baseline: 408, pen: DemoPen.red.scaled(0.9))
        s.arrow(from: (448, 400), to: (352, 384), pen: .red)
        s.write("ATP synthase here", x: 84, baseline: 318, pen: DemoPen.blue.scaled(0.9))
        s.arrow(from: (150, 326), to: (186, 358), pen: .blue)

        s.box(x: x0 - 8, y: base(19) - 18, width: 350, height: 36, pen: .red)
        s.write("O2 is the final electron acceptor!", x: x0 + 4, baseline: base(19), pen: .red)
        s.star(cx: 478, cy: base(19) - 6, radius: 15)
        s.write("Why does cyanide kill?", x: x0, baseline: base(21), pen: DemoPen.blue)
        s.write("-> blocks complex IV", x: x0 + 200, baseline: base(21), pen: DemoPen.blue)
        s.write("Review: ch. 9, problems 3 - 7", x: x0, baseline: base(23), pen: DemoPen.green)
    }

    /// The second hero: a sketch of how the sync works, on dot paper.
    static func atlas(_ s: inout DemoSheet) {
        let title = DemoPen.blue.scaled(1.8)
        s.write("Atlas: sync design", x: 54, baseline: 62, pen: title)
        s.underline(x0: 54, x1: 54 + s.width(of: "Atlas: sync design", pen: title), y: 72, pen: .blue, double: true)

        s.box(x: 60, y: 112, width: 150, height: 56)
        s.writeCentered("iPad", cx: 135, baseline: 148, pen: DemoPen.ink.scaled(1.2))
        s.box(x: 402, y: 112, width: 150, height: 56)
        s.writeCentered("Mac", cx: 477, baseline: 148, pen: DemoPen.ink.scaled(1.2))
        s.arrow(from: (135, 176), to: (205, 268), pen: .blue)
        s.arrow(from: (478, 176), to: (410, 268), pen: .blue)
        s.lock(x: 176, y: 192, size: 16, pen: .red)
        s.lock(x: 414, y: 192, size: 16, pen: .red)
        s.write("age", x: 198, baseline: 214, pen: DemoPen.red.scaled(0.85))
        s.write("age", x: 372, baseline: 214, pen: DemoPen.red.scaled(0.85))

        s.ellipse(cx: 306, cy: 306, rx: 160, ry: 42, pen: .green, tilt: -0.02)
        s.writeCentered("any folder", cx: 306, baseline: 300, pen: DemoPen.green.scaled(1.05))
        s.writeCentered("iCloud - WebDAV", cx: 306, baseline: 322, pen: DemoPen.green.scaled(0.85))

        s.write("Rules", x: 60, baseline: 408, pen: DemoPen.blue.scaled(1.3))
        s.underline(x0: 60, x1: 112, y: 416, pen: .blue)
        let rules = ["* revisions are write-once", "* merge = union of edits", "* keys never leave the devices",
                     "* no server, no account"]
        for (i, rule) in rules.enumerated() {
            s.write(rule, x: 72, baseline: 450 + Double(i) * 36, pen: .ink.scaled(1.1))
        }
        s.highlight(x0: 72, x1: 72 + s.width(of: "* no server, no account", pen: DemoPen.ink.scaled(1.1)), y: 450 + 3 * 36 - 3)
        s.star(cx: 500, cy: 520, radius: 22)
        s.write("ship it!", x: 460, baseline: 580, pen: .red)
    }

    /// The demo vault's notes.
    static let specs: [Spec] = [
        Spec(key: "atlas", title: "Sync design sketch", notebook: "Work/Atlas", tags: ["ideas"], paper: dots,
             daysAgo: 0.2, draw: atlas),
        Spec(key: "respiration", title: "Cellular Respiration", notebook: "School/Biology", tags: ["lecture", "exam"],
             paper: margin, daysAgo: 1.3, draw: respiration),
        Spec(key: "sprint", title: "Sprint planning", notebook: "Work/Atlas", tags: ["todo"], paper: ruled, daysAgo: 2.2,
             draw: { plain("Sprint planning", ["Goals", "* ship the vault browser", "* fix the iCloud progress bar",
                                                "* write the release notes", "Risks", "* review queue is long"], into: &$0) }),
        Spec(key: "weekly", title: "Weekly sync", notebook: "Work/Meetings", tags: ["todo"], paper: margin, daysAgo: 3.1,
             draw: { plain("Weekly sync", ["Agenda", "* status updates", "* blockers", "* demo on Friday"], x: 84, into: &$0) }),
        Spec(key: "optics", title: "Wave optics: problem set 3", notebook: "School/Physics", tags: ["review"], paper: grid,
             daysAgo: 4.4,
             draw: { plain("Wave optics: set 3", ["1. Single slit: a sin t = m L", "2. Two slits, d = 0.2 mm",
                                                    "3. Grating, 600 lines per mm", "Check the units!"], spacing: 36, into: &$0) }),
        Spec(key: "quantum", title: "Quantum states", notebook: "School/Physics", tags: ["lecture"], paper: ruled, daysAgo: 6.3,
             draw: { plain("Quantum states", ["Superposition and measurement", "Observables are Hermitian",
                                              "Eigenvalues are real", "Next time: spin 1/2"], into: &$0) }),
        Spec(key: "photosynthesis", title: "Photosynthesis", notebook: "School/Biology", tags: ["lecture", "review"],
             paper: margin, daysAgo: 8.2,
             draw: { plain("Photosynthesis", ["Light reactions - thylakoid", "Calvin cycle - stroma",
                                              "6 CO2 + 6 H2O -> glucose + 6 O2", "Chlorophyll absorbs red and blue"],
                           x: 84, into: &$0) }),
        Spec(key: "lisbon", title: "Lisbon itinerary", notebook: "Personal/Travel", tags: ["travel", "ideas"], paper: cornell,
             daysAgo: 11.3,
             draw: { plain("Lisbon, 4 days", ["Day 1 - Alfama and the castle", "Day 2 - Belem, pasteis", "Day 3 - Sintra by train"],
                           x: 200, into: &$0) },
             more: [{ plain("Day 4", ["Morning market", "Tram 28", "Fado in the evening"], x: 200, into: &$0) }]),
        Spec(key: "vocabulario", title: "Vocabulario: viajes", notebook: "School/Spanish", tags: ["travel"], paper: ruled,
             daysAgo: 13.2,
             draw: { plain("Vocabulario: viajes", ["el aeropuerto - airport", "la maleta - suitcase", "el billete - ticket",
                                                    "la estacion - station"], into: &$0) }),
        Spec(key: "books", title: "Reading list", notebook: "Personal/Books", tags: ["reading"], paper: dots, daysAgo: 17.4,
             draw: { plain("To read", ["* The Shadow of the Wind", "* The Left Hand of Darkness", "* Piranesi",
                                       "* Braiding Sweetgrass"], x: 54, spacing: 36, into: &$0) }),
        Spec(key: "groceries", title: "Grocery list", notebook: nil, tags: ["todo"], paper: ruled, daysAgo: 20.2,
             draw: { plain("Groceries", ["* oat milk", "* tomatoes", "* coffee beans", "* basil"], into: &$0) }),
        Spec(key: "thoughts", title: "Quick thoughts", notebook: nil, tags: ["ideas"], paper: .blank, daysAgo: 23.4,
             draw: { plain("Idea", ["a keyboard shortcut", "for switching pens"], first: 120, into: &$0) }),
    ]
}
#endif
