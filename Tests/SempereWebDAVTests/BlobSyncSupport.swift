import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Synthetic attachment content (never real data).
func syntheticBlob(_ n: Int, seed: UInt8 = 7) -> Data {
    var x = UInt32(seed) &* 2_654_435_761 | 1
    return Data((0..<n).map { _ in
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        return UInt8(truncatingIfNeeded: x)
    })
}

class BlobSyncTestCase: SyncTestCase {
    var id: String { noteID.uuidString.lowercased() }

    func att(_ name: String, _ note: UUID? = nil) -> URL {
        dir(name).appendingPathComponent("notes/\((note ?? noteID).uuidString.lowercased())/att")
    }

    func attEntries(_ name: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: att(name).path)) ?? []).sorted()
    }

    func blobFile(_ vault: Vault, _ ref: BlobRef) throws -> String { try vault.blobFileName(for: ref) }

    /// A delta in the test note with one image item per reference (on a new page).
    @discardableResult
    func referencing(_ vault: Vault, device: DeviceID, t: Int64, _ refs: [BlobRef]) throws -> Revision {
        let page = UUID()
        var ops: [Op] = [.addPage(Page(id: page, order: "a\(t)"))]
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: page, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                         frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        let seq = try vault.nextSeq(noteId: noteID, device: device)
        let ms = baseMillis + t
        let r = Revision(noteId: noteID, device: device, seq: seq, hlc: HLC(millis: ms, counter: 0)!,
                         wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "test/0", body: .delta(ops: ops))
        try vault.write(r)
        return r
    }
}
