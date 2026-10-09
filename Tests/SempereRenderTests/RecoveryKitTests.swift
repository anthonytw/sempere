import Foundation
import FuzzSupport
import Sempere
import XCTest
@testable import SempereRender

final class RecoveryKitTests: XCTestCase {
    // The throwaway fixture key (Tests/SempereTests/Fixtures/sample.key).
    static let key = "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN"
    static let recipient = "age1f406y9syjcsa2gj2lgz0s2g7suxrytycqr79zccg3d4spcujegqsgl00rd"
    static let armored = """
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNjcnlwdCBtc2F2amlUZWhESW94cmlq
        OUhHVkFnIDE1CmpyQVlwUnZmaEQvcmk4d1puVzkzT2ovOXRjQWVzUUlrc1gvc0ls
        -----END AGE ENCRYPTED FILE-----

        """

    private func kit(_ secret: RecoveryKit.Secret, vault: Bool = true) -> RecoveryKit {
        RecoveryKit(secret: secret, recipient: Self.recipient,
                    vault: vault ? .init(name: "School", id: "5a3b1e00-1000-4000-8000-000000000001",
                                         created: Date(timeIntervalSince1970: 1_790_000_000), recipientCount: 2) : nil,
                    printed: Date(timeIntervalSince1970: 1_791_000_000))
    }

    /// The uncompressed content streams of our own PDF.
    private func streams(_ pdf: Data) -> [String] {
        let text = String(decoding: pdf, as: UTF8.self)
        var out: [String] = []
        var rest = Substring(text)
        while let s = rest.range(of: "stream\n"), let e = rest.range(of: "\nendstream", range: s.upperBound..<rest.endIndex) {
            out.append(String(rest[s.upperBound..<e.lowerBound]))
            rest = rest[e.upperBound...]
        }
        return out
    }

    /// Every `(...) Tj` string, unescaped.
    private func texts(_ stream: String) -> [String] {
        var out: [String] = []
        for line in stream.split(separator: "\n") where line.hasSuffix(") Tj") && line.hasPrefix("(") {
            var s = ""
            var escaped = false
            for c in line.dropFirst().dropLast(4) {
                if escaped { s.append(c); escaped = false } else if c == "\\" { escaped = true } else { s.append(c) }
            }
            out.append(s)
        }
        return out
    }

    /// Rebuilds the QR module grid from the run rectangles on the page.
    private func qrModules(_ stream: String, size: Int) throws -> [Bool] {
        var rects: [(Double, Double, Double, Double)] = []
        for line in stream.split(separator: "\n") where line.hasSuffix(" re") {
            let n = line.split(separator: " ").dropLast().compactMap { Double($0) }
            XCTAssertEqual(n.count, 4)
            rects.append((n[0], n[1], n[2], n[3]))
        }
        let m = try XCTUnwrap(rects.first?.3)
        let left = try XCTUnwrap(rects.map(\.0).min())
        let top = try XCTUnwrap(rects.map { $0.1 + $0.3 }.max())
        var grid = [Bool](repeating: false, count: size * size)
        for r in rects {
            XCTAssertEqual(r.3, m, accuracy: 0.002, "every run is one module high")
            let col = Int(((r.0 - left) / m).rounded())
            let row = Int(((top - r.1 - r.3) / m).rounded())
            let len = Int((r.2 / m).rounded())
            for c in col..<(col + len) { grid[row * size + c] = true }
        }
        return grid
    }

