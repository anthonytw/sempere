import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// A fresh post-quantum identity (vaults take no other kind).
func pqIdentity() -> NativeIdentity { try! NativeIdentity.generate(.postQuantum) }

class SyncTestCase: TempDirTestCase {
    let identity = pqIdentity()
    let devA = DeviceID("aaaaaaaa")!
    let devB = DeviceID("bbbbbbbb")!
    let noteID = UUID(uuidString: "7e57c0de-0000-4000-8000-000000000001")!
    let baseMillis: Int64 = 1_759_632_000_000

    func dir(_ name: String) -> URL { tmp.appendingPathComponent("\(name).sempere") }

    func makeVault(_ name: String = "A") throws -> Vault {
        try Vault.create(at: dir(name), recipients: [identity.recipient], labels: ["t"], identities: [identity])
    }

    func openVault(_ name: String) throws -> Vault { try Vault.open(at: dir(name), identities: [identity]) }

    func client(_ server: MockDAV, auth: WebDAVCredentials? = nil) throws -> WebDAVClient {
        try WebDAVClient(baseURL: URL(string: "https://dav.example.com\(MockDAV.base)/")!, credentials: auth, transport: server)
    }

    @discardableResult
    func sync(_ name: String, _ server: MockDAV, vault: Vault?? = nil, dryRun: Bool = false, label: String? = nil,
              now: Date = Date()) throws -> SyncReport {
        let exists = FileManager.default.fileExists(atPath: dir(name).appendingPathComponent("vault.json").path)
        let v: Vault?
        if let vault { v = vault } else { v = exists ? try openVault(name) : nil }
        let s = WebDAVSync(directory: dir(name), vault: v, client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-\(name).json"),
                           options: WebDAVSyncOptions(dryRun: dryRun, deviceLabel: label ?? name, now: now))
        return try s.run()
    }

    func delta(_ vault: Vault, device: DeviceID, t: Int64, title: String, note: UUID? = nil) throws -> Revision {
        let id = note ?? noteID
        let seq = try vault.nextSeq(noteId: id, device: device)
        let ms = baseMillis + t
        let r = Revision(noteId: id, device: device, seq: seq, hlc: HLC(millis: ms, counter: 0)!,
                         wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "test/0",
                         body: .delta(ops: [.setMeta(.title(title))]))
        try vault.write(r)
        return r
    }

    func fileNames(_ vault: Vault, _ note: UUID? = nil) throws -> [String] {
        try vault.revisionNames(of: note ?? noteID).map(\.filename)
    }

    func title(_ vault: Vault, _ note: UUID? = nil) throws -> String {
        try vault.reconstruct(noteId: note ?? noteID).meta.title
    }

    func vaultJSON(_ name: String) throws -> Data { try Data(contentsOf: dir(name).appendingPathComponent("vault.json")) }
}
