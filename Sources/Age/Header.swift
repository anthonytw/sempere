import Crypto
import Foundation

/// Header encoding and strict parsing (age spec "Header", mirroring
/// `filippo.io/age/internal/format`).
enum HeaderCodec {
    static let intro = Array("age-encryption.org/v1\n".utf8)
    static let versionPrefix = Array("age-encryption.org/".utf8)
    static let columnsPerLine = 64
    static let bytesPerLine = 48
    static let maxHeaderBytes = 2 << 20
    static let maxStanzas = 1024

    // MARK: Encoding

    /// Wraps `data` as unpadded base64 at 64 columns. The output always ends
    /// with a line shorter than 64 columns (possibly empty), and has no
    /// trailing newline.
    static func wrappedRawBase64(_ data: Data) -> [UInt8] {
        let enc = Array(Base64.encodeRaw(data).utf8)
        var out = [UInt8]()
        var i = 0
        while i + columnsPerLine <= enc.count {
            out += enc[i..<i + columnsPerLine]
            out.append(0x0A)
            i += columnsPerLine
        }
        out += enc[i...]
        return out
    }

    static func encodeStanza(_ s: Stanza) throws -> [UInt8] {
        guard isValidStanzaString(s.type), s.args.allSatisfy(isValidStanzaString) else {
            throw AgeError.invalidStanzaEncoding
        }
        var out = Array("->".utf8)
        for a in [s.type] + s.args { out += [0x20] + Array(a.utf8) }
        out.append(0x0A)
        out += wrappedRawBase64(s.body)
        out.append(0x0A)
        return out
    }

    /// The header bytes covered by the MAC: intro, stanzas, and `---`.
    static func encodeWithoutMAC(_ stanzas: [Stanza]) throws -> [UInt8] {
        guard !stanzas.isEmpty else { throw AgeError.noRecipients }
        var out = intro
        for s in stanzas { out += try encodeStanza(s) }
        out += Array("---".utf8)
        return out
    }

    static func mac(fileKey: FileKey, macInput: some DataProtocol) -> Data {
        let key = hkdfSHA256(ikm: fileKey.bytes, salt: Data(), info: "header")
        return Data(HMAC<SHA256>.authenticationCode(for: Data(macInput), using: key))
    }

    static func verifyMAC(fileKey: FileKey, header: Header) -> Bool {
        let key = hkdfSHA256(ikm: fileKey.bytes, salt: Data(), info: "header")
        return HMAC<SHA256>.isValidAuthenticationCode(header.mac, authenticating: header.macInput, using: key)
    }

    // MARK: Parsing

    /// Parses the header at the start of `data`. Returns the header and the
    /// offset (relative to `data.startIndex`) where the payload begins.
    static func parse(_ data: Data) throws -> (Header, Int) {
        let bytes = [UInt8](data.prefix(maxHeaderBytes))
        var pos = 0

        // Reads one LF-terminated line; returns it without the LF, or nil at
        // EOF before an LF (every header line must end in LF).
        func readLine() -> ArraySlice<UInt8>? {
            // `bytes` is already capped at maxHeaderBytes, so a header that
            // is too long simply runs out of input here.
            guard let nl = bytes[pos...].firstIndex(of: 0x0A) else { return nil }
            let line = bytes[pos..<nl]
            pos = nl + 1
            return line
        }

        guard let first = readLine() else { throw AgeError.headerParse }
        if Array(first) + [0x0A] != intro {
            // A CRLF-mangled file (e.g. PowerShell redirection) is a broken
            // v1 file, not a different version.
            if Array(first) == intro.dropLast() + [0x0D] { throw AgeError.headerParse }
            // Only a well-formed `version = 1*VCHAR` token counts as a
            // different version.
            let version = first.dropFirst(versionPrefix.count)
            if first.starts(with: versionPrefix), !version.isEmpty, version.allSatisfy({ $0 >= 33 && $0 <= 126 }) {
                throw AgeError.unsupportedVersion
            }
            throw AgeError.headerParse
        }

        func readStanza() throws -> Stanza {
            guard let line = readLine(), line.starts(with: "->".utf8) else { throw AgeError.headerParse }
            let (prefix, args) = splitArgs(line)
            guard prefix.elementsEqual("->".utf8), let args, !args.isEmpty else { throw AgeError.headerParse }
            var body = [UInt8]()
            while true {
                guard let bodyLine = readLine(), let decoded = Base64.decodeRaw(bodyLine) else {
                    throw AgeError.headerParse
                }
                guard decoded.count <= bytesPerLine else { throw AgeError.headerParse }
                body += decoded
                if decoded.count < bytesPerLine {
                    return Stanza(type: args[0], args: Array(args.dropFirst()), body: Data(body))
                }
            }
        }

        var stanzas = [Stanza]()
        while true {
            guard pos + 3 <= bytes.count else { throw AgeError.headerParse }
            if bytes[pos..<pos + 3].elementsEqual("---".utf8) {
                let macStart = pos
                guard let line = readLine() else { throw AgeError.headerParse }
                let (prefix, args) = splitArgs(line)
                guard prefix.elementsEqual("---".utf8), let args, args.count == 1,
                    let mac = Base64.decodeRaw(args[0].utf8), mac.count == 32
                else { throw AgeError.headerParse }
                guard !stanzas.isEmpty else { throw AgeError.headerParse }
                let header = Header(stanzas: stanzas, mac: Data(mac), macInput: Data(bytes[0..<macStart + 3]))
                return (header, pos)
            }
            guard stanzas.count < maxStanzas else { throw AgeError.headerParse }
            stanzas.append(try readStanza())
        }
    }

    /// Splits `prefix arg arg...` on single spaces. `args` is nil when there
    /// is no space, or when any argument is empty or contains bytes outside
    /// VCHAR (so doubled, leading or trailing spaces are rejected). There is
    /// no argument-count cap: the 2 MiB header cap bounds the input.
    static func splitArgs(_ line: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, [String]?) {
        guard let sp = line.firstIndex(of: 0x20) else { return (line, nil) }
        let prefix = line[line.startIndex..<sp]
        var args = [String]()
        for part in line[(sp + 1)...].split(separator: 0x20, omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
                return (line, nil)
            }
            args.append(String(decoding: part, as: UTF8.self))
        }
        return (prefix, args)
    }
}
