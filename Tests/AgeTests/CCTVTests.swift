import Crypto
import Foundation
import XCTest

@testable import Age

/// Runs every C2SP CCTV age vector in Tests/AgeTests/Vectors (format in the
/// README there), mirroring the reference `testkit_test.go`.
final class CCTVTests: XCTestCase {
    struct Vector {
        var name: String
        var expect = ""
        var payloadHash: Data?
        var fileKey: Data?
        var identities: [any AgeIdentity] = []
        var unparsedIdentities: [String] = []
        var armored = false
        var file = Data()
    }

    static func hex(_ s: String) -> Data {
        var out = Data()
        var it = s.utf8.makeIterator()
        while let a = it.next(), let b = it.next() {
            let pair: String = String(decoding: [a, b], as: UTF8.self)
            let byte: UInt8 = UInt8(pair, radix: 16)!
            out.append(byte)
        }
        return out
    }

    static func parse(name: String, contents: Data) throws -> Vector {
        var v = Vector(name: name)
        var rest = contents[...]
        var compressed = false
        while true {
            guard let nl = rest.firstIndex(of: 0x0A) else { throw XCTSkip("\(name): no payload separator") }
            let line = String(decoding: rest[rest.startIndex..<nl], as: UTF8.self)
            rest = rest[(nl + 1)...]
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
            let key = parts[0]
            let value = parts.count > 1 ? String(parts[1].dropFirst()) : ""
            switch key {
            case "expect": v.expect = value
            case "payload": v.payloadHash = hex(value)
            case "file key": v.fileKey = hex(value)
            case "identity":
                if let id = try? NativeIdentity(string: value) {
                    v.identities.append(id)
                } else {
                    v.unparsedIdentities.append(value)
                }
            case "passphrase": v.identities.append(ScryptIdentity(passphrase: value))
            case "armored": v.armored = value == "yes"
            case "compressed":
                XCTAssertEqual(value, "zlib", name)
                compressed = true
            case "comment": break
            default: XCTFail("\(name): unknown header key \(key)")
            }
        }
        v.file = compressed ? try zlibUncompress(Data(rest)) : Data(rest)
        return v
    }

    static let headerFailures: Set<AgeError> = [
        .headerParse, .unsupportedVersion, .invalidStanza, .scryptNotAlone, .scryptWorkFactor,
    ]

    func expectedErrors(_ expect: String) -> Set<AgeError>? {
        switch expect {
        case "success": return nil
        case "payload failure": return [.payload]
        case "HMAC failure": return [.headerMAC]
        case "no match": return [.noMatchingIdentity]
        case "header failure": return Self.headerFailures
        case "armor failure": return [.armor]
        default:
            XCTFail("unknown expect \(expect)")
            return []
        }
    }

    func testCCTVVectors() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Vectors", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0 != "README.md" && $0 != "UPSTREAM_COMMIT" }
            .sorted()
        XCTAssertEqual(names.count, 147, "expected the full CCTV set")