    func testPlainKitHoldsQRAndCheckedText() throws {
        let k = kit(.identity(Self.key))
        let pdf = try k.pdf()
        XCTAssertTrue(pdf.starts(with: Data("%PDF-1.4".utf8)))
        XCTAssertEqual(String(decoding: pdf, as: UTF8.self).components(separatedBy: "/Type /Page ").count - 1, 2)
        let pages = streams(pdf)
        XCTAssertEqual(pages.count, 2)
        let one = texts(pages[0]), two = texts(pages[1])

        // The warning, the vault, the public key.
        XCTAssertTrue(one.contains("THIS SHEET IS YOUR KEY."))
        XCTAssertTrue(one.contains("Vault:      School"))
        XCTAssertTrue(one.contains("Vault id:   5a3b1e00-1000-4000-8000-000000000001"))
        XCTAssertTrue(one.contains("Public key: \(Self.recipient)"))
        XCTAssertTrue(one.contains("Printed:    2026-10-03"))

        // The key in checked lines that join back to the key.
        let lines = PaperKey.identityLines(Self.key)
        XCTAssertEqual(lines.map(\.text).joined(), Self.key)
        for l in lines {
            XCTAssertTrue(one.contains(l.groups.joined(separator: " ")), l.text)
            XCTAssertTrue(one.contains(l.checksum), l.checksum)
        }
        XCTAssertTrue(one.contains { $0.contains("Bech32") })

        // The QR code on the page is exactly the encoder's symbol for the key.
        let code = try k.qrCode()
        XCTAssertEqual(code.errorCorrection, .quartile)
        XCTAssertEqual(code, try QRCode.encode(text: Self.key, correction: .quartile))
        XCTAssertEqual(try qrModules(pages[0], size: code.size), code.modules)

        // Recovery steps with stock tools match docs/format.md framing.
        XCTAssertTrue(two.contains { $0.contains("age -d -i key.txt FILE.age | tail -c +38 | gunzip | jq .") })
        XCTAssertTrue(two.contains { $0.contains("sempere restore BACKUP_DIR") })
        XCTAssertTrue(two.contains { $0.contains("age-keygen -y key.txt") })
    }

    // A post-quantum identity and recipient have the real shapes (77 and 1959
    // characters) but are random strings, not keys.
    static let pqKey = "AGE-SECRET-KEY-PQ-15FERYXHRDZ9M6Y09MR8WRERWZGJ6F8NTXVHXYRDLM5AAHN0T09NL4UJY86"
    static let pqRecipient = "age1pq124fl6zy54klay937yrnujckpak28lrdjg0eel92ue3gm36kcwf9tfwwqltsjqf6h5graeeeex7ervydu284rxqfxhpydcfskh788la77n9fx4s72pdhfpn9sh2kw4wv0ewvlkpp37svkukh9wxw7v4d7q7k98cv7tm49eae922gpfaf7kfgpqxgmvdpsdj05s6grka6gfputqftf78r57xr0v3zxupyu5v3u70svug68eu5y0mydn8fhfsgawxel2w2me46vk59hp4aupc4jy8wx9s3zt3gmsefl593rtmy3p9s9wys8aq463gz082srtvnndjut3kpszqpv70uxmlendw4vgekrgqysm2r9cj0jzat23uqsh450zndktq4c973v0q9s9fezepnnw9fc5lfjfzmgpw9pzghxcurp0lsqay9y7sys0dwalcy7jzvyf4sngq7rl3xdljjaaa8vn97pjayu3cddy9fshg38hwllep2qluenf6kc584q54e8vqjshyecyhm3r3xrjf03m5vhmped9r6ugjlrg2764jnsse0n7e822ydlwu4umgv09t4950hsvp6c6dc34rl3hgd930ceumnpgzm7lqyeau0xwffxa9zqgwzngsm8xynvcswqqna350700p6nrpvl69swmhwlz46hevqjydlvnvwawsjxltwl6rferdpf6rrteu58924vtaznch4u2xq939k68dcknm9r7vhuv5h7p60ezczayrsvy4h34zs53nqypwx7acsmlgltqnf055ah9ve206yz752mxys9dx6lutwg6a08jj33hssvu0t00fjv5yes0wxazxq7wuhzjw8rvvyhtusqxkdzh4fzdszdq56htnydzl7y6xef92e36jn6rnk66phveedqm2m89eha2gqrfe9h2fkj22yxclvngz75rc92wev7tdze2ck8f0vzz58can6n0mchuutpqla0uat7exygkmh9uzzg959rcgpy8vglj2wyks253afs7ds05hzvte235c2s8rhuxsehschfh49uwtrjsn5qzwfjm6hrglwzprqknxkw6ngdh72gq0fuxyf3esqrkul02qzrpet02rxqvf6v6tnynr7qcma9utwxswz84sr3msjd9q2s0v25vc40c77qpmwndey2fzp8x2kfppzgzyzyhvycx0dd8zz9j7xgxdj54mspksjrh57jp6pmxk7rd9j2mqvjrqklxltlks2jdwl289lx5kxee9mphdnsm2cwagzk5fu52auswg4a0v3nff05k205vsx2xvcffnnm3vxx3dcazqemwjapfseq0m6wwt8am5sx60e2sm7ap6t5qclxzsd2vkxad7ph46adte8krs3cerqy66ksxwnewead2gyv7wfk6ajg7kw3csmt7q3k0n57lm9hfncr95gkqqdyjsxfwtukfde29nvld9u88s6wg7lr7afl0l2q25aljahm6ythppz4x7lfzd6g4xh47djm4msrjjkle43kdl84v5ng9zeerenxqzv7rcf9dzatxtz6xqhgnsnt6z5pmrlz86euyqcf76x97dfqmqq89d8g7p30utrhf9jlasrzqrq9cnn2lr5hu72f8h267cu34j3r4qfnm0cccwujq5s3m2zjff3lk9lcvwnreadsqca9kywes57vvdv9tjhkef0zlhxha9f5pk3pxzdlds3mxugsz4vtc9przhalye89s5w9etu2h0wtzskrprs7rxf5qvnux75hsc8h7c2u0fqavz2wyhguxcpyu45w78hf4wrtufuf3660fp3j42slx5a78frd7j8svhms00xcj62rjfpu4guqjthmz6d3tgtwtv99l3tdgvnvqy6rk4jl9q67g30thz2hqkuy8k05crjxlupgp09wt2xnsppxvspa0uxkxtz38al3888egwwf"

