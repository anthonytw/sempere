import Age
import ArgumentParser
import Foundation
import Sempere

// The device list from the CLI (docs/design/key-hierarchy.md §5.1, §6.1, §6.2, §6.4; phase KH2):
// `sempere device init|confirm` on a joining machine, `sempere devices list|approve|rename` on the vault's
// home. Removal and handoff (`sempere devices remove|handoff`), the takeover and kit replacement (`sempere
// recovery`) start new epochs (KH3, Epochs.swift).

/// This machine's device keys, one set per vault (design §6.1): `$XDG_STATE_HOME/sempere/devices/<vault
/// id>/device.key` (mode 0600 in a 0700 folder), or `device.key.age` when passphrase-wrapped. They never
/// leave the machine; a copied state directory makes two installs one device.
enum DeviceKeyStore {
    enum Stored {
        case none
        case plain(String)
        case wrapped(String)
    }

    /// The scrypt work factor of a passphrase-wrapped device key (it stays on the machine).
    static let workFactor = 18

    static func directory(vaultId: UUID) -> URL {
        DeviceState.defaultURL().deletingLastPathComponent().appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(vaultId.uuidString.lowercased(), isDirectory: true)
    }

    static func stored(vaultId: UUID) -> Stored {
        let dir = directory(vaultId: vaultId)
        let plain = dir.appendingPathComponent("device.key"), wrapped = dir.appendingPathComponent("device.key.age")
        if FileManager.default.fileExists(atPath: plain.path) { return .plain(plain.path) }
        if FileManager.default.fileExists(atPath: wrapped.path) { return .wrapped(wrapped.path) }
        return .none
    }

    /// Writes `device`'s key file for `vaultId`, refusing to overwrite; returns its path.
    static func save(_ device: DeviceKeys, vaultId: UUID, passphrase: String?) throws -> String {
        guard case .none = stored(vaultId: vaultId) else {
            throw CLIError.failure("this machine already has a device key for vault \(vaultId.uuidString.lowercased())")
        }
        let dir = directory(vaultId: vaultId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            throw CLIError.failure("cannot create \(dir.path): \(error.localizedDescription)")
        }
        let text = try device.fileText(created: Date())
        if let passphrase {
            guard !passphrase.isEmpty else { throw CLIError.usage("the passphrase is empty") }
            let path = dir.appendingPathComponent("device.key.age").path
            let data = try AgeFile.encrypt(Data(text.utf8), to: [ScryptRecipient(passphrase: passphrase, workFactor: workFactor)])
            try writeNewSecretFile(data, to: path)
            return path
        }
        let path = dir.appendingPathComponent("device.key").path
        try writeNewSecretFile(text, to: path)
        return path
    }

    /// The passphrase-wrapped device key of `vaultId`.
    static func unwrap(vaultId: UUID, passphrase: String) throws -> DeviceKeys {
        guard case .wrapped(let path) = stored(vaultId: vaultId) else {
            throw CLIError.cannotDecrypt("no passphrase-wrapped device key for this vault")
        }
        let data: Data
        do { data = try BoundedRead.contents(of: URL(fileURLWithPath: path), maxBytes: DeviceKeys.maxBytes) } catch {
            throw CLIError.failure("cannot read \(path): \(error)")
        }
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: [ScryptIdentity(passphrase: passphrase)]) } catch {
            throw CLIError.cannotDecrypt("wrong passphrase for the device key \(path)")
        }
        do { return try DeviceKeys.parse(String(decoding: plain, as: UTF8.self)) } catch {
            throw CLIError.failure("\(path) is not a valid device key: \(error)")
        }
    }

    /// The device key of `vaultId`, plain or (asking for the passphrase) wrapped; nil when there is none.
    static func load(vaultId: UUID, passphraseEnv: String?) throws -> DeviceKeys? {
        switch stored(vaultId: vaultId) {
        case .none: return nil
        case .plain(let path):
            do { return try DeviceKeys.parse(try String(contentsOfFile: path, encoding: .utf8)) } catch {
                throw CLIError.failure("\(path) is not a valid device key: \(error)")
            }
        case .wrapped:
            return try unwrap(vaultId: vaultId,
                              passphrase: try obtainPassphrase(envName: passphraseEnv, prompt: "Device key passphrase: "))
        }
    }
}

// MARK: - device init / confirm (the joining machine)

struct DeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Join this machine to a vault: generate its device key, then confirm the home device's reply.",
        subcommands: [DeviceInit.self, DeviceConfirm.self]
    )
}