        streamed = 0
        var counts: [String: Int] = [:]
        var hybrid = 0
        for name in names {
            let v = try Self.parse(name: name, contents: Data(contentsOf: dir.appendingPathComponent(name)))
            XCTAssertTrue(v.unparsedIdentities.isEmpty, "\(name): needs an identity we cannot parse")
            if v.identities.contains(where: { ($0 as? NativeIdentity)?.isPostQuantum == true }) { hybrid += 1 }
            check(v)
            counts[v.expect, default: 0] += 1
        }
        // Every MLKEM768-X25519 vector (CCTV "hybrid*") ran with its PQ identity.
        XCTAssertEqual(hybrid, 19)
        let total = counts.values.reduce(0, +)
        XCTAssertEqual(total, 147)
        // Every vector whose armor (if any) decodes ran through the streaming decryptor.
        XCTAssertEqual(streamed, (147 - counts["armor failure", default: 0]) * Self.readPatterns.count)
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        print("CCTV: \(total) vectors exercised (\(summary))")
    }

    func check(_ v: Vector) {
        let name = v.name
        let expected = expectedErrors(v.expect)

        // 1. The reference harness path: strip armor explicitly when the
        //    vector says so, then decrypt the binary file chunk by chunk.
        var binary = v.file
        if v.armored {
            do {
                binary = try Armor.decode(v.file)
            } catch {
                XCTAssertEqual(error as? AgeError, .armor, name)
                XCTAssertEqual(v.expect, "armor failure", "\(name): unexpected armor failure")
                return checkPublicAPIFails(v)
            }
            // Armor round trip (README): re-encoding gives the normalised input.
            var norm = [UInt8](v.file)
            norm = Array(String(decoding: norm, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
            while let f = norm.first, Armor.isSpace(f) { norm.removeFirst() }
            while let l = norm.last, Armor.isSpace(l) { norm.removeLast() }
            XCTAssertEqual(Armor.encode(binary), Data(norm + [0x0A]), "\(name): armor round trip")
        }

        checkStreaming(v, binary: binary)

        var released = Data()
        do {
            let fileKey = try AgeFile.decrypt(binary: binary, with: v.identities, released: &released)
            XCTAssertNil(expected, "\(name): expected \(v.expect), got success")
            XCTAssertEqual(fileKey.bytes, v.fileKey, "\(name): file key")
            XCTAssertEqual(Data(SHA256.hash(data: released)), v.payloadHash, "\(name): payload hash")
            // Header encode/decode round trip and STREAM re-encryption (README).
            if let (header, start) = try? AgeFile.parseHeader(binary) {
                let reencoded = try? HeaderCodec.encodeWithoutMAC(header.stanzas)
                    + Array(" \(Base64.encodeRaw(header.mac))\n".utf8)
                XCTAssertEqual(reencoded.map { Data($0) }, binary.prefix(start), "\(name): header round trip")
                let nonce = binary.dropFirst(start).prefix(Stream.nonceSize)
                let key = Stream.payloadKey(fileKey: fileKey, nonce: nonce)
                XCTAssertEqual(
                    try? Stream.encrypt(released, key: key), binary.dropFirst(start + Stream.nonceSize),
                    "\(name): STREAM round trip")
            }
            // The public API (with armor auto-detection) agrees.
            XCTAssertEqual(try? AgeFile.decrypt(v.file, with: v.identities), released, "\(name): public API")
        } catch {
            guard let expected else {
                return XCTFail("\(name): expected success, got \(error)")
            }
            let ageError = error as? AgeError
            XCTAssertTrue(
                ageError.map(expected.contains) ?? false,
                "\(name): expected \(v.expect), got \(error)")
            if v.expect == "payload failure" {
                XCTAssertEqual(
                    Data(SHA256.hash(data: released)), v.payloadHash,
                    "\(name): partial payload hash (\(released.count) bytes released)")
            }
            if v.expect != "header failure", v.expect != "armor failure" {
                XCTAssertNoThrow(try AgeFile.parseHeader(binary), "\(name): header should parse")
            }
            checkPublicAPIFails(v)
        }
    }

    func checkPublicAPIFails(_ v: Vector) {
        XCTAssertThrowsError(try AgeFile.decrypt(v.file, with: v.identities), "\(v.name): public API should fail")
    }

    // MARK: - Streaming (attachments B1)

    /// Read sizes handed to the streaming decryptor's source: whole reads,
    /// an odd size (chunk boundaries fall inside reads), and single bytes
    /// (0) for the first 8 KiB, which covers every header, the nonce and the
    /// start of the first chunk, then 4099-byte reads (single bytes over a
    /// whole payload take seconds in a debug build).
    static let readPatterns = [Int.max, 7_919, 0]
    var streamed = 0

    /// Runs `binary` through `AgeDecryptor` with each read pattern and
    /// checks the same outcome as the reference harness: success with the
    /// payload and file key, or a failure of the expected class having
    /// released exactly the reference's partial payload. For success vectors
    /// also re-encrypts with `AgeEncryptor` (vector key, nonce and header;
    /// odd piece sizes) to the identical bytes, and rewraps the header.
    func checkStreaming(_ v: Vector, binary: Data) {
        let name = v.name
        let expected = expectedErrors(v.expect)
        for pattern in Self.readPatterns {
            streamed += 1
            var offset = 0
            var released = Data()
            var decryptor: AgeDecryptor?
            do {
                let d = try AgeDecryptor(identities: v.identities) { n in
                    let size = pattern > 0 ? pattern : (offset < 8192 ? 1 : 4099)
                    let k = min(n, size, binary.count - offset)
                    defer { offset += k }
                    return binary.subdata(in: offset..<offset + k)
                }
                decryptor = d
                while let chunk = try d.next() {
                    XCTAssertLessThanOrEqual(chunk.count, 64 * 1024, "\(name): chunk size")
                    released += chunk
                }
                XCTAssertNil(try d.next(), "\(name): stays finished")
                XCTAssertNil(expected, "\(name) [stream \(pattern)]: expected \(v.expect), got success")
                XCTAssertEqual(d.fileKey.bytes, v.fileKey, "\(name) [stream]: file key")
                XCTAssertEqual(Data(SHA256.hash(data: released)), v.payloadHash, "\(name) [stream]: payload")
            } catch {
                guard let expected else {
                    XCTFail("\(name) [stream \(pattern)]: expected success, got \(error)")
                    continue
                }
                XCTAssertTrue((error as? AgeError).map(expected.contains) ?? false,
                              "\(name) [stream \(pattern)]: expected \(v.expect), got \(error)")
                if v.expect == "payload failure" {
                    XCTAssertEqual(Data(SHA256.hash(data: released)), v.payloadHash,
                                   "\(name) [stream \(pattern)]: partial payload (\(released.count) bytes)")
                    // Errors are sticky.
                    if let d = decryptor {
                        XCTAssertThrowsError(try d.next(), "\(name): sticky error") {
                            XCTAssertEqual($0 as? AgeError, error as? AgeError)
                        }
                    }
                }
            }
        }
        guard expected == nil, let fileKey = v.fileKey,
              let (_, start) = try? AgeFile.parseHeader(binary),
              let key = try? FileKey(bytes: fileKey)
        else { return }

        // STREAM re-encryption through AgeEncryptor, fed in uneven pieces.
        var plain = Data()
        _ = try? AgeFile.decrypt(binary: binary, with: v.identities, released: &plain)
        let nonce = binary.subdata(in: start..<start + 16)
        let encryptor = AgeEncryptor(header: binary.prefix(start), fileKey: key, nonce: nonce)
        var out = Data()
        var i = 0, step = 1
        while i < plain.count {
            let end = min(i + step, plain.count)
            out += (try? encryptor.update(plain.subdata(in: i..<end))) ?? Data()
            i = end
            step = step * 3 + 1
        }
        out += (try? encryptor.finish()) ?? Data()
        XCTAssertEqual(out, binary, "\(name): streaming re-encryption")

        // Header-only rewrap to a new recipient: same nonce and payload bytes,
        // new single stanza, opens with the new key only.
        let fresh = X25519Identity()
        guard let rewrapped = try? AgeFile.rewrapHeader(binary, identities: v.identities, recipients: [fresh.recipient])
        else { return XCTFail("\(name): rewrap failed") }
        guard let (newHeader, newStart) = try? AgeFile.parseHeader(rewrapped) else { return XCTFail("\(name): rewrap header") }
        XCTAssertEqual(newHeader.stanzas.map(\.type), ["X25519"], name)
        XCTAssertEqual(rewrapped.dropFirst(newStart), binary.dropFirst(start), "\(name): payload copied unchanged")
        XCTAssertEqual(try? AgeFile.decrypt(rewrapped, with: [fresh]), plain, "\(name): rewrapped decrypts")
    }
}
