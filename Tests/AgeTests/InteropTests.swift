import Foundation
import TempDirSupport
import XCTest

@testable import Age

/// Interop with the reference `age` / `age-keygen` CLI (skipped when they
/// are not on PATH).
///
/// Passphrase interop is one-directional here: `age -p` and `age -d` read
/// passphrases only from a terminal, so they cannot be scripted. Reference
/// scrypt output is covered by the CCTV `scrypt*` vectors (decrypt
/// direction); our scrypt output is covered by our own round trips.
final class InteropTests: TempDirTestCase {
    static func which(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs: [String] = path.split(separator: ":").map { String($0) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func tools() throws -> (age: URL, keygen: URL) {
        guard let age = Self.which("age"), let keygen = Self.which("age-keygen") else {
            throw XCTSkip("age / age-keygen not on PATH")
        }
        return (age, keygen)
    }

    @discardableResult
    func run(_ exe: URL, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        // stderr from age is small; stdout is drained first so a large
        // plaintext cannot fill the pipe and stall the child.
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(
            p.terminationStatus, 0,
            "\(exe.lastPathComponent) \(args.joined(separator: " ")): \(String(decoding: err, as: UTF8.self))")
        return out
    }

    func random(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    func testX25519BothDirections() throws {
        let (age, keygen) = try tools()
        let keyFile = tmp.appendingPathComponent("key.txt")
        try run(keygen, ["-o", keyFile.path])
        let keyText = try String(contentsOf: keyFile, encoding: .utf8)
        let secret = try XCTUnwrap(keyText.split(separator: "\n").first { $0.hasPrefix("AGE-SECRET-KEY-1") })
        let publicLine = try XCTUnwrap(keyText.split(separator: "\n").first { $0.hasPrefix("# public key: ") })
        let identity = try X25519Identity(string: String(secret))
        XCTAssertEqual(identity.string, String(secret))
        XCTAssertEqual(identity.recipient.string, String(publicLine.dropFirst("# public key: ".count)))
        // age-keygen -y agrees on the recipient.
        let derived = String(decoding: try run(keygen, ["-y", keyFile.path]), as: UTF8.self)
        XCTAssertEqual(derived.trimmingCharacters(in: .whitespacesAndNewlines), identity.recipient.string)

        for size in [0, 1, 65_536, 65_537, 200_000] {
            let plaintext = random(size)
            for armor in [false, true] {
                // Ours -> age -d.
                let ct = try AgeFile.encrypt(plaintext, to: [identity.recipient], armor: armor)
                let ctFile = tmp.appendingPathComponent("ours-\(size)-\(armor).age")
                try ct.write(to: ctFile)
                XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, ctFile.path]), plaintext, "ours->age \(size) \(armor)")

                // age -r -> ours.
                let ptFile = tmp.appendingPathComponent("pt-\(size)")
                try plaintext.write(to: ptFile)
                let outFile = tmp.appendingPathComponent("theirs-\(size)-\(armor).age")
                try run(age, ["-r", identity.recipient.string] + (armor ? ["-a"] : []) + ["-o", outFile.path, ptFile.path])
                let theirs = try Data(contentsOf: outFile)
                XCTAssertEqual(try AgeFile.decrypt(theirs, with: [identity]), plaintext, "age->ours \(size) \(armor)")
            }
        }
    }

