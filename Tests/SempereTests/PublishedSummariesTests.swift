import Crypto
import Foundation
import Age
import FuzzSupport
import XCTest
import VaultTestSupport
@testable import Sempere

/// `sempere-summaries.sealed` (format.md §12): a hint that only a vault's own
/// secret opens, entries keyed by revision names, never created behind the
/// user's back, and bounded and typed on hostile bytes.
final class PublishedSummariesTests: VaultTestCase {
    static let vectorSecret = try! VaultEpochKey(bytes: Data(0..<32))
    static let vectorVault = UUID(uuidString: "0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c")!
    static let vectorNonce = Data(0xa0...0xab)

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// The vector in format.md §12.1 (also checked by web/test/summaries.test.ts).
    func testVector() throws {
        let key = PublishedSummaries.key(Self.vectorSecret).withUnsafeBytes { Data($0) }
        let file = try PublishedSummaries.seal(Data("{}".utf8), secret: Self.vectorSecret, vaultId: Self.vectorVault,
                                               nonce: Self.vectorNonce)
        XCTAssertEqual(Self.hex(key), Self.vectorKeyHex)
        XCTAssertEqual(Self.hex(file), Self.vectorFileHex)
        XCTAssertEqual(try PublishedSummaries.open(file, secret: Self.vectorSecret, vaultId: Self.vectorVault),
                       Data("{}".utf8))
    }

    static let vectorKeyHex = "4ffd10840df4dc46092a2c424919f611c1bcc355fe7526a19e25a1489bf5510a"
    static let vectorFileHex = "534d505501a0a1a2a3a4a5a6a7a8a9aaabb466bcf027fe45b94f3fe195f6e0b57d9c6e"

    static let noteA = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000a00a")!
    static let noteB = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000a00b")!
    static let noteC = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000a00c")!

    func rev(_ note: UUID, _ device: DeviceID, _ seq: Int, _ t: Int64, _ ops: [Op]) -> Revision {
        let ms = baseMillis + t
        return Revision(noteId: note, device: device, seq: seq, hlc: HLC(millis: ms, counter: 0)!, wall: wallAt(ms),
                        app: "test/0", body: .delta(ops: ops))
    }

    /// A vault with two clean notes and one with an unreadable revision.
    func makeNotes(_ vault: Vault) throws -> (clean: [Revision], broken: Revision) {
        let page = UUID(uuidString: "7e57c0de-0000-4000-8000-00000000c001")!
        let a = rev(Self.noteA, devA, 1, 0, NoteOps.newNote(title: "Synthetic A", notebook: "School/Math", tags: ["alpha"],
                                                             pageId: page))
        let a2 = rev(Self.noteA, devA, 2, 10, [.setPageRecognition(pageId: page, recognition: Recognition(
            engine: "test", text: "synthetic words", words: [])), .setMeta(.favorite(true))])
        let b = rev(Self.noteB, devB, 1, 5, NoteOps.newNote(title: "Synthetic B", pageId: UUID()))
        let c = rev(Self.noteC, devA, 1, 7, NoteOps.newNote(title: "Synthetic C", pageId: UUID()))
        for r in [a, a2, b, c] { try vault.write(r) }
        try flipByte(fileURL(vault, c.noteId, c.name), at: 40)
        return ([a, a2, b], c)
    }

    func testEntriesRoundTripAndSkipUnreadableNotes() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let (clean, broken) = try makeNotes(vault)
        let (entries, read) = try vault.publishedSummaryEntries()
        XCTAssertEqual(read, 3)
        XCTAssertEqual(Set(entries.keys), Set(clean.map(\.noteId)))
        XCTAssertNil(entries[broken.noteId], "a note with an unreadable revision is never published")
        let a = try XCTUnwrap(entries[clean[0].noteId])
        XCTAssertEqual(a.title, "Synthetic A")
        XCTAssertEqual(a.notebook, "School/Math")
        XCTAssertEqual(a.tags, ["alpha"])
        XCTAssertTrue(a.favorite)
        XCTAssertEqual(a.revisions, [clean[0].name.filename, clean[1].name.filename].sorted())
        XCTAssertEqual(a.pageTexts, [.init(page: 1, text: "synthetic words")])
        XCTAssertEqual(a.modified, clean[1].wall)

