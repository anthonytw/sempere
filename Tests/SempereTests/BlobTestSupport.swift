import Age
import Foundation
import XCTest
@testable import Sempere

let blobPage = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a1")!
let otherNote = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

/// Synthetic attachment content (never real data).
func syntheticBytes(_ n: Int, seed: UInt8 = 7) -> Data {
    var x = UInt32(seed) &* 2_654_435_761 | 1
    return Data((0..<n).map { _ in
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        return UInt8(truncatingIfNeeded: x)
    })
}

extension VaultTestCase {
    func attDir(_ vault: Vault, _ note: UUID) -> URL {
        vault.url.appendingPathComponent("notes").appendingPathComponent(note.uuidString.lowercased())
            .appendingPathComponent("att")
    }

    func blobURL(_ vault: Vault, _ note: UUID, _ ref: BlobRef) throws -> URL {
        attDir(vault, note).appendingPathComponent(try vault.blobFileName(for: ref))
    }

    func attEntries(_ vault: Vault, _ note: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: attDir(vault, note).path)) ?? []).sorted()
    }

    /// A delta in `note` adding a page with one image item per reference.
    func referencingDelta(_ log: inout LogBuilder, _ t: Int64, note: UUID = testNote, refs: [BlobRef],
                          newPage: Bool = true, device: DeviceID = devA) -> Revision {
        var ops: [Op] = newPage ? [.addPage(Page(id: blobPage, order: "a0"))] : []
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: blobPage, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                             frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        var rev = log.delta(device, t, ops)
        rev.noteId = note
        return rev
    }

    /// A delta in `note` with an item of an unknown kind that names `ref`
    /// only deep inside unknown fields (format.md §8.1.1 structural rule).
    func unknownKindDelta(_ log: inout LogBuilder, _ t: Int64, note: UUID = testNote, ref: BlobRef) -> Revision {
        let nested: JSONValue = .object(["layers": .array([.object(["source": .object([
            "sha256": .string(ref.sha256), "size": .number(Double(ref.size)), "type": .string(ref.type)])])])])
        let item = Item(kind: ItemKind(rawValue: "sticker"), frame: Rect(x: 1, y: 1, w: 5, h: 5), z: "s",
                        extra: ["art": nested])
        var rev = log.delta(devA, t, [.addPage(Page(id: blobPage, order: "a0")), .addItem(page: blobPage, item: item)])
        rev.noteId = note
        return rev
    }

    /// Encrypts `plaintext` to the vault's recipients and stores it as
    /// `att/<fileName>` of `note`, bypassing every check (hostile storage).
    func plant(_ vault: Vault, _ note: UUID, _ plaintext: Data, as fileName: String) throws {
        let dir = attDir(vault, note)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Vault.encrypt(plaintext, to: vault.ageRecipients()).write(to: dir.appendingPathComponent(fileName))
    }

    /// A blob plaintext with the given header fields, content and padding.
    func blobPlaintext(_ content: Data, digest: Data? = nil, length: Int64? = nil, padding: Data = Data()) -> Data {
        BlobFraming.header(digest: digest ?? Data(SHA256Digest(content)), length: length ?? Int64(content.count))
            + content + padding
    }

    /// The plaintext of a blob file.
    func decryptBlob(_ url: URL, _ id: any AgeIdentity) throws -> Data {
        try AgeFile.decrypt(Data(contentsOf: url), with: [id])
    }

    func stanzaCount(_ url: URL) throws -> Int {
        try AgeFile.readHeader(contentsOf: url).stanzas.count
    }

    /// Bytes after the age header (nonce and payload).
    func payload(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let (_, headerLength) = try AgeFile.parseHeader(data)
        return data.dropFirst(headerLength)
    }
}

/// SHA-256 bytes without importing Crypto into every test.
func SHA256Digest(_ data: Data) -> [UInt8] {
    Array(Hex.decode(FileDigest.sha256(data))!)
}
