import Foundation
import FuzzSupport
import XCTest

@testable import Age

/// Seeded mutation fuzzing of every age parser (header, armor, STREAM, Bech32,
/// scrypt stanza). Inputs come from a hostile sync server or shared folder:
/// anything may throw `AgeError`, nothing may trap, hang or allocate without
/// bound. See Tests/FuzzSupport for the knobs (SEMPERE_FUZZ_LONG, ...).
final class AgeFuzzTests: XCTestCase {
    static let identities = [X25519Identity(), X25519Identity()]

    static func plaintexts() -> [Data] {
        var g = FuzzRNG(seed: 7)
        return [0, 1, 47, 48, 64 * 1024, 64 * 1024 + 1].map { n in Data((0..<n).map { _ in UInt8(truncatingIfNeeded: g.next()) }) }
    }

    func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    /// Any error is fine, as long as it is an `AgeError`.
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is AgeError { } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    func testFuzzBinaryFiles() throws {
        let ids = Self.identities
        var seeds: [Data] = []
        for (i, p) in Self.plaintexts().enumerated() {
            seeds.append(try AgeFile.encrypt(p, to: Array(ids.prefix(1 + i % 2)).map(\.recipient)))
        }
        assertClean(Fuzz.run("age-binary", seeds: seeds, quick: 3000, maxSize: 256 << 10) { input in
            Self.typed {
                _ = try? AgeFile.parseHeader(input)
                _ = try AgeFile.decrypt(input, with: ids)
            }
        })
    }

    /// Differential: the streaming decryptor (fed in uneven reads) and the
    /// buffer API agree on every mutated file: same plaintext, or the same
    /// error after releasing the same bytes. Mutations land in the header,
    /// in chunk boundaries and in the final-chunk flag.
    func testFuzzStreamingMatchesBuffer() throws {
        let ids = Self.identities
        var seeds: [Data] = []
        for (i, p) in Self.plaintexts().enumerated() {
            seeds.append(try AgeFile.encrypt(p, to: Array(ids.prefix(1 + i % 2)).map(\.recipient)))
        }
        seeds.append(try AgeFile.encrypt(Data(count: 2 * 64 * 1024), to: [ids[0].recipient]))
        assertClean(Fuzz.run("age-stream", seeds: seeds, quick: 2000, maxSize: 256 << 10) { input in
            var bufferReleased = Data()
            var bufferError: AgeError?
            do { _ = try AgeFile.decrypt(binary: input, with: ids, released: &bufferReleased) } catch {
                guard let e = error as? AgeError else { return "buffer: untyped error \(error)" }
                bufferError = e
            }
            var streamReleased = Data()
            var streamError: AgeError?
            var offset = 0, step = 1
            do {
                let d = try AgeDecryptor(identities: ids) { n in
                    let k = min(n, step, input.count - offset)
                    defer { offset += k; step = step % 9_973 + 7 }
                    return input.subdata(in: offset..<offset + k)
                }
                while let chunk = try d.next() { streamReleased += chunk }
            } catch {
                guard let e = error as? AgeError else { return "stream: untyped error \(error)" }
                streamError = e
            }
            if streamError != bufferError { return "errors differ: stream \(String(describing: streamError)), buffer \(String(describing: bufferError))" }
            if streamReleased != bufferReleased { return "released \(streamReleased.count) vs \(bufferReleased.count) bytes" }
            return nil
        })
    }

    func testFuzzArmoredFiles() throws {
        let ids = Self.identities
        let seeds = try Self.plaintexts().prefix(4).map { try AgeFile.encrypt($0, to: [ids[0].recipient], armor: true) }
        assertClean(Fuzz.run("age-armor", seeds: Array(seeds), quick: 3000, text: true, maxSize: 256 << 10) { input in
            Self.typed {
                _ = try? Armor.decode(input)
                _ = try AgeFile.decrypt(input, with: ids)
            }
        })
    }

    /// Passphrase files: the stanza names its own work factor, so the reader's
    /// cap is what bounds memory (here 2^12 KiB).
    func testFuzzScryptFiles() throws {
        let seeds = try [Data("AGE-SECRET-KEY-1...".utf8), Data()].map {
            try AgeFile.encrypt($0, to: [ScryptRecipient(passphrase: "pw", workFactor: 2)])
        }
        let id = ScryptIdentity(passphrase: "pw", maxWorkFactor: 12, maxMemoryBytes: 8 << 20)
        assertClean(Fuzz.run("age-scrypt", seeds: seeds, quick: 1500, text: true) { input in
            Self.typed { _ = try AgeFile.decrypt(input, with: [id]) }
        })
    }

    func testFuzzBech32Keys() throws {
        let seeds = Self.identities.flatMap { [Data($0.string.utf8), Data($0.recipient.string.utf8)] }
        assertClean(Fuzz.run("bech32", seeds: seeds, quick: 5000, text: true, maxSize: 4096) { input in
            let s = String(decoding: input, as: UTF8.self)
            return Self.typed {
                _ = try? X25519Recipient(string: s)
                _ = try X25519Identity(string: s)
            }
        })
    }
}
