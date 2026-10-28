import Foundation
import XCTest

@testable import Age

/// RFC 7914 §8–§12 test vectors.
final class ScryptTests: XCTestCase {
    func hex(_ s: String) -> [UInt8] {
        let digits = Array(s.filter { $0.isHexDigit })
        var out = [UInt8]()
        var i = 0
        while i + 1 < digits.count {
            let pair: String = String(digits[i...(i + 1)])
            out.append(UInt8(pair, radix: 16)!)
            i += 2
        }
        return out
    }

    func testSalsa208Core() {
        let input = hex("""
            7e 87 9a 21 4f 3e c9 86 7c a9 40 e6 41 71 8f 26 ba ee 55 5b 8c 61 c1 b5 0d f8 46 11 6d cd 3b 1d
            ee 24 f3 19 df 9b 3d 85 14 12 1e 4b 5a c5 aa 32 76 02 1d 29 09 c7 48 29 ed eb c6 8d b8 b8 c2 5e
            """)
        let output = hex("""
            a4 1f 85 9c 66 08 cc 99 3b 81 ca cb 02 0c ef 05 04 4b 21 81 a2 fd 33 7d fd 7b 1c 63 96 68 2f 29
            b4 39 31 68 e3 c9 e6 bc fe 6b c5 b7 a0 6d 96 ba e4 24 cc 10 2c 91 74 5c 24 ad 67 3d c7 61 8f 81
            """)
        XCTAssertEqual(Scrypt.salsa208(bytes: input), output)
    }

    static let blockMixInput = """
        f7 ce 0b 65 3d 2d 72 a4 10 8c f5 ab e9 12 ff dd 77 76 16 db bb 27 a7 0e 82 04 f3 ae 2d 0f 6f ad
        89 f6 8f 48 11 d1 e8 7b cc 3b d7 40 0a 9f fd 29 09 4f 01 84 63 95 74 f3 9a e5 a1 31 52 17 bc d7
        89 49 91 44 72 13 bb 22 6c 25 b5 4d a8 63 70 fb cd 98 43 80 37 46 66 bb 8f fc b5 bf 40 c2 54 b0
        67 d2 7c 51 ce 4a d5 fe d8 29 c9 0b 50 5a 57 1b 7f 4d 1c ad 6a 52 3c da 77 0e 67 bc ea af 7e 89
        """

    func testBlockMix() {
        let output = hex("""
            a4 1f 85 9c 66 08 cc 99 3b 81 ca cb 02 0c ef 05 04 4b 21 81 a2 fd 33 7d fd 7b 1c 63 96 68 2f 29
            b4 39 31 68 e3 c9 e6 bc fe 6b c5 b7 a0 6d 96 ba e4 24 cc 10 2c 91 74 5c 24 ad 67 3d c7 61 8f 81
            20 ed c9 75 32 38 81 a8 05 40 f6 4c 16 2d cd 3c 21 07 7c fe 5f 8d 5f e2 b1 a4 16 8f 95 36 78 b7
            7d 3b 3d 80 3b 60 e4 ab 92 09 96 e5 9b 4d 53 b6 5d 2a 22 58 77 d5 ed f5 84 2c b9 f1 4e ef e4 25
            """)
        XCTAssertEqual(Scrypt.blockMix(bytes: hex(Self.blockMixInput), r: 1), output)
    }

    func testROMix() {
        let output = hex("""
            79 cc c1 93 62 9d eb ca 04 7f 0b 70 60 4b f6 b6 2c e3 dd 4a 96 26 e3 55 fa fc 61 98 e6 ea 2b 46
            d5 84 13 67 3b 99 b0 29 d6 65 c3 57 60 1f b4 26 a0 b2 f4 bb a2 00 ee 9f 0a 43 d1 9b 57 1a 9c 71
            ef 11 42 e6 5d 5a 26 6f dd ca 83 2c e5 9f aa 7c ac 0b 9c f1 be 2b ff ca 30 0d 01 ee 38 76 19 c4
            ae 12 fd 44 38 f2 03 a0 e4 e1 c4 7e c3 14 86 1f 4e 90 87 cb 33 39 6a 68 73 e8 f9 d2 53 9a 4b 8e
            """)
        XCTAssertEqual(Scrypt.roMix(bytes: hex(Self.blockMixInput), n: 16, r: 1), output)
    }

