import Age
import ArgumentParser
import Foundation
import Sempere

/// `sempere keys derive`: the key schedule of one vault epoch key
/// (docs/design/key-hierarchy.md §2, §4; phase KH1), for checking another
/// implementation against this one. It reads and writes no vault.
struct KeysDerive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "derive",
        abstract: "Print every key derived from a vault epoch key (key-hierarchy design, KH1).",
        discussion: """
            Reads the epoch key K_e (64 hex digits, one line) from --epoch-key-file and prints the vault
            identity and its recipient, the derived keys of the design's §2.2, the epoch id, the link public
            keys, and with --vault-id the wrap plaintext (and, at epoch 1, the root fingerprint). The output
            holds secret keys: it is for test vectors, not for a real vault. The --json field names are those of
            Tests/SempereTests/Fixtures/epoch-vectors.json.
            """
    )

    @Option(name: .customLong("epoch-key-file"),
            help: ArgumentHelp("A file holding K_e as 64 lowercase hex digits ('-' for standard input).", valueName: "file"))
    var epochKeyFile: String

    @Option(name: .long, help: ArgumentHelp("The epoch number (at least 1).", valueName: "n"))
    var epoch = 1

    @Option(name: .customLong("vault-id"), help: ArgumentHelp("The vault id, for the wrap plaintext and the root.", valueName: "uuid"))
    var vaultId: String?

    @Option(name: .customLong("capture-fingerprint"),
            help: ArgumentHelp("A device fingerprint (format.md §11.1), for its capture key.", valueName: "hex"))
    var captureFingerprint: String?

    @OptionGroup var output: OutputOptions

    struct Output: Encodable {
        var epoch: Int
        var key, identitySeed, identity, recipient, tagKey, blobNameKey, listKey, markersKey, epochId, pendingKey: String
        var linkEd25519Seed, linkMLDSA65Seed, ed25519PublicKey, mldsa65PublicKey: String
        var captureKey: String?
        var wrapPlaintext: String?
        var root: String?
    }

    func run() throws {
        guard epoch >= 1 else { throw CLIError.usage("--epoch counts from 1") }
        let id: UUID?
        if let vaultId {
            guard let u = UUID(uuidString: vaultId) else { throw CLIError.usage("--vault-id is not a UUID") }
            id = u
        } else { id = nil }
        let text: String
        if epochKeyFile == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile().prefix(1024), as: UTF8.self)
        } else {
            do { text = try String(contentsOfFile: epochKeyFile, encoding: .utf8) } catch {
                throw CLIError.failure("cannot read \(epochKeyFile): \(error.localizedDescription)")
            }
        }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw CLIError.failure("\(epochKeyFile): not 64 lowercase hex digits")
        }
        let key: VaultEpochKey
        do { key = try VaultEpochKey(bytes: Self.unhex(hex)) } catch { throw CLIError.failure("\(error)") }
        let out: Output
        do {
            let identity = try key.vaultIdentity()
            let link = try LinkPublicKeys(epochKey: key)
            let signing = (key.derive(VaultEpochKey.Info.linkEd25519Seed), key.derive(VaultEpochKey.Info.linkMLDSA65Seed))
            out = Output(
                epoch: epoch, key: hex, identitySeed: Self.hex(key.identitySeed), identity: identity.string,
                recipient: identity.recipient.string, tagKey: Self.hex(key.tagKey), blobNameKey: Self.hex(key.blobNameKey),
                listKey: Self.hex(key.listKey), markersKey: Self.hex(key.markersKey), epochId: Self.hex(key.epochId),
                pendingKey: Self.hex(key.pendingKey), linkEd25519Seed: Self.hex(signing.0), linkMLDSA65Seed: Self.hex(signing.1),
                ed25519PublicKey: Self.hex(link.ed25519), mldsa65PublicKey: Self.hex(link.mldsa65),
                captureKey: captureFingerprint.map { Self.hex(key.captureKey(device: $0).bytes) },
                wrapPlaintext: try id.map { try EpochKeyWrap.plaintext(key, vaultId: $0, epoch: epoch) },
                root: epoch == 1 ? id.map { Self.hex(VaultRoot.fingerprint(vaultId: $0, epochOne: link)) } : nil)
        } catch {
            throw CLIError.failure("\(error)")
        }
        if output.json { return try output.emitJSON(out) }
        let rows: [(String, String?)] = [
            ("epoch", String(out.epoch)), ("identity", out.identity), ("recipient", out.recipient),
            ("identitySeed", out.identitySeed), ("tagKey", out.tagKey), ("blobNameKey", out.blobNameKey),
            ("listKey", out.listKey), ("markersKey", out.markersKey), ("epochId", out.epochId),
            ("pendingKey", out.pendingKey), ("captureKey", out.captureKey), ("linkEd25519Seed", out.linkEd25519Seed),
            ("linkMLDSA65Seed", out.linkMLDSA65Seed), ("ed25519PublicKey", out.ed25519PublicKey),
            ("mldsa65PublicKey", out.mldsa65PublicKey), ("root", out.root),
        ]
        for case let (name, value?) in rows { print("\(name): \(value)") }
        if let w = out.wrapPlaintext { print("wrapPlaintext:\n\(w)", terminator: "") }
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }
}