    func testOurKeysWorkWithAge() throws {
        let (age, keygen) = try tools()
        let identity = X25519Identity()
        let keyFile = tmp.appendingPathComponent("ours.txt")
        try "\(identity.string)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let derived = String(decoding: try run(keygen, ["-y", keyFile.path]), as: UTF8.self)
        XCTAssertEqual(derived.trimmingCharacters(in: .whitespacesAndNewlines), identity.recipient.string)

        // Multiple recipients, one of them from age-keygen.
        let other = tmp.appendingPathComponent("other.txt")
        try run(keygen, ["-o", other.path])
        let otherRecipient = String(decoding: try run(keygen, ["-y", other.path]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plaintext = random(1000)
        let ct = try AgeFile.encrypt(plaintext, to: [identity.recipient, try X25519Recipient(string: otherRecipient)])
        let ctFile = tmp.appendingPathComponent("multi.age")
        try ct.write(to: ctFile)
        XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, ctFile.path]), plaintext)
        XCTAssertEqual(try run(age, ["-d", "-i", other.path, ctFile.path]), plaintext)
    }

    // MARK: - MLKEM768-X25519 (needs age >= 1.3)

    /// `age` and `age-keygen` from PATH when they are v1.3 or later (the
    /// first with `-pq`). Skips otherwise, unless SEMPERE_REQUIRE_AGE_PQ is
    /// set (CI), which turns a missing or old `age` into a failure.
    func pqTools() throws -> (age: URL, keygen: URL) {
        let required = ProcessInfo.processInfo.environment["SEMPERE_REQUIRE_AGE_PQ"] != nil
        guard postQuantumAvailable else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but this OS lacks X-Wing") }
            throw XCTSkip("no X-Wing on this OS")
        }
        guard let age = Self.which("age"), let keygen = Self.which("age-keygen") else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is not on PATH") }
            throw XCTSkip("age / age-keygen not on PATH")
        }
        let version = String(decoding: try run(age, ["--version"]), as: UTF8.self)
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" }.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3) else {
            if required { XCTFail("SEMPERE_REQUIRE_AGE_PQ set but age is \(version)") }
            throw XCTSkip("age \(version) predates post-quantum recipients (needs 1.3)")
        }
        return (age, keygen)
    }

    /// age-keygen -pq keys parse and derive the same recipient; files `age`
    /// encrypts to them we decrypt, and the other way round.
    func testPostQuantumBothDirections() throws {
        let (age, keygen) = try pqTools()
        let keyFile = tmp.appendingPathComponent("pq.txt")
        try run(keygen, ["-pq", "-o", keyFile.path])
        let keyText = try String(contentsOf: keyFile, encoding: .utf8)
        let secret = try XCTUnwrap(keyText.split(separator: "\n").first { $0.hasPrefix("AGE-SECRET-KEY-PQ-1") })
        let publicLine = try XCTUnwrap(keyText.split(separator: "\n").first { $0.hasPrefix("# public key: ") })
        let identity = try MLKEM768X25519Identity(string: String(secret))
        XCTAssertEqual(identity.string, String(secret))
        XCTAssertEqual(identity.recipient.string, String(publicLine.dropFirst("# public key: ".count)))
        let derived = String(decoding: try run(keygen, ["-y", keyFile.path]), as: UTF8.self)
        XCTAssertEqual(derived.trimmingCharacters(in: .whitespacesAndNewlines), identity.recipient.string)

        for size in [0, 1, 65536, 200_000] {
            let plain = random(size)
            // age encrypts, we decrypt (binary and armored).
            let input = tmp.appendingPathComponent("in-\(size)")
            try plain.write(to: input)
            for armor in [false, true] {
                let out = tmp.appendingPathComponent("theirs-\(size)-\(armor).age")
                try run(age, ["-r", identity.recipient.string] + (armor ? ["-a"] : []) + ["-o", out.path, input.path])
                let file = try Data(contentsOf: out)
                XCTAssertEqual(try AgeFile.parseHeader(armor ? Armor.decode(file) : file).header.stanzas.map(\.type),
                               ["mlkem768x25519"])
                XCTAssertEqual(try AgeFile.decrypt(file, with: [identity]), plain, "age -> us, \(size), armor \(armor)")
            }
            // We encrypt, age decrypts.
            let ours = tmp.appendingPathComponent("ours-\(size).age")
            try AgeFile.encrypt(plain, to: [identity.recipient], armor: size == 1).write(to: ours)
            XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, ours.path]), plain, "us -> age, \(size)")
        }
    }

    /// Keys we generate work with `age`, alone and with several PQ recipients.
    func testOurPostQuantumKeysWorkWithAge() throws {
        let (age, keygen) = try pqTools()
        let ids = try (0..<2).map { _ in try MLKEM768X25519Identity() }
        let keyFile = tmp.appendingPathComponent("ours.txt")
        try "# public key: \(ids[1].recipient.string)\n\(ids[1].string)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let derived = String(decoding: try run(keygen, ["-y", keyFile.path]), as: UTF8.self)
        XCTAssertEqual(derived.trimmingCharacters(in: .whitespacesAndNewlines), ids[1].recipient.string)
        let file = tmp.appendingPathComponent("two.age")
        try AgeFile.encrypt(Data("two pq".utf8), to: ids.map(\.recipient)).write(to: file)
        XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, file.path]), Data("two pq".utf8))
        // A recipients file listing both, encrypted by age.
        let list = tmp.appendingPathComponent("recipients.txt")
        try ids.map(\.recipient.string).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let theirs = tmp.appendingPathComponent("theirs.age")
        let input = tmp.appendingPathComponent("in")
        try Data("from age".utf8).write(to: input)
        try run(age, ["-R", list.path, "-o", theirs.path, input.path])
        for id in ids { XCTAssertEqual(try AgeFile.decrypt(try Data(contentsOf: theirs), with: [id]), Data("from age".utf8)) }
    }

    /// A mixed X25519 + PQ file (what a vault holds while it changes key
    /// type) decrypts with `age` under either identity.
    func testMixedFileDecryptsWithAge() throws {
        let (age, keygen) = try pqTools()
        let pqFile = tmp.appendingPathComponent("pq.txt"), xFile = tmp.appendingPathComponent("x.txt")
        try run(keygen, ["-pq", "-o", pqFile.path])
        try run(keygen, ["-o", xFile.path])
        func recipient(_ f: URL) throws -> NativeRecipient {
            try NativeRecipient(string: String(decoding: try run(keygen, ["-y", f.path]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let mixed = tmp.appendingPathComponent("mixed.age")
        try AgeFile.encrypt(Data("mixed".utf8), to: [try recipient(pqFile), try recipient(xFile)],
                            allowMixedPostQuantum: true).write(to: mixed)
        XCTAssertEqual(try run(age, ["-d", "-i", pqFile.path, mixed.path]), Data("mixed".utf8))
        XCTAssertEqual(try run(age, ["-d", "-i", xFile.path, mixed.path]), Data("mixed".utf8))
    }

    // MARK: - Streaming, rewrap, re-encrypt (attachments B1)

    /// Exit status of a tool run expected to fail (stderr discarded).
    func status(_ exe: URL, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A fresh key file from `age-keygen` (post-quantum with `pq`) and our
    /// identity parsed from it.
    func keygen(_ keygen: URL, pq: Bool, _ name: String) throws -> (file: URL, identity: NativeIdentity) {
        let file = tmp.appendingPathComponent(name)
        try run(keygen, (pq ? ["-pq"] : []) + ["-o", file.path])
        let text = try String(contentsOf: file, encoding: .utf8)
        let secret = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("AGE-SECRET-KEY-") })
        return (file, try NativeIdentity(string: String(secret)))
    }

    /// Files streamed by us decrypt with `age`, and files from `age`
    /// decrypt through our streaming APIs, for both key types, at sizes
    /// around chunk boundaries and a multi-megabyte one.
    func testStreamingBothDirections() throws {
        let (age, keygenTool) = try pqTools()
        for pq in [true, false] {
            let (keyFile, identity) = try keygen(keygenTool, pq: pq, "key-\(pq)")
            for size in [0, 1, 65_536, 65_537, 1_000_003] {
                let plain = random(size)
                let input = tmp.appendingPathComponent("plain-\(pq)-\(size)")
                try plain.write(to: input)

                let ours = tmp.appendingPathComponent("ours-\(pq)-\(size).age")
                try AgeFile.encrypt(contentsOf: input, to: ours, recipients: [identity.recipient])
                XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, ours.path]), plain, "us -> age, pq \(pq), \(size)")

                let theirs = tmp.appendingPathComponent("theirs-\(pq)-\(size).age")
                try run(age, ["-r", identity.recipient.string, "-o", theirs.path, input.path])
                let out = tmp.appendingPathComponent("out-\(pq)-\(size)")
                try AgeFile.decrypt(contentsOf: theirs, to: out, identities: [identity])
                XCTAssertEqual(try Data(contentsOf: out), plain, "age -> us, pq \(pq), \(size)")
                XCTAssertEqual(try AgeFile.readHeader(contentsOf: theirs).stanzas.map(\.type),
                               [pq ? "mlkem768x25519" : "X25519"])
            }
        }
    }

    /// A file from `age`, rewrapped header-only by us to another key, opens
    /// with `age` and that key only, with the nonce and payload bytes
    /// unchanged; re-encrypted by us, it opens with `age` too. Both key
    /// types, and a mixed set during a migration.
    func testRewrapAndReencryptWithAge() throws {
        let (age, keygenTool) = try pqTools()
        let plain = random(200_000)
        let input = tmp.appendingPathComponent("plain")
        try plain.write(to: input)
        for pq in [true, false] {
            let (oldKey, oldId) = try keygen(keygenTool, pq: pq, "old-\(pq)")
            let (newKey, newId) = try keygen(keygenTool, pq: pq, "new-\(pq)")
            let theirs = tmp.appendingPathComponent("theirs-\(pq).age")
            try run(age, ["-r", oldId.recipient.string, "-o", theirs.path, input.path])

            let rewrapped = tmp.appendingPathComponent("rewrapped-\(pq).age")
            try AgeFile.rewrapHeader(contentsOf: theirs, to: rewrapped, identities: [oldId], recipients: [newId.recipient])
            XCTAssertEqual(try run(age, ["-d", "-i", newKey.path, rewrapped.path]), plain, "rewrap, pq \(pq)")
            XCTAssertNotEqual(try status(age, ["-d", "-i", oldKey.path, rewrapped.path]), 0, "old key, pq \(pq)")
            let a = try Data(contentsOf: theirs), b = try Data(contentsOf: rewrapped)
            XCTAssertEqual(b.dropFirst(try AgeFile.parseHeader(b).payloadStart),
                           a.dropFirst(try AgeFile.parseHeader(a).payloadStart), "payload unchanged, pq \(pq)")

            // Rewrapped to both keys, age opens it with either.
            let both = try AgeFile.rewrapHeader(a, identities: [oldId], recipients: [oldId.recipient, newId.recipient])
            let bothFile = tmp.appendingPathComponent("both-\(pq).age")
            try both.write(to: bothFile)
            for key in [oldKey, newKey] { XCTAssertEqual(try run(age, ["-d", "-i", key.path, bothFile.path]), plain) }

            let reencrypted = tmp.appendingPathComponent("reencrypted-\(pq).age")
            try AgeFile.reencrypt(contentsOf: rewrapped, to: reencrypted, identities: [newId], recipients: [oldId.recipient])
            XCTAssertEqual(try run(age, ["-d", "-i", oldKey.path, reencrypted.path]), plain, "reencrypt, pq \(pq)")
            XCTAssertNotEqual(try status(age, ["-d", "-i", newKey.path, reencrypted.path]), 0)
        }
        // Classic to post-quantum (format.md §8.1.5 type change), through a mixed header.
        let (xKey, xId) = try keygen(keygenTool, pq: false, "x")
        let (pqKey, pqId) = try keygen(keygenTool, pq: true, "pq")
        let classic = tmp.appendingPathComponent("classic.age")
        try run(age, ["-r", xId.recipient.string, "-o", classic.path, input.path])
        let mixed = tmp.appendingPathComponent("mixed.age")
        try AgeFile.rewrapHeader(contentsOf: classic, to: mixed, identities: [xId],
                                 recipients: [xId.recipient, pqId.recipient], allowMixedPostQuantum: true)
        for key in [xKey, pqKey] { XCTAssertEqual(try run(age, ["-d", "-i", key.path, mixed.path]), plain) }
        let migrated = tmp.appendingPathComponent("migrated.age")
        try AgeFile.reencrypt(contentsOf: mixed, to: migrated, identities: [pqId], recipients: [pqId.recipient])
        XCTAssertEqual(try AgeFile.readHeader(contentsOf: migrated).stanzas.map(\.type), ["mlkem768x25519"])
        XCTAssertEqual(try run(age, ["-d", "-i", pqKey.path, migrated.path]), plain)
    }
}
