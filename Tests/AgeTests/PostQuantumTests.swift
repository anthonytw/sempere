import Foundation
import XCTest

@testable import Age

/// The MLKEM768-X25519 hybrid recipient type (c2sp.org/age). The official
/// vectors are the CCTV `hybrid*` files run by CCTVTests; the reference CLI
/// interop is in InteropTests.
final class PostQuantumTests: XCTestCase {
    // From the age spec, "The MLKEM768-X25519 (i.e. X-Wing) hybrid
    // post-quantum recipient type": an identity and its recipient.
    static let specIdentity = "AGE-SECRET-KEY-PQ-1XX76JRALNLXDMEW0CRK45QMCCH4X06SE84UN3VPM33W6HWDX0H3SK3ZQFR"
    static let specRecipient =
        "age1pq1x34nzsvr0rxjsgdn8zgyhfe8j7ceq5r9rdelkjuh3y235jzxshfg87pzf5zrqtzdxz95paef6caq5aapdmwjjqpjfdyxnzr2zampc3uxy0dg4z2n2gm9su72p0pc3u0jvev55l694v78snxg3yzvcl7yda0eyytqj6a0ec477lnhcy5hzpz4zq3pxanve4cn62gqj3pjy5lqj9c6kyj4v2z8alktn8zh99970x79gjkv7522hv9kfz35zsnxhsx8wwtmu9cy3ftzjgwcp4sshn3llnylnpdsyz5jm72vefv4x5vfwytrefxg4wq3mv42wcrvkj742479zrxzpvp2p3e9fed9f0739vcu80r7ma28qfhnvlv4gfzel9q654dj3zmuvvz893azhxdvs9fxd0r7jzchzcfcs5mkyyjxhw0n2z6dvp9yn9qfdp29h0azxqyjw6v7fhyuzj7zel0uq6j9rd7wgrpz7mf5dnj43jwsgvrc8qcnhy7tu6dkdujuxzkp9xj43xe8h92ktre2a3u3s8mm5mrp9nr9pwkgtz4mdlq9hgn4fps4k57ff6wddn2fy23t47sm20r8km8sd2pcyyafnet8f0dajsrlyjeah4n3mssr6aseevuuskdvq5lzguyvpgwpta742c6698vgutzqgny8usfg0w2he7kq5vyxjd0f9hqg8xk26y9e4th0gezq92q4cpp5p2y9hf5f2cje5l0c3sa3a2qxmm38pxxvhxh99yzmfz0zk7r2s64nnwjhkfgfr3gf8xnmppcgmaykvh5sh6g7vk9790rf8ws0axmr2t7z8aae5fq2029uvcn2ghgt4fu4wgwdc0k0cz52qkvwmuzj8p8k5jgf3xzk5zmrkavjekjrpeq408xz3zxazwkc6tyfmhayrkfpjhwtz5mp8j8guqe43k2q6m2kte03vrw27y3wmqyu5etmt9dnkwcnnpmu9gz9dekfhdevf42ucshphnrk38ra6hx8w5f8q5ru0xdhrjxmwqf6cused7zc5xvq43r0zscjglpwlptpwydhqw64xz7ptjdyeyzpq2zkxtmzg29gzjpvzva4d3l0cenn9xs297wf4y4ukwrunf57xj6pm7nvrkwvtrt8hwcmgv8x7ajw7258ugf9wvkmk4052ekg87tw5vnx8nq2swyzv77v8yqlwsenvamr0zssknwts8rrhfuwj7ykysnq9jxy0uv3kuyt22djszjdtvpz6d0s0kwh8ryynddzud92emeyvvyqktd0jtj7rvvg5gch25v8smlvny3kvn5gagyz475ze2y6q466xqmz2n3hs77lddeqyta2nch5k2u5yacuk9ywnwfdzvyejnucz724hj77hrrmakm7pr3kxsrxq22ejexlud9fy2kdqmkg5yncz7jm5wv2qjk5w5kvcpqsry2yqffh2la52dxfjkjq5rzhjzeyn6dupn0qwtyv7s4lwg3xdarsdlwe2y3tujy480y7z39q259fzx6jhd2j0f5hagqpcpees7hzc2yrk5cy788uk3s7qvp5cpepx24gvws3m2g433exgwppnkjscec8qu4y9z9r7vccexjcjaen42245lmgmxmuavg9alej92322gvvyy2t6267v09ch64y0m53jff0vjj96s0ypk60hr3jw4myd6m5hpn3xjstx7tl2szhpr5qe8jj08ydjc4wy2rch2fhuy3pdfjax5awe9j99ly5hkntzz9fe5zatgjvzdd0kgtxs25njnajyf6ssekp7gelxquusn4pt25czh3scj68kq79wdn5tgm6yvm9nzavrg043x3msnygf8dweknw5jmqd0uvny6ttsn09508k0c55zfnegrm9efhxpfqdkmhh6gjtqmwze9pyyzk3tlhl53k2ykx3qheyty7saeq0d3fzv49zc0k"