struct DeviceInit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Generate this machine's device key for a vault and ask to join (writes joins/<id>.join.json).",
        discussion: """
            The device key and signing keys go to $XDG_STATE_HOME/sempere/devices/<vault id>/ (mode 0600; with \
            --passphrase, passphrase-wrapped) and never leave this machine. The join request goes into the \
            vault folder (sync it to where the home device sees it). Then, on the home device, type the six \
            words this prints: `sempere devices approve WORD...`. Home \
            shows six words back: type them here with `sempere device confirm`, which checks that the vault \
            this machine sees is the one home approved it in (design §6.2).
            """
    )

    @OptionGroup var access: AccessOptions

    @Option(name: .long, help: ArgumentHelp("This device's name (at most 40 characters).", valueName: "text"))
    var name = "sempere CLI"

    @Option(name: .long, help: ArgumentHelp("This device's kind: a lowercase word (cli, mac, ...).", valueName: "word"))
    var kind = "cli"

    @Flag(name: .long, help: "Passphrase-wrap the device key (asked at every use).")
    var passphrase = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard JoinRequest.isValidKind(kind) else { throw ValidationError("--kind must be a lowercase word of 1 to 32 letters") }
    }

    func run() throws {
        let url = try access.vaultURL()
        let locked = try Vault.open(at: url)
        let device: DeviceKeys
        do { device = try DeviceKeys.generate() } catch { throw CLIError.failure("\(error)") }
        // An id that collides with a listed device's is refused by home (design §3): generate again.
        guard !locked.devices.contains(where: { $0.id == device.id }) else {
            throw CLIError.failure("the new key's id collides with a listed device's: run this again")
        }
        let path = try DeviceKeyStore.save(device, vaultId: locked.vaultId, passphrase: passphrase
            ? try obtainPassphrase(envName: access.passphraseEnv, prompt: "Device key passphrase: ", confirm: true,
                                   asError: CLIError.failure) : nil)
        let request = try Vault.writeJoinRequest(at: url, device: device, name: name, kind: kind)
        let words = JoinCodes.words(request.commitment)
        if output.json {
            try output.emitJSON(Out(device: device.id, deviceKey: path, request: "\(Vault.joinsName)/\(request.fileName)",
                                    words: words))
        } else {
            output.info("This device: \(device.id) (keys in \(path))")
            output.info("Asked to join: \(Vault.joinsName)/\(request.fileName)")
            print("On the home device, type these six words: \(words.joined(separator: " "))")
            output.info("  sempere devices approve --vault VAULT \(words.joined(separator: " "))")
            output.info("Then type the six words home shows here: sempere device confirm --vault VAULT WORD...")
        }
    }

    private struct Out: Encodable {
        var device: String
        var deviceKey: String
        var request: String
        var words: [String]
    }
}

struct DeviceConfirm: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm",
        abstract: "Confirm this machine's join with the six words the home device showed.",
        discussion: """
            Checks the words against this machine's commitment, the vault's root and epoch (design §6.2 \
            step 4) and, when they match, pins the vault in this machine's trust record: from then on it \
            writes to the vault. Exit 4 when this machine is not listed yet (home has not approved it, or the \
            approval has not synced here), 1 when the words do not match.
            """
    )

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("The six words the home device showed.", valueName: "word"))
    var words: [String] = []

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard words.count == 6 else { throw ValidationError("give the six words the home device showed") }
    }

    func run() throws {
        var vault = try access.openVault(.required)
        do { try vault.confirmJoin(words: words) } catch VaultError.replyMismatch {
            throw CLIError.failure("\(VaultError.replyMismatch)")
        }
        if output.json {
            try output.emitJSON(Out(device: vault.deviceEntry?.id ?? "", root: Hex.encode(vault.root)))
        } else {
            output.info("Confirmed: this machine (\(vault.deviceEntry?.id ?? "?")) is a device of the vault and writes to it.")
        }
    }

    private struct Out: Encodable { var device: String; var root: String }
}

// MARK: - devices list / approve / rename (home)

struct DevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List the vault's devices; approve, rename, remove them and hand the home role over (on the home device); take over with the recovery kit.",
        subcommands: [DevicesList.self, DevicesApprove.self, DevicesRename.self, DevicesRemove.self, DevicesHandoff.self,
                      RecoveryTakeover.self, DevicesStatus.self, DevicesHistory.self]
    )
}