        let sealed = try vault.sealPublishedSummaries(entries)
        XCTAssertEqual(try vault.openPublishedSummaries(sealed), entries)
        // Equal entries, equal JSON.
        XCTAssertEqual(try PublishedSummaries.encode(entries, vaultId: vault.vaultId),
                       try PublishedSummaries.encode(try vault.openPublishedSummaries(sealed), vaultId: vault.vaultId))
    }

    func testTamperedForeignAndLockedFilesDoNotOpen() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        _ = try makeNotes(vault)
        let sealed = try vault.sealPublishedSummaries(try vault.publishedSummaryEntries().entries)
        for i in [0, 4, 5, 20, sealed.count - 1] {
            var bad = sealed
            bad[i] ^= 0x01
            XCTAssertThrowsError(try vault.openPublishedSummaries(bad)) { XCTAssert($0 is PublishedSummariesError) }
        }
        XCTAssertThrowsError(try vault.openPublishedSummaries(sealed.prefix(20)))
        XCTAssertThrowsError(try vault.openPublishedSummaries(Data()))

        // Another vault (its own secret) cannot open it.
        let other = try makeVault(id, name: "Other")
        XCTAssertThrowsError(try other.openPublishedSummaries(sealed)) { XCTAssert($0 is PublishedSummariesError) }
        // Same secret, another vault id: the associated data differs.
        let json = try Gzip.compress(try PublishedSummaries.encode([:], vaultId: vault.vaultId))
        let forOther = try PublishedSummaries.seal(json, secret: try vault.requireSecret(), vaultId: other.vaultId)
        XCTAssertThrowsError(try vault.openPublishedSummaries(forOther))
        // Authentic but naming another vault inside.
        let inside = try PublishedSummaries.seal(try Gzip.compress(try PublishedSummaries.encode([:], vaultId: other.vaultId)),
                                                 secret: try vault.requireSecret(), vaultId: vault.vaultId)
        XCTAssertThrowsError(try vault.openPublishedSummaries(inside))
        // A locked vault reads nothing.
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.openPublishedSummaries(sealed)) { XCTAssertEqual($0 as? VaultError, .locked) }
        XCTAssertEqual(locked.readPublishedSummaries(), [:])
    }

    /// A per-device file (format.md §12.5) names its device and carries a version, both inside the sealed
    /// content, and is signed by the device; each write is a later version, and a file naming another
    /// device or without a version does not open as that device's.
    func testDeviceFilesCarryTheirDeviceAndAVersion() throws {
        let vault = try makeVault(pqIdentity())
        let me = try XCTUnwrap(vault.writerDevice)
        let other = DeviceID(me.rawValue == "aaaaaaaa" ? "bbbbbbbb" : "aaaaaaaa")!
        let (entries, _) = try vault.publishedSummaryEntries()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try vault.writeDevicePublishedSummaries(entries, now: t0)
        let opened = try vault.openDevicePublishedSummaries(first, device: me)
        XCTAssertEqual(opened.device, me)
        XCTAssertEqual(opened.version, 1_790_000_000_000)
        XCTAssertEqual(opened.entries, entries)
        XCTAssertEqual(try Data(contentsOf: vault.devicePublishedSummariesURL(me)), first)
        // The clock went back: still one more than the last one.
        let second = try vault.writeDevicePublishedSummaries(entries, now: t0.addingTimeInterval(-3600))
        XCTAssertEqual(try vault.openDevicePublishedSummaries(second, device: me).version, 1_790_000_000_001)
        // The file lost: the clock still gives a later one than before.
        try FileManager.default.removeItem(at: vault.devicePublishedSummariesURL(me))
        let third = try vault.writeDevicePublishedSummaries(entries, now: t0.addingTimeInterval(60))
        XCTAssertEqual(try vault.openDevicePublishedSummaries(third, device: me).version, 1_790_000_060_000)

        XCTAssertThrowsError(try vault.openDevicePublishedSummaries(first, device: other)) { XCTAssert($0 is PublishedSummariesError) }
        let plain = try vault.sealPublishedSummaries(entries)
        XCTAssertNil(try vault.decryptPublishedSummaries(plain).version)
        XCTAssertThrowsError(try vault.openDevicePublishedSummaries(plain, device: me)) { XCTAssert($0 is PublishedSummariesError) }
        // A per-device file is never read as a root file (that would skip its signature).
        XCTAssertThrowsError(try vault.openPublishedSummaries(first)) { XCTAssert($0 is PublishedSummariesError) }
        // The root file's JSON is unchanged (no `device`, no `version`).
        let json = String(decoding: try PublishedSummaries.encode([:], vaultId: vault.vaultId), as: UTF8.self)
        XCTAssertFalse(json.contains("version") || json.contains("device"), json)
    }

    /// Only a listed device opened with its signing keys writes a per-device file.
    func testOnlyADeviceWithItsSigningKeysWritesItsFile() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let keyless = try Vault.open(at: vault.url, identities: [id])
        XCTAssertThrowsError(try keyless.writeDevicePublishedSummaries([:])) {
            guard case PublishedSummariesError.cannotSign = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try keyless.sealDevicePublishedSummaries([:], version: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("summaries").path))
    }

    /// The previous own file does not open (sealed under an earlier epoch's key, here another vault's) or
    /// has a version beyond the window: the next write starts at the clock, on purpose (review of #83).
    func testAnUnreadableOrFarFuturePreviousFileRestartsAtTheClock() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let me = try XCTUnwrap(vault.writerDevice)
        let other = try makeVault(pqIdentity(), name: "Other")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let url = vault.devicePublishedSummariesURL(me)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try other.sealDeviceFile([:], device: me, version: 1_890_000_000_000, signer: TestVaults.signing(id)).write(to: url)
        let first = try vault.writeDevicePublishedSummaries([:], now: t0)
        XCTAssertEqual(try vault.openDevicePublishedSummaries(first, device: me, now: t0).version, 1_790_000_000_000)
        // One beyond the 7-day window is no version, for the writer as for readers (a clock-skew guard).
        let ahead = try vault.sealDevicePublishedSummaries([:], version: 1_790_000_000_000 + 8 * 86_400_000)
        XCTAssertThrowsError(try vault.openDevicePublishedSummaries(ahead, device: me, now: t0))
        XCTAssertNoThrow(try vault.openDevicePublishedSummaries(ahead, device: me, now: t0.addingTimeInterval(2 * 86_400)))
        try ahead.write(to: url)
        let second = try vault.writeDevicePublishedSummaries([:], now: t0.addingTimeInterval(1))
        XCTAssertEqual(try vault.openDevicePublishedSummaries(second, device: me, now: t0).version, 1_790_000_001_000)
        XCTAssertNil(PublishedSummaries.accepted(PublishedSummaries.maxVersion, now: t0))
        XCTAssertEqual(PublishedSummaries.accepted(1_790_000_000_000 + 7 * 86_400_000, now: t0), 1_790_000_000_000 + 7 * 86_400_000)
    }

    /// A per-device file is `SMPU 0x04 ‖ epoch (u32 BE) ‖ version (u64 BE) ‖ nonce ‖ ciphertext ‖ tag ‖
    /// signature`, the header bound as associated data and the whole sealed part signed (format.md §12.5), so
    /// the signature is checked from the header before anything is decrypted; the root file keeps `SMPU 0x01`.
    func testDeviceFilesCarryTheirEpochAndVersionInASignedHeader() throws {
        let vault = try makeVault(pqIdentity())
        let me = try XCTUnwrap(vault.writerDevice)
        let signing = TestVaults.signing(try identity(of: vault))
        let t0 = Date(timeIntervalSince1970: 0)
        let file = try vault.sealDevicePublishedSummaries([:], version: 0x0102_0304_0506)
        XCTAssertEqual(Array(file.prefix(17)), [0x53, 0x4D, 0x50, 0x55, 0x04, 0, 0, 0, UInt8(vault.manifest.epoch),
                                                0, 0, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        XCTAssertEqual(PublishedSummaries.sealedEpoch(file), vault.manifest.epoch)
        XCTAssertEqual(PublishedSummaries.sealedVersion(file), 0x0102_0304_0506)
        let five = try vault.sealDevicePublishedSummaries([:], version: 5)
        XCTAssertEqual(try vault.openDevicePublishedSummaries(five, device: me, now: t0).version, 5)
        for (i, flip) in [(8, UInt8(0x02)), (16, UInt8(0x01)), (12, UInt8(0x80))] {
            var changed = five
            changed[i] ^= flip
            XCTAssertThrowsError(try vault.openDevicePublishedSummaries(changed, device: me, now: t0), "header byte \(i) is signed")
        }
        // A version outside 1 … 2^53 − 1 in the header is no version.
        var huge = five
        huge.replaceSubrange(9..<17, with: Data(repeating: 0xFF, count: 8))
        XCTAssertNil(PublishedSummaries.sealedVersion(huge))
        XCTAssertThrowsError(try PublishedSummaries.deviceHeader(epoch: 1, version: 0))
        XCTAssertThrowsError(try PublishedSummaries.deviceHeader(epoch: 1, version: PublishedSummaries.maxVersion + 1))
        let root = try vault.sealPublishedSummaries([:])
        XCTAssertEqual(Array(root.prefix(5)), [0x53, 0x4D, 0x50, 0x55, 0x01])
        XCTAssertNil(PublishedSummaries.sealedEpoch(root))
        XCTAssertNil(PublishedSummaries.sealedVersion(root))
        XCTAssertThrowsError(try vault.openDevicePublishedSummaries(root, device: me), "a per-device file has the epoch header")
        XCTAssertNil(PublishedSummaries.sealedEpoch(Data([0x53, 0x4D, 0x50, 0x55, 0x04, 0, 0, 0, 1])), "too short")
        // The earlier formats (`SMPU 0x02`, unsigned; `0x03`, version only inside) are not per-device files.
        for byte: UInt8 in [0x02, 0x03] {
            var old = five
            old[4] = byte
            XCTAssertNil(PublishedSummaries.sealedEpoch(old))
            XCTAssertFalse(PublishedSummaries.looksSealed(old))
            XCTAssertThrowsError(try vault.openDevicePublishedSummaries(old, device: me, now: t0))
        }
        func signed(_ body: Data, epoch: Int, version: Int64) throws -> Data {
            PublishedSummaries.attach(try signing.sign(AuthorMessage.summaries(
                vaultId: vault.vaultId, epoch: epoch, epochId: vault.manifest.epochId, device: me, version: version,
                sealed: body)), to: body)
        }
        // Sealed and signed with this vault's key and this device's keys under another epoch number: not this
        // epoch's file.
        let json5 = try Gzip.compress(try PublishedSummaries.encode([:], vaultId: vault.vaultId, device: me, version: 5))
        let otherEpoch = try PublishedSummaries.seal(json5, secret: try vault.requireSecret(), vaultId: vault.vaultId,
                                                     device: (vault.manifest.epoch + 1, 5))
        XCTAssertThrowsError(try vault.openDevicePublishedSummaries(try signed(otherEpoch, epoch: vault.manifest.epoch + 1, version: 5),
                                                                    device: me, now: t0)) { XCTAssert($0 is PublishedSummariesError) }
        // Signed over the header's version 6 while the content says 5: refused after decryption.
        let mismatch = try PublishedSummaries.seal(json5, secret: try vault.requireSecret(), vaultId: vault.vaultId,
                                                   device: (vault.manifest.epoch, 6))
        XCTAssertThrowsError(try vault.openDevicePublishedSummaries(try signed(mismatch, epoch: vault.manifest.epoch, version: 6),
                                                                    device: me, now: t0)) { XCTAssert($0 is PublishedSummariesError) }
    }

    /// The vector in format.md §12.5: the header and the signed message's SHA-256 for fixed inputs (the
    /// signatures themselves are randomized, so the vector stops at the message).
    func testDeviceFileHeaderAndMessageVector() throws {
        let header = try PublishedSummaries.deviceHeader(epoch: 1, version: 1_790_000_000_000)
        XCTAssertEqual(Self.hex(header), "534d50550400000001000001a0c4506c00")
        let sealed = header + Self.vectorNonce + Data(repeating: 0, count: 16)
        let message = AuthorMessage.summaries(vaultId: Self.vectorVault, epoch: 1, epochId: Data(repeating: 0x11, count: 32),
                                              device: DeviceID("aaaaaaaa")!, version: 1_790_000_000_000, sealed: sealed)
        XCTAssertEqual(Self.hex(Data(SHA256.hash(data: message))), Self.vectorMessageDigestHex)
    }

    static let vectorMessageDigestHex = "d4e08dd4bc1132fd3b046dffc878de1e621a3def942c29fd9c47a0cde69a4896"

    /// The identity a test vault was made with (its only device).
    func identity(of vault: Vault) throws -> NativeIdentity {
        try XCTUnwrap(vault.unlockIdentities.first as? NativeIdentity)
    }

    func testVersionsAreBoundedAndMalformedOnesAreDroppedAlone() throws {
        XCTAssertNil(PublishedSummaries.nextVersion(after: PublishedSummaries.maxVersion, now: Date()))
        XCTAssertEqual(PublishedSummaries.nextVersion(after: nil, now: Date(timeIntervalSince1970: -5)), 1)
        XCTAssertEqual(PublishedSummaries.nextVersion(after: PublishedSummaries.maxVersion - 1, now: .distantFuture),
                       PublishedSummaries.maxVersion)
        let vid = UUID()
        func contents(_ extra: String) throws -> PublishedSummaries.Contents {
            try PublishedSummaries.decodeContents(Data(#"{"format":"sempere-summaries/1","vaultId":"\#(vid.uuidString.lowercased())","notes":{}\#(extra)}"#.utf8),
                                                  vaultId: vid)
        }
        XCTAssertEqual(try contents(#","device":"aaaaaaaa","version":42"#).version, 42)
        XCTAssertEqual(try contents(#","device":"aaaaaaaa","version":42"#).device, DeviceID("aaaaaaaa"))
        for bad in [#","version":0"#, #","version":-1"#, #","version":9007199254740992"#, #","version":1.5"#,
                    #","version":"7""#, #","version":1e300"#] {
            let c = try contents(bad)
            XCTAssertNil(c.version, bad)
        }
        XCTAssertNil(try contents(#","device":"AAAAAAAA""#).device)
        XCTAssertNil(try contents(#","device":7"#).device)
    }

    func testMalformedEntriesAreDroppedAlone() throws {
        let vid = UUID()
        let good = #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":1,"pageTexts":[{"page":1,"text":"x"}]"#
        let bad = [
            #""revisions":[],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":0,"pageTexts":[]"#,
            #""revisions":["../x"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":0,"pageTexts":[]"#,
            #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-02-30T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":0,"pageTexts":[]"#,
            #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":"T","tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":1,"pageTexts":[{"page":2,"text":"x"}]"#,
            #""revisions":["17596320000000000-a1b2c3d4-1.delta.age"],"title":7,"tags":[],"favorite":false,"deleted":false,"created":"2026-10-04T16:20:00.000Z","modified":"2026-10-04T16:20:00.000Z","pages":1,"pageTexts":[]"#,
        ]
        var notes = [#""11111111-1111-4111-8111-111111111111":{\#(good),"unknown":{"x":1}}"#,
                     #""11111111-1111-4111-8111-11111111111A":{\#(good)}"#]
        for (i, b) in bad.enumerated() { notes.append(#""22222222-2222-4222-8222-22222222222\#(i)":{\#(b)}"#) }
        let json = #"{"format":"sempere-summaries/1","vaultId":"\#(vid.uuidString.lowercased())","notes":{\#(notes.joined(separator: ","))}}"#
        let entries = try PublishedSummaries.decode(Data(json.utf8), vaultId: vid)
        XCTAssertEqual(entries.keys.map { $0.uuidString.lowercased() }, ["11111111-1111-4111-8111-111111111111"])
        XCTAssertThrowsError(try PublishedSummaries.decode(Data(json.replacingOccurrences(of: "summaries/1", with: "summaries/2").utf8),
                                                           vaultId: vid))
        XCTAssertThrowsError(try PublishedSummaries.decode(Data(json.utf8), vaultId: UUID()))
    }

    func testStaleEntriesAreReadAgainAndListingFiltersTheServerView() throws {
        let vault = try makeVault(pqIdentity())
        let (clean, _) = try makeNotes(vault)
        let (first, _) = try vault.publishedSummaryEntries()
        // A new revision of note A: its entry is stale, B's is reused.
        let a3 = rev(Self.noteA, devA, 3, 20, [.setMeta(.title("Renamed"))])
        try vault.write(a3)
        let (second, read) = try vault.publishedSummaryEntries(reuse: first)
        XCTAssertEqual(read, 2, "note A again, and the unreadable note C")
        XCTAssertEqual(second[clean[0].noteId]?.title, "Renamed")
        XCTAssertEqual(second[clean[2].noteId], first[clean[2].noteId])
        // For a server that lacks A's newest revision, A has no entry.
        var listing = try vault.webIndexListing()
        listing[clean[0].noteId.uuidString.lowercased()]?.removeAll { $0 == a3.name.filename }
        let (server, _) = try vault.publishedSummaryEntries(for: listing, reuse: second)
        XCTAssertNil(server[clean[0].noteId])
        XCTAssertNotNil(server[clean[2].noteId])
    }

    func testRefreshRewritesOnlyAnExistingStaleFile() throws {
        let vault = try makeVault(pqIdentity())
        _ = try makeNotes(vault)
        XCTAssertFalse(try vault.refreshPublishedSummaries())
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.publishedSummariesURL.path), "never created")
        try Data("junk".utf8).write(to: vault.publishedSummariesURL)
        XCTAssertTrue(try vault.refreshPublishedSummaries(), "a damaged file is replaced")
        XCTAssertEqual(vault.readPublishedSummaries().count, 2)
        XCTAssertFalse(try vault.refreshPublishedSummaries(), "current: not rewritten")
        XCTAssertFalse(try Vault.open(at: vault.url).refreshPublishedSummaries(), "locked: left alone")
    }

    // MARK: - Fuzz

    func testFuzzPublishedSummaries() throws {
        let vault = try makeVault(pqIdentity())
        _ = try makeNotes(vault)
        let entries = try vault.publishedSummaryEntries().entries
        let json = try PublishedSummaries.encode(entries, vaultId: vault.vaultId)
        let vid = vault.vaultId
        let secret = try vault.requireSecret()
        // Plaintext JSON: decode must accept or throw typed errors only.
        let jsonReport = Fuzz.run("published-summaries-json", seeds: [json], quick: 1500, text: true, maxSize: 64 << 10) { input in
            do { _ = try PublishedSummaries.decode(input, vaultId: vid) } catch is PublishedSummariesError {
            } catch { return "untyped error \(type(of: error))" }
            return nil
        }
        XCTAssertGreaterThan(jsonReport.cases, 0)
        for f in jsonReport.failures { XCTFail("\(f)") }
        // Mutated JSON sealed for real, read through the vault.
        let sealedReport = Fuzz.run("published-summaries-sealed", seeds: [json], quick: 200, text: true, maxSize: 64 << 10) { input in
            do {
                let file = try PublishedSummaries.seal(try Gzip.compress(input), secret: secret, vaultId: vid)
                _ = try vault.openPublishedSummaries(file)
            } catch is PublishedSummariesError {
            } catch is GzipError {
            } catch { return "untyped error \(type(of: error))" }
            return nil
        }
        XCTAssertGreaterThan(sealedReport.cases, 0)
        for f in sealedReport.failures { XCTFail("\(f)") }
    }
}