    override func setUpWithError() throws {
        guard postQuantumAvailable else { throw XCTSkip("no X-Wing on this OS (needs macOS 26)") }
    }

    func testSpecExampleKeys() throws {
        let id = try MLKEM768X25519Identity(string: Self.specIdentity)
        XCTAssertEqual(id.string, Self.specIdentity)
        XCTAssertEqual(id.seed.count, 32)
        XCTAssertEqual(id.recipient.publicKey.count, 1216)
        XCTAssertEqual(id.recipient.string, Self.specRecipient)
        XCTAssertEqual(try MLKEM768X25519Recipient(string: Self.specRecipient), id.recipient)
        XCTAssertEqual(try NativeIdentity(string: Self.specIdentity), .mlkem768x25519(id))
        XCTAssertEqual(try NativeRecipient(string: Self.specRecipient), .mlkem768x25519(id.recipient))
        XCTAssertTrue(try NativeRecipient(string: Self.specRecipient).isPostQuantum)
        XCTAssertEqual(try NativeRecipient(string: KeyTests.specRecipient), .x25519(try X25519Recipient(string: KeyTests.specRecipient)))
    }

    /// Key sizes that matter to anything printing or storing keys (recovery
    /// kit, QR codes, file names): the identity stays short, the recipient
    /// does not.
    func testEncodedLengths() throws {
        let id = try MLKEM768X25519Identity()
        XCTAssertEqual(id.string.count, 77)
        XCTAssertEqual(id.recipient.string.count, 1959)
        XCTAssertTrue(id.string.hasPrefix("AGE-SECRET-KEY-PQ-1"))
        XCTAssertEqual(id.string, id.string.uppercased())
        XCTAssertTrue(id.recipient.string.hasPrefix("age1pq1"))
        XCTAssertEqual(try MLKEM768X25519Identity(string: id.string), id)
    }

    func testRejectsWrongKeyStrings() {
        let bad = [
            Self.specRecipient.uppercased(),  // recipients are lowercase only
            Self.specIdentity.lowercased(),  // identities are uppercase only
            String(Self.specRecipient.dropLast()) + "q",  // checksum
            KeyTests.specRecipient, KeyTests.specIdentity,  // other type
            "age1pq1", "AGE-SECRET-KEY-PQ-1",
        ]
        for s in bad {
            XCTAssertThrowsError(try MLKEM768X25519Recipient(string: s), s)
            XCTAssertThrowsError(try MLKEM768X25519Identity(string: s), s)
        }
        XCTAssertThrowsError(try NativeRecipient(string: "age1pq1qqqq"))
        XCTAssertThrowsError(try NativeIdentity(string: "AGE-SECRET-KEY-PQ-1QQQQ"))
    }

    func testRoundTripAndStanzaShape() throws {
        let id = try MLKEM768X25519Identity()
        let plain = Data("quantum-resistant ink".utf8)
        let file = try AgeFile.encrypt(plain, to: [id.recipient])
        XCTAssertEqual(try AgeFile.decrypt(file, with: [id]), plain)
        let stanzas = try AgeFile.parseHeader(file).header.stanzas
        XCTAssertEqual(stanzas.count, 1)
        XCTAssertEqual(stanzas[0].type, "mlkem768x25519")
        XCTAssertEqual(stanzas[0].args.count, 1)
        XCTAssertEqual(Base64.decodeRaw(stanzas[0].args[0].utf8)?.count, 1120)
        XCTAssertEqual(stanzas[0].body.count, 32)
        // Armored, and through the type-erased wrappers.
        let armored = try AgeFile.encrypt(plain, to: [NativeRecipient.mlkem768x25519(id.recipient)], armor: true)
        XCTAssertEqual(try AgeFile.decrypt(armored, with: [NativeIdentity.mlkem768x25519(id)]), plain)
    }