struct DevicesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the devices, the recovery kit, and the join requests waiting for the home device.",
        discussion: "Works without a key (names as stored, unchecked); with one, vault.json is checked first."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let m = vault.manifest
        let this = vault.deviceFingerprint
        let devices = m.devices.map { e -> Row in
            Row(device: DeviceOutput(e, in: m), thisDevice: e.fingerprint == this,
                lastSynced: e.id.flatMap { vault.lastSynced(device: $0) }.map { RFC3339.string($0) })
        }
        let requests = vault.joinRequests().map { f in
            Request(file: "\(Vault.joinsName)/\(f.name)", id: f.request.map { String(Hex.encode($0.fingerprint).prefix(8)) },
                    name: f.request.map { DeviceName.display($0.name) }, kind: f.request?.kind, created: f.request?.created,
                    problem: f.problem ?? (f.request.map { $0.vaultId == vault.vaultId } == false ? "another vault's" : nil))
        }
        let recovery = m.recoveryEntry.map { Recovery(added: $0.added, passphraseCopy: !vault.passphraseCopyNames().isEmpty) }
        if output.json {
            try output.emitJSON(Out(devices: devices, recovery: recovery, joinRequests: requests, list: ListStatusOutput(vault),
                                    thisDeviceIsHome: vault.deviceFingerprint == m.home, unlisted: vault.unlistedNotice,
                                    waiting: vault.waitingNotice))
            return
        }
        if let n = vault.unlistedNotice { print("Not on the newest device list: \(n)") }
        if let n = vault.waitingNotice { print("Waiting for a device change to be verified: \(n)") }
        var rows: [[String]] = [["ID", "KIND", "NAME", "ADDED", "BY", "SYNCED", ""]]
        for d in devices {
            var notes: [String] = []
            if d.device.home { notes.append("manages devices") }
            if d.thisDevice { notes.append("this device") }
            let synced = d.lastSynced.flatMap { RFC3339.parse($0) }.map { EpochTargets.ago($0) } ?? (vault.canRead ? "unknown" : "")
            rows.append([d.device.id, d.device.kind, d.device.name, d.device.added, d.device.addedBy, synced,
                         notes.joined(separator: ", ")])
        }
        print(Format.table(rows))
        if let recovery {
            print("Recovery kit: created \(recovery.added)" + (recovery.passphraseCopy ? "; passphrase copy in keys/" : ""))
        }
        for r in requests {
            print("Join request \(r.file): " + (r.problem.map { "unreadable (\($0))" }
                ?? "\(r.name ?? "?") (\(r.kind ?? "?"), \(r.id ?? "?")); approve with its six words, typed"))
        }
        if !vault.isLocked { print("Device list: \(ListStatusOutput(vault).text)") }
    }

    struct Row: Encodable {
        var device: DeviceOutput
        var thisDevice: Bool
        /// When the device last completed a two-way sync (its own summaries file, design §5.5); needs the key.
        var lastSynced: String?
    }

    struct Request: Encodable {
        var file: String
        var id: String?
        var name: String?
        var kind: String?
        var created: String?
        var problem: String?
    }

    struct Recovery: Encodable {
        var added: String
        var passphraseCopy: Bool
    }

    private struct Out: Encodable {
        var devices: [Row]
        var recovery: Recovery?
        var joinRequests: [Request]
        var list: ListStatusOutput
        var thisDeviceIsHome: Bool
        /// Set when this machine is not on the newest device list it verified (design §5.5): why.
        var unlisted: String?
        /// Set when a later device list waits to be verified here (design §4.3): why, and where it was seen.
        var waiting: String?
    }
}

struct DevicesApprove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Approve a join request on the home device: type the six words the new device shows.",
        discussion: """
            Finds the request in joins/ whose commitment the words give (typing, not comparing, so a near \
            match is not waved through), adds the device with a wrap of the vault key and this device's \
            signature, and deletes the request. No file is re-encrypted. Prints six words: type them on \
            the new device (`sempere device confirm`). Only the home device approves (exit 1 elsewhere).
            """
    )

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("The six words the new device shows.", valueName: "word"))
    var words: [String] = []

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard words.count == 6 else { throw ValidationError("give the six words the new device shows") }
    }

    func run() throws {
        var vault = try access.openVault(.required)
        guard vault.isHome else {
            let home = vault.manifest.homeEntry.map { "\(DeviceName.display($0.name)) (\($0.id ?? "?"))" } ?? "another device"
            throw CLIError.failure("only the home device approves devices: \(home) manages this vault's devices")
        }
        guard let request = vault.joinRequest(matching: words) else {
            throw CLIError.failure("no join request in \(Vault.joinsName)/ matches those words: check them, or the "
                + "request was replaced on the way (it is refused)")
        }
        let reply = try vault.approveDevice(request)
        let id = String(Hex.encode(request.fingerprint).prefix(8))
        if output.json {
            try output.emitJSON(Out(device: id, name: DeviceName.display(request.name), reply: reply))
        } else {
            output.info("Approved \(DeviceName.display(request.name)) (\(id)).")
            print("On the new device, type these six words: \(reply.joined(separator: " "))")
        }
    }

    private struct Out: Encodable { var device: String; var name: String; var reply: [String] }
}

struct DevicesRename: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a device (on the home device).",
        discussion: "Names are stored unencrypted in vault.json, covered by its tag and the home device's signature."
    )

    @OptionGroup var access: AccessOptions

    @Argument(help: ArgumentHelp("The device's id (or 4+ leading hex digits of it).", valueName: "id"))
    var id: String

    @Argument(help: ArgumentHelp("The new name (at most 40 characters).", valueName: "name"))
    var name: String

    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required)
        guard vault.isHome else { throw CLIError.failure("only the home device renames devices") }
        let target = try vault.resolveDevice(id)
        try vault.renameDevice(id: target.id ?? id, to: name)
        let renamed = try vault.resolveDevice(target.id ?? id)
        if output.json {
            try output.emitJSON(DeviceOutput(renamed, in: vault.manifest))
        } else {
            output.info("Renamed \(renamed.id ?? id) to \(DeviceName.display(renamed.name)).")
        }
    }
}
