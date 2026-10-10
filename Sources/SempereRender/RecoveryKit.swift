import Foundation
import Sempere

/// A printable recovery kit: the key as a QR code and as checked text, the
/// vault it opens, and how to get notes back with stock tools. Two pages.
public struct RecoveryKit: Sendable {
    /// What the sheet holds.
    public enum Secret: Sendable {
        /// The plain `AGE-SECRET-KEY-1…` line. The sheet is the key.
        case identity(String)
        /// An armored, passphrase-wrapped (scrypt) age file whose plaintext
        /// is an identity file. Useless without the passphrase.
        case passphraseWrapped(String)
    }

    /// The vault the kit was printed for, if one was given.
    public struct VaultInfo: Sendable {
        public var name: String
        public var id: String
        public var created: Date
        public var recipientCount: Int

        public init(name: String, id: String, created: Date, recipientCount: Int) {
            self.name = name; self.id = id; self.created = created; self.recipientCount = recipientCount
        }

        /// `vault`'s id, creation date and recipient count, under `name`.
        public init(vault: Vault, name: String) {
            self.init(name: name, id: vault.vaultId.uuidString.lowercased(), created: vault.manifest.created,
                      recipientCount: vault.recipients.count)
        }
    }

    public var secret: Secret
    /// The public recipient (`age1…`) of the key.
    public var recipient: String
    public var vault: VaultInfo?
    public var printed: Date
    public var pageWidth: Double = 612
    public var pageHeight: Double = 792

    public init(secret: Secret, recipient: String, vault: VaultInfo?, printed: Date) {
        self.secret = secret; self.recipient = recipient; self.vault = vault; self.printed = printed
    }

    /// A4 pages (595.28 x 841.89 pt) instead of US Letter.
    public mutating func useA4() {
        pageWidth = 595.28
        pageHeight = 841.89
    }

    /// Error correction for the QR code: Q (25 %) for the short key, M for
    /// the much longer armored file so it stays a printable size.
    public var qrCorrection: QRCode.ErrorCorrection {
        if case .identity = secret { return .quartile }
        return .medium
    }