    func testPBKDF2() {
        XCTAssertEqual(
            Scrypt.pbkdf2SHA256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, keyLength: 64),
            hex("""
                55 ac 04 6e 56 e3 08 9f ec 16 91 c2 25 44 b6 05 f9 41 85 21 6d de 04 65 e6 8b 9d 57 c2 0d ac bc
                49 ca 9c cc f1 79 b6 45 99 16 64 b3 9d 77 ef 31 7c 71 b8 45 b1 e3 0b d5 09 11 20 41 d3 a1 97 83
                """))
        XCTAssertEqual(
            Scrypt.pbkdf2SHA256(password: Array("Password".utf8), salt: Array("NaCl".utf8), iterations: 80000, keyLength: 64),
            hex("""
                4d dc d8 f6 0b 98 be 21 83 0c ee 5e f2 27 01 f9 64 1a 44 18 d0 4c 04 14 ae ff 08 87 6b 34 ab 56
                a1 d4 25 a1 22 58 33 54 9a db 84 1b 51 c9 b3 17 6a 27 2b de bb a1 d0 78 47 8f 62 b3 97 f3 3c 8d
                """))
    }

    func testScryptN16() {
        XCTAssertEqual(
            Scrypt.derive(password: [], salt: [], n: 16, r: 1, p: 1, keyLength: 64),
            hex("""
                77 d6 57 62 38 65 7b 20 3b 19 ca 42 c1 8a 04 97 f1 6b 48 44 e3 07 4a e8 df df fa 3f ed e2 14 42
                fc d0 06 9d ed 09 48 f8 32 6a 75 3a 0f c8 1f 17 e8 d3 e0 fb 2e 0d 36 28 cf 35 e2 0c 38 d1 89 06
                """))
    }

    func testScryptN1024() {
        XCTAssertEqual(
            Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1024, r: 8, p: 16, keyLength: 64),
            hex("""
                fd ba be 1c 9d 34 72 00 78 56 e7 19 0d 01 e9 fe 7c 6a d7 cb c8 23 78 30 e7 73 76 63 4b 37 31 62
                2e af 30 d9 2e 22 a3 88 6f f1 09 27 9d 98 30 da c7 27 af b9 4a 83 ee 6d 83 60 cb df a2 cc 06 40
                """))
    }

    func testScryptN16384() {
        XCTAssertEqual(
            Scrypt.derive(
                password: Array("pleaseletmein".utf8), salt: Array("SodiumChloride".utf8), n: 16384, r: 8, p: 1,
                keyLength: 64),
            hex("""
                70 23 bd cb 3a fd 73 48 46 1c 06 cd 81 fd 38 eb fd a8 fb ba 90 4f 8e 3e a9 b5 43 f6 54 5d a1 f2
                d5 43 29 55 61 3f 0f cf 62 d4 97 05 24 2a 9a f9 e6 1e 85 dc 0d 65 1e 40 df cf 01 7b 45 57 58 87
                """))
    }

    func testRejectsBadParameters() {
        XCTAssertNil(Scrypt.derive(password: [], salt: [], n: 15, r: 1, p: 1, keyLength: 32))
        XCTAssertNil(Scrypt.derive(password: [], salt: [], n: 1, r: 1, p: 1, keyLength: 32))
        XCTAssertNil(Scrypt.derive(password: [], salt: [], n: 16, r: 0, p: 1, keyLength: 32))
    }

    /// Times one age-default derivation (log2 N = 18, r = 8) and requires it
    /// to stay under 10 s. Optimized builds only (about 20 s unoptimized):
    /// `swift test -c release -Xswiftc -enable-testing --filter testWorkFactor18Timing`.
    func testWorkFactor18Timing() throws {
        #if DEBUG
            let optimized = false
        #else
            let optimized = true
        #endif
        try XCTSkipUnless(optimized, "timing is only meaningful in an optimized build")
        let start = Date()
        let key = Scrypt.derive(password: Array("timing".utf8), salt: Array(repeating: 1, count: 44), n: 1 << 18, r: 8, p: 1, keyLength: 32)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(key?.count, 32)
        print(String(format: "scrypt work factor 18: %.2f s", elapsed))
        XCTAssertLessThan(elapsed, 10)
    }
}
