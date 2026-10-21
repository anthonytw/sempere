// The base class of the CLI tests: they drive the built `sempere` binary as a subprocess (identically on Linux and
// macOS, and without linking the executable's `main` into a test bundle).
import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest

/// Result of one `sempere` run.
public struct CLIResult {
    public var status: Int32
    public var out: String
    public var err: String
    public var outData: Data
    public var json: Any? { try? JSONSerialization.jsonObject(with: outData) }
}

/// Base class: a scratch directory per test, subprocess helper, fixture access.
open class CLITestCase: TempDirTestCase {
    public static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures")
    public static var fixtureVault: String { fixtures.appendingPathComponent("sample.sempere").path }
    /// The fixture vault's device key file (`DeviceKeys.fileText`: the age identity plus its signing seeds).
    public static var fixtureKey: String { fixtures.appendingPathComponent("sample.key").path }
    /// The fixture vault's recovery key (an `age-keygen -pq` style identity file).
    public static var fixtureRecoveryKey: String { fixtures.appendingPathComponent("sample-recovery.key").path }
    public static let passphrase = "sempere-test"
    public static let lecture = "11111111-1111-4111-8111-111111111111"

    /// The built `sempere` binary: `.build/<config>/sempere`, next to the test bundle.
    public static var binary: URL {
        var url = Bundle(for: CLITestCase.self).bundleURL
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appendingPathComponent("sempere").path) {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("sempere")
    }