    /// The exact bytes in the QR code: the key line, or the armored file.
    public var qrPayload: String {
        switch secret {
        case .identity(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .passphraseWrapped(let s): return s
        }
    }

    /// True for the post-quantum hybrid (MLKEM768-X25519) key type.
    public var isPostQuantum: Bool { recipient.hasPrefix("age1pq1") }

    /// The public key as printed: in full when it fits a line (X25519,
    /// 62 characters), else, for the 1959-character post-quantum key, its length and
    /// SHA-256 fingerprint. The full key is derived from the secret key
    /// (`age-keygen -y`), so nothing is lost.
    public var publicKeyDescription: String {
        guard recipient.count > 100 else { return recipient }
        return "\(recipient.prefix(10))... (\(recipient.count) characters), SHA-256 \(PaperKey.fingerprint(recipient))..."
    }

    /// The printed lines with their checksums.
    public var lines: [PaperKey.Line] {
        switch secret {
        case .identity(let s): return PaperKey.identityLines(s)
        case .passphraseWrapped(let s): return PaperKey.textLines(s)
        }
    }

    public func qrCode() throws -> QRCode {
        try QRCode.encode(text: qrPayload, correction: qrCorrection)
    }

    /// Renders the kit as a PDF.
    public func pdf() throws -> Data {
        let code = try qrCode()
        return try PDFDocument.render(pages: [try pageOne(code), pageTwo()], title: "Sempere recovery kit")
    }

    // MARK: - Layout

    private var isPlain: Bool { if case .identity = secret { return true } else { return false } }
    private var margin: Double { 54 }
    private var contentWidth: Double { pageWidth - 2 * margin }

    static func utcDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: d)
    }

    /// Wraps `text` to lines of at most `columns` characters at spaces.
    static func wrap(_ text: String, columns: Int) -> [String] {
        var out: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= columns {
                    line += " " + word
                } else {
                    out.append(line)
                    line = String(word)
                }
            }
            out.append(line)
        }
        return out
    }

    /// A text cursor that moves down the page.
    struct Writer {
        var page: PDFPage
        var y: Double
        let x: Double
        let width: Double

        mutating func line(_ s: String, size: Double = 9, font: PDFPage.Font = .courier, indent: Double = 0,
                           gap: Double = 1.35) {
            y += size * gap
            page.text(s, x: x + indent, y: y, size: size, font: font)
        }

        /// Courier text wrapped to the column width.
        mutating func paragraph(_ s: String, size: Double = 9, font: PDFPage.Font = .courier, indent: Double = 0) {
            let columns = Int((width - indent) / (0.6 * size))
            for l in RecoveryKit.wrap(s, columns: columns) { line(l, size: size, font: font, indent: indent) }
        }

        mutating func space(_ d: Double) { y += d }
    }

    private func pageOne(_ code: QRCode) throws -> PDFPage {
        var w = Writer(page: PDFPage(width: pageWidth, height: pageHeight), y: margin - 6, x: margin,
                       width: contentWidth)
        w.line(isPlain ? "Sempere recovery kit: secret key" : "Sempere recovery kit: passphrase-locked key",
               size: 18, font: .helveticaBold)
        w.space(4)
        if let v = vault {
            w.line("Vault:      \(v.name)")
            w.line("Vault id:   \(v.id)")
            w.line("Created:    \(Self.utcDate(v.created)) (\(v.recipientCount) key(s) can open it)")
        } else {
            w.line("Vault:      (not given; this key may open several vaults)")
        }
        w.line("Printed:    \(Self.utcDate(printed))")
        w.line("Public key: \(publicKeyDescription)")
        w.space(8)

        // Warning box.
        let boxTop = w.y
        let warning: [String]
        if isPlain {
            warning = [
                "THIS SHEET IS YOUR KEY.",
                "Anyone who holds it, or a photo of it, can read every note in the vault.",
                "Keep it offline and safe (with your passport, in a sealed envelope). Do not",
                "photograph it, scan it to a cloud, email it or leave it in a shared printer.",
                "Lose every copy of your key and your notes are gone for good: nobody, including",
                "the Sempere authors, can recover them.",
            ]
        } else {
            warning = [
                "THIS SHEET IS YOUR KEY, LOCKED WITH YOUR PASSPHRASE.",
                "Without the passphrase it reveals nothing, but whoever holds it can try to guess",
                "the passphrase offline: use a long one. NEVER write the passphrase on this sheet.",
                "Forget the passphrase and this sheet is useless: keep another copy of the key.",
            ]
        }
        w.space(6)
        for (i, l) in warning.enumerated() {
            w.line(l, size: i == 0 ? 13 : 9, font: i == 0 ? .helveticaBold : .courierBold, indent: 10)
        }
        w.space(8)
        w.page.strokeRect(x: margin, y: boxTop, width: contentWidth, height: w.y - boxTop, lineWidth: 3)
        w.space(14)

        // QR code, quiet zone of 4 modules.
        let qrSide = isPlain ? 150.0 : 230.0
        let modulePt = qrSide / Double(code.size)
        let quiet = 4 * modulePt
        let qrTop = w.y + quiet
        w.page.qrCode(code, x: margin + quiet, y: qrTop, module: modulePt)
        let textX = margin + qrSide + 2 * quiet + 12
        var side = Writer(page: w.page, y: qrTop - 10, x: textX, width: pageWidth - margin - textX)
        let sideNote: String
        if isPlain {
            sideNote = "QR code: the key line exactly (\(qrPayload.count) characters, byte mode, error "
                + "correction Q, version \(code.version)). Scan it only with an offline tool, e.g. "
                + "`zbarimg --raw -q photo.png > key.txt`, never with a phone app that uploads images."
        } else {
            sideNote = "QR code: the whole locked key file below (\(qrPayload.utf8.count) bytes, byte mode, "
                + "error correction M, version \(code.version)). `zbarimg --raw -q photo.png > key.age` "
                + "gives the file back; then `age -d key.age > key.txt` asks for the passphrase."
        }
        side.paragraph(sideNote, size: 8.5)
        w.page = side.page
        w.y = qrTop + qrSide + quiet + 8

        // The key as text.
        w.line(isPlain ? "The key as text (type the lines one after another, no spaces, as ONE line):"
                       : "The locked key file as text (type each line exactly, keep the line breaks):",
               size: 9.5, font: .helveticaBold)
        w.space(4)
        let lineSize = isPlain ? 13.0 : 8.5
        for l in lines {
            let shown = l.groups.joined(separator: " ")
            w.y += lineSize * 1.45
            w.page.text(String(format: "%2d", l.number), x: margin, y: w.y, size: lineSize * 0.75, font: .courier,
                        gray: 0.35)
            w.page.text(shown, x: margin + 22, y: w.y, size: lineSize, font: .courierBold)
            w.page.text(l.checksum, x: pageWidth - margin - 0.6 * lineSize * 4, y: w.y, size: lineSize,
                        font: .courier, gray: 0.35)
        }
        w.space(10)
        w.paragraph("Grey numbers on the right are line checksums, not part of the key. To find a mistyped "
                    + "line, check each one: printf '%s' 'LINE WITHOUT SPACES' | sha256sum | cut -c1-4", size: 8.5)
        if isPlain {
            w.space(4)
            w.paragraph("The key has its own checksum too: an age key is Bech32, and its last 6 characters are "
                        + "a BCH checksum over the whole key. Any typo of up to 4 characters is always detected "
                        + "(age refuses the key), but Bech32 cannot say where the typo is; the line checksums "
                        + "can. `age-keygen -y key.txt` must give the public key above"
                        + (isPostQuantum ? " (its fingerprint, see page 2)." : "."), size: 8.5)
        }
        return w.page
    }

    /// How to check the rebuilt key against the public key on page 1.
    private func checkKeyLines(_ w: inout Writer) {
        if isPostQuantum {
            w.line("age-keygen -y key.txt | tr -d '\\n' | sha256sum | cut -c1-16", indent: 14)
            w.line("# must print \(PaperKey.fingerprint(recipient)) (the SHA-256 on page 1)", indent: 14)
        } else {
            w.line("age-keygen -y key.txt     # must print the public key on page 1", indent: 14)
        }
    }

    private func pageTwo() -> PDFPage {
        var w = Writer(page: PDFPage(width: pageWidth, height: pageHeight), y: margin - 6, x: margin,
                       width: contentWidth)
        w.line("How to get your notes back", size: 16, font: .helveticaBold)
        w.space(4)
        w.paragraph("You need: this sheet, a copy of the vault folder (*.sempere, from your sync service, a "
                    + "backup made with `sempere backup`, or a tar of it), and a computer. The vault holds "
                    + "only encrypted files; this key decrypts them.")
        w.space(6)
        w.line("1. Rebuild the key file", size: 11, font: .helveticaBold)
        if isPlain {
            w.paragraph("Type the key lines into key.txt as one line with no spaces (or scan the QR code "
                        + "offline). Then check it:")
            w.line("chmod 600 key.txt", indent: 14)
            checkKeyLines(&w)
        } else {
            w.paragraph("Type the locked key file into key.age line by line (or scan the QR code offline), "
                        + "then unlock it with your passphrase:")
            w.line("age -d -o key.txt key.age && chmod 600 key.txt", indent: 14)
            checkKeyLines(&w)
        }
        if isPostQuantum {
            w.paragraph("This is a post-quantum key: age 1.3 or newer is needed for every `age` command here "
                        + "(github.com/FiloSottile/age/releases; the version in Ubuntu's apt is older).", size: 8.5)
        }
        w.space(6)
        w.line("2a. With the sempere tool (github.com/anthonytw/sempere)", size: 11, font: .helveticaBold)
        w.line("V=~/restore/notes.sempere", indent: 14)
        w.line("sempere restore BACKUP_DIR --to $V --identity key.txt   # from a backup", indent: 14)
        w.line("sempere vault verify --vault $V --identity key.txt", indent: 14)
        w.line("sempere export --all --format pdf --out ~/notes-pdf \\", indent: 14)
        w.line("    --vault $V --identity key.txt", indent: 14)
        w.space(6)
        w.line("2b. With nothing but stock tools (age, tail, gunzip, jq)", size: 11, font: .helveticaBold)
        w.paragraph("Each note is a folder notes/<note id>/ of revision files. The newest *.snapshot.age "
                    + "holds the whole note; later *.delta.age files hold edits since. Every file decrypts "
                    + "to 37 header bytes (SMPR, version, tag) and then gzip-compressed JSON:")
        w.line("age -d -i key.txt FILE.age | tail -c +38 | gunzip | jq .", indent: 14)
        w.paragraph("To dump the newest snapshot of every note:")
        w.line("for d in $V/notes/*/; do", indent: 14)
        w.line("  f=$(ls \"$d\"*.snapshot.age 2>/dev/null | tail -n 1)", indent: 14)
        w.line("  [ -n \"$f\" ] || f=$(ls \"$d\"*.age | tail -n 1)", indent: 14)
        w.line("  age -d -i key.txt \"$f\" | tail -c +38 | gunzip > \"$(basename \"$d\").json\"", indent: 14)
        w.line("done", indent: 14)
        w.paragraph("Strokes are B-spline control points (docs/format.md in the repository); the JSON is "
                    + "readable on its own and any later sempere release can render it.")
        w.space(6)
        w.line("3. Afterwards", size: 11, font: .helveticaBold)
        w.paragraph("Delete key.txt (and key.age) from any computer you do not own. If this sheet was ever "
                    + "out of your control, make a new key, add it to the vault and remove this one "
                    + "(sempere vault recipients add / remove): removing a key does not undo what it "
                    + "already decrypted, but it locks out everything written afterwards.")
        w.space(10)
        w.page.hline(y: w.y, from: margin, to: pageWidth - margin)
        w.space(4)
        w.paragraph("Public key \(publicKeyDescription)" + (vault.map { "   vault \($0.id)" } ?? ""), size: 7.5)
        return w.page
    }
}