    /// The hybrid key: a 1959-character public key must not run off the page,
    /// the QR code is version 7 at level Q, and page 2 says `age` 1.3 is needed.
    func testPostQuantumKitFitsThePage() throws {
        let k = RecoveryKit(secret: .identity(Self.pqKey), recipient: Self.pqRecipient,
                            vault: .init(name: "School", id: "5a3b1e00-1000-4000-8000-000000000001",
                                         created: Date(timeIntervalSince1970: 1_790_000_000), recipientCount: 1),
                            printed: Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertTrue(k.isPostQuantum)
        let pages = streams(try k.pdf())
        let one = texts(pages[0]), two = texts(pages[1])
        // Courier is 0.6 em per character: the 504 pt column holds 93 characters at 9 pt, 112 at 7.5 pt.
        for t in one + two where !t.contains("zbarimg") { XCTAssertLessThanOrEqual(t.count, 112, t) }
        XCTAssertTrue(one.allSatisfy { $0.allSatisfy { $0.isASCII } }, "the PDF fonts are WinAnsi: no ellipsis")
        XCTAssertLessThanOrEqual(try XCTUnwrap(one.first { $0.hasPrefix("Public key:") }).count, 93)
        let fingerprint = PaperKey.fingerprint(Self.pqRecipient)
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertTrue(one.contains { $0.hasPrefix("Public key: age1pq1") && $0.contains("1959 characters")
                                     && $0.contains(fingerprint) })
        XCTAssertFalse((one + two).contains { $0.contains(String(Self.pqRecipient.dropFirst(20).prefix(40))) },
                       "the full public key is never printed")
        let lines = k.lines
        XCTAssertEqual(lines.map(\.text).first, "AGE-SECRET-KEY-PQ-1")
        XCTAssertEqual(lines.map(\.text).joined(), Self.pqKey)
        for l in lines { XCTAssertTrue(one.contains(l.checksum), l.checksum) }

        let code = try k.qrCode()
        XCTAssertEqual(code.errorCorrection, .quartile)
        XCTAssertEqual(code.version, 7)
        XCTAssertEqual(code, try QRCode.encode(text: Self.pqKey, correction: .quartile))
        XCTAssertEqual(try qrModules(pages[0], size: code.size), code.modules)

        XCTAssertTrue(two.contains { $0.contains("age 1.3 or newer") })
        XCTAssertTrue(two.contains { $0.contains("sha256sum | cut -c1-16") })
        XCTAssertTrue(two.contains { $0.contains(fingerprint) })
        XCTAssertFalse(two.contains { $0.contains("must print the public key on page 1") })
    }

    func testPassphraseKitOfAPostQuantumKey() throws {
        let k = RecoveryKit(secret: .passphraseWrapped(Self.armored), recipient: Self.pqRecipient, vault: nil,
                            printed: Date(timeIntervalSince1970: 1_791_000_000))
        let pages = streams(try k.pdf())
        for t in texts(pages[0]) + texts(pages[1]) where !t.contains("zbarimg") { XCTAssertLessThanOrEqual(t.count, 112, t) }
        XCTAssertTrue(texts(pages[1]).contains { $0.contains("age 1.3 or newer") })
    }

    func testClassicKitStillPrintsTheWholePublicKeyAndNoVersionNote() throws {
        let k = kit(.identity(Self.key))
        XCTAssertFalse(k.isPostQuantum)
        XCTAssertEqual(k.publicKeyDescription, Self.recipient)
        XCTAssertFalse(texts(streams(try k.pdf())[1]).contains { $0.contains("age 1.3") })
    }

    func testPassphraseKitNeverHoldsAPlainKey() throws {
        let k = kit(.passphraseWrapped(Self.armored), vault: false)
        let pdf = try k.pdf()
        let text = String(decoding: pdf, as: UTF8.self)
        XCTAssertFalse(text.contains("AGE-SECRET-KEY"))
        let one = texts(streams(pdf)[0])
        XCTAssertTrue(one.contains("THIS SHEET IS YOUR KEY, LOCKED WITH YOUR PASSPHRASE."))
        XCTAssertTrue(one.contains { $0.contains("(not given") })
        for l in PaperKey.textLines(Self.armored) {
            XCTAssertTrue(one.contains(l.text))
            XCTAssertTrue(one.contains(l.checksum))
        }
        XCTAssertEqual(PaperKey.textLines(Self.armored).count, 4)
        let code = try k.qrCode()
        XCTAssertEqual(code.errorCorrection, .medium)
        XCTAssertEqual(try qrModules(streams(pdf)[0], size: code.size), code.modules)
        XCTAssertTrue(texts(streams(pdf)[1]).contains { $0.contains("age -d -o key.txt key.age") })
    }

    func testA4AndLongWrappedFileStayOnThePage() throws {
        var k = kit(.passphraseWrapped("-----BEGIN AGE ENCRYPTED FILE-----\n"
            + String(repeating: String(repeating: "A", count: 64) + "\n", count: 9)
            + "-----END AGE ENCRYPTED FILE-----\n"))
        k.pageWidth = 595.28
        k.pageHeight = 841.89
        for stream in streams(try k.pdf()) {
            for line in stream.split(separator: "\n") where line.hasSuffix(" Td") {
                let n = line.split(separator: " ").compactMap { Double($0) }
                XCTAssertGreaterThan(n[1], 36, "text above the bottom margin: \(line)")
                XCTAssertLessThan(n[0], 595.28 - 54)
            }
        }
    }

    func testDocumentWriterBasics() throws {
        var page = PDFPage(width: 200, height: 100)
        page.text("a (b) \\ é", x: 10, y: 20, size: 12, font: .courier)
        page.fillRect(x: 0, y: 0, width: 10, height: 10)
        let pdf = try PDFDocument.render(pages: [page], title: "T")
        let s = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(s.contains("(a \\(b\\) \\\\ ?) Tj"))
        XCTAssertTrue(s.contains("/BaseFont /Courier /Encoding /WinAnsiEncoding"))
        XCTAssertTrue(s.contains("10 80 Td"), "y is flipped to PDF's bottom-left origin")
        XCTAssertTrue(s.contains("0 90 10 10 re f"))
        XCTAssertFalse(s.contains("Helvetica"), "only fonts in use are declared")
        XCTAssertEqual(PDFPage.monospacedWidth("abcd", size: 10), 24)
        XCTAssertNil(PDFPage.monospacedWidth("abcd", size: 10, font: .helvetica))
        let compressed = try PDFDocument.render(pages: [page], compress: true)
        XCTAssertTrue(String(decoding: compressed, as: UTF8.self).contains("/FlateDecode"))
    }

    /// Rasterises the kit with poppler and decodes the QR code with zbar,
    /// where both are installed (apt install poppler-utils zbar-tools).
    func testPrintedQRDecodesWithZbar() throws {
        guard let pdftoppm = ExternalTool.find("pdftoppm"),
            try QRCodeTests.zbar(QRCodeTests.png(try QRCode.encode(text: "probe"))) != nil else {
            throw XCTSkip("pdftoppm or zbarimg not installed")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, secret, payload) in [("plain", RecoveryKit.Secret.identity(Self.key), Self.key),
                                        ("locked", .passphraseWrapped(Self.armored), Self.armored)] {
            try kit(secret).pdf().write(to: dir.appendingPathComponent("\(name).pdf"))
            try ExternalTool.run(pdftoppm, ["-r", "150", "-f", "1", "-l", "1", "-png", "-singlefile",
                                            dir.appendingPathComponent("\(name).pdf").path, dir.appendingPathComponent(name).path])
            let png = try Data(contentsOf: dir.appendingPathComponent("\(name).png"))
            XCTAssertEqual(String(decoding: try XCTUnwrap(try QRCodeTests.zbar(png)), as: UTF8.self), payload, name)
        }
    }
}