    /// Runs the binary with a clean SEMPERE_* environment.
    @discardableResult
    public func cli(_ args: [String], env: [String: String] = [:]) throws -> CLIResult {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SEMPERE_") }
        environment["XDG_STATE_HOME"] = tmp.appendingPathComponent("state").path
        environment["XDG_CACHE_HOME"] = tmp.appendingPathComponent("cache").path
        environment.merge(env) { $1 }
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Drain both pipes before waiting so a large output cannot deadlock.
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return CLIResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: box.get(), as: UTF8.self), outData: outData)
    }

    public func path(_ name: String) -> String { tmp.appendingPathComponent(name).path }

    /// Mounts a fresh FAT volume of `megabytes` (no hard links, a size that
    /// can fill up) under the scratch directory and returns its path; it is
    /// detached when the test ends. Skips the test where `hdiutil` is not
    /// available (Linux).
    public func mountFATVolume(megabytes: Int = 4) throws -> String {
        #if os(macOS)
        let image = path("fat-\(UUID().uuidString).dmg"), mount = path("fat-\(UUID().uuidString)")
        func hdiutil(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args + ["-quiet"]
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard try hdiutil(["create", "-size", "\(megabytes)m", "-fs", "MS-DOS", "-volname", "SEMPTEST", image]) == 0,
              try hdiutil(["attach", "-nobrowse", "-mountpoint", mount, image]) == 0 else {
            throw XCTSkip("cannot make a FAT volume here")
        }
        addTeardownBlock { _ = try? hdiutil(["detach", mount, "-force"]) }
        return mount
        #else
        throw XCTSkip("needs hdiutil to make a FAT volume")
        #endif
    }

    /// This test's CLI trust records (`$XDG_STATE_HOME/sempere/trust` of `cli`).
    public var cliTrustStore: FileEpochTrustStore {
        FileEpochTrustStore(directory: FileEpochTrustStore.cliDirectory(
            environment: ["XDG_STATE_HOME": tmp.appendingPathComponent("state").path]))
    }

    /// A writable copy of the fixture vault. The CLI's trust record for it is saved as `sempere device
    /// confirm` would (the fixture device's join confirmed against the fixture's root), so the CLI writes
    /// to it with `--identity` the fixture key.
    public func copyFixtureVault(as name: String = "copy.sempere") throws -> String {
        let dest = tmp.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.fixtureVault), to: dest)
        try trustFixtureCopy(dest.path)
        return dest.path
    }

    /// Saves the CLI's trust record for a copy of a vault the fixture device belongs to (as `sempere
    /// device confirm` would), so the CLI writes to it.
    public func trustFixtureCopy(_ path: String) throws {
        let keys = try fixtureDeviceKeys()
        let url = URL(fileURLWithPath: path)
        let vault = try Vault.open(at: url, identities: [keys.nativeIdentity], signing: keys.signing, trust: cliTrustStore,
                                   root: try Vault.open(at: url).root)
        if !vault.isReadOnly { try vault.requireWritable() }   // saves the record
    }

    /// Writes the vault keys of the vault at `vault` (what the kit's script puts in vault-keys.txt,
    /// format.md §15.13), unwrapped from vault.json with the device key file `keyFile`; returns the path.
    public func vaultKeysFile(vault: String, keyFile: String) throws -> String {
        let identity = try DeviceKeys.parse(String(contentsOfFile: keyFile, encoding: .utf8)).nativeIdentity
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: vault)
            .appendingPathComponent("vault.json"))) as? [String: Any]
        let wraps = ((manifest?["keys"] as? [[String: Any]]) ?? []).compactMap { $0["wrap"] as? String }
        for wrap in wraps {
            guard let plain = try? AgeFile.decrypt(Data(wrap.utf8), with: [identity]) else { continue }
            let out = path("vault-keys-\(UUID().uuidString.prefix(8)).txt")
            try plain.write(to: URL(fileURLWithPath: out))
            return out
        }
        throw XCTSkip("no wrap in \(vault) opens with \(keyFile)")
    }

    public func fixtureIdentity() throws -> NativeIdentity {
        try IdentityFile.parse(String(contentsOfFile: Self.fixtureKey, encoding: .utf8))
    }

    /// The fixture device's keys (its decryption key and signing pair).
    public func fixtureDeviceKeys() throws -> DeviceKeys {
        try DeviceKeys.parse(String(contentsOfFile: Self.fixtureKey, encoding: .utf8))
    }

    /// Creates a vault through the library, with this test's CLI as its home device (its trust record
    /// saved), and writes a two-page note plus a one-page note. Returns the vault, the identity and the
    /// device key file's path (`--identity`).
    public func makeVault(named name: String = "mine.sempere") throws -> (vault: Vault, identity: NativeIdentity, keyPath: String) {
        let id = try NativeIdentity.generate(.postQuantum)
        let keyPath = path("\(name).key")
        try TestVaults.deviceKeyFile(id).write(toFile: keyPath, atomically: true, encoding: .utf8)
        let vault = try TestVaults.create(at: tmp.appendingPathComponent(name), identities: [id], names: ["laptop"],
                                          trust: cliTrustStore)
        let device = DeviceID("abcdef01")!
        func stroke(_ n: Double) -> Stroke {
            var pts: [StrokePoint] = []
            for i in 0..<5 {
                let k = Double(i)
                pts.append(StrokePoint(x: 40 + n * 10 + k * 12, y: 100 + k * 9, t: k * 0.02, w: 2.5, h: 2.5))
            }
            return Stroke(ink: Ink(tool: .pen, color: .black, width: 2.5), points: pts)
        }
        func rev(_ note: UUID, _ seq: Int, _ ms: Int64, _ ops: [Op]) -> Revision {
            Revision(noteId: note, device: device, seq: seq, hlc: HLC(millis: 1_760_000_000_000 + ms, counter: 0)!,
                     wall: Date(timeIntervalSince1970: Double(1_760_000_000_000 + ms) / 1000),
                     app: "cli-test/1", body: .delta(ops: ops))
        }
        let n1 = UUID(uuidString: "aaaaaaaa-1111-4111-8111-000000000001")!
        let n2 = UUID(uuidString: "bbbbbbbb-2222-4222-8222-000000000002")!
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        try vault.write(rev(n1, 1, 1000, [.addPage(Page(id: p1, order: "a0")), .setMeta(.title("Physics / Week 3")),
                                          .addTag("physics"), .setMeta(.paper(.ruled)),
                                          .addStroke(page: p1, stroke: stroke(1))]))
        try vault.write(rev(n1, 2, 2000, [.addPage(Page(id: p2, order: "a1")), .addStroke(page: p2, stroke: stroke(2)),
                                          .addStroke(page: p2, stroke: stroke(3))]))
        try vault.write(rev(n2, 1, 3000, [.addPage(Page(id: p3, order: "a0")), .setMeta(.title("Groceries")),
                                          .addStroke(page: p3, stroke: stroke(4))]))
        return (vault, id, keyPath)
    }
}

/// A lock-protected Data cell for handing a pipe's contents between threads.
public final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    public func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    public func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