    func testWrongKeyFails() throws {
        let file = try AgeFile.encrypt(Data("x".utf8), to: [try MLKEM768X25519Identity().recipient])
        XCTAssertThrowsError(try AgeFile.decrypt(file, with: [try MLKEM768X25519Identity()])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try AgeFile.decrypt(file, with: [X25519Identity()])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
    }

    func testSeveralPostQuantumRecipients() throws {
        let ids = try (0..<3).map { _ in try MLKEM768X25519Identity() }
        let file = try AgeFile.encrypt(Data("three".utf8), to: ids.map(\.recipient))
        for id in ids { XCTAssertEqual(try AgeFile.decrypt(file, with: [id]), Data("three".utf8)) }
    }

    /// Mixed post-quantum and classic recipients: refused by default, as by
    /// `age`; allowed on request (a vault in transition), and then either
    /// identity decrypts.
    func testMixedRecipients() throws {
        let pq = try MLKEM768X25519Identity(), classic = X25519Identity()
        let recipients: [any AgeRecipient] = [pq.recipient, classic.recipient]
        XCTAssertThrowsError(try AgeFile.encrypt(Data("m".utf8), to: recipients)) {
            XCTAssertEqual($0 as? AgeError, .incompatibleRecipients)
        }
        let file = try AgeFile.encrypt(Data("m".utf8), to: recipients, allowMixedPostQuantum: true)
        XCTAssertEqual(try AgeFile.decrypt(file, with: [pq]), Data("m".utf8))
        XCTAssertEqual(try AgeFile.decrypt(file, with: [classic]), Data("m".utf8))
        XCTAssertEqual(try AgeFile.parseHeader(file).header.stanzas.map(\.type), ["mlkem768x25519", "X25519"])
    }

    /// Malformed `mlkem768x25519` stanzas never crash and fail as header
    /// errors (or as "no match" when only the ciphertext is wrong).
    func testMalformedStanzasFuzz() throws {
        let id = try MLKEM768X25519Identity()
        let good = try XCTUnwrap(try id.recipient.wrap(fileKey: FileKey()).first)
        let enc = try XCTUnwrap(Base64.decodeRaw(good.args[0].utf8))
        var cases: [Stanza] = [
            Stanza(type: good.type, args: [], body: good.body),
            Stanza(type: good.type, args: good.args + ["extra"], body: good.body),
            Stanza(type: good.type, args: [Base64.encodeRaw(enc.dropLast())], body: good.body),
            Stanza(type: good.type, args: [Base64.encodeRaw(enc + [0])], body: good.body),
            Stanza(type: good.type, args: [good.args[0] + "="], body: good.body),
            Stanza(type: good.type, args: good.args, body: good.body.dropLast()),
            Stanza(type: good.type, args: good.args, body: good.body + Data([0])),
            Stanza(type: good.type, args: good.args, body: Data()),
            // X25519 part of enc is a low-order point (all-zero secret).
            Stanza(type: good.type, args: [Base64.encodeRaw(enc.prefix(1088) + Data(count: 32))], body: good.body),
        ]
        var rng = SystemRandomNumberGenerator()
        while cases.count < 9 + 200 {
            var e = [UInt8](enc), b = [UInt8](good.body)
            let flips = Int.random(in: 1...4, using: &rng)
            for _ in 0..<flips {
                if Bool.random(using: &rng) { e[Int.random(in: 0..<e.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
                else { b[Int.random(in: 0..<b.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng) }
            }
            // Two flips of the same byte by the same value cancel (about 1 case in
            // 100 000): that is the good stanza again, which rightly unwraps.
            if e == [UInt8](enc) && b == [UInt8](good.body) { continue }
            cases.append(Stanza(type: good.type, args: [Base64.encodeRaw(e)], body: Data(b)))
        }
        for (i, s) in cases.enumerated() {
            do {
                let key = try id.unwrap(stanzas: [s])
                XCTAssertNil(key, "case \(i) unwrapped")
            } catch {
                XCTAssertEqual(error as? AgeError, .invalidStanza, "case \(i)")
                XCTAssertLessThan(i, 9, "random corruption of a well-formed stanza must be 'no match', not \(error)")
            }
        }
        // The fixed malformed cases all throw.
        for s in cases.prefix(9) { XCTAssertThrowsError(try id.unwrap(stanzas: [s])) }
        // An uppercase type is another (unknown) stanza type: ignored.
        XCTAssertNil(try id.unwrap(stanzas: [Stanza(type: "MLKEM768X25519", args: good.args, body: good.body)]))
    }
}
