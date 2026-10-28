import Age
import Crypto
import Foundation

// The device list of a single-epoch vault (docs/design/key-hierarchy.md §5.1, §6.2; format.md §15.3,
// §15.12): join requests, approval and renaming by the home device, and the recovery key's passphrase
// copy (§15.11). Removals, handoffs and takeovers start new epochs (KH3, KH4).

/// A join request found in `joins/`, or why one could not be read.
public struct JoinRequestFile: Sendable {
    /// The file name under `joins/`.
    public var name: String
    /// The request; nil when the file does not parse (untrusted input, format.md §9).
    public var request: JoinRequest?
    /// Why it does not parse.
    public var problem: String?
}

extension Vault {
    // MARK: - Join requests (design §6.2 step 1)

    /// Writes this device's join request to `joins/<id>.join.json` in the vault at `url` (create-only,
    /// so a request is never replaced), and returns it. No key is needed: the vault may be locked.
    ///
    /// - Throws: `alreadyExists` when a request of this device is there already,
    ///   `deviceAlreadyListed` when the device is listed.
    @discardableResult
    public static func writeJoinRequest(at url: URL, device: DeviceKeys, name: String, kind: String,
                                        created: Date = Date()) throws -> JoinRequest {
        let locked = try open(at: url)
        guard JoinRequest.isValidKind(kind) else { throw VaultError.joinRequestRefused("kind \(kind)") }
        guard !locked.manifest.keys.contains(where: { $0.key == device.key }) else {
            throw VaultError.deviceAlreadyListed(device.id)
        }
        let request = device.joinRequest(vaultId: locked.vaultId, name: name, kind: kind, created: created)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileIO.createDirectory(locked.joinsURL)
        try FileIO.writeAtomically(try enc.encode(request) + Data("\n".utf8),
                                   to: locked.joinsURL.appendingPathComponent(request.fileName), replacing: false)
        return request
    }

    /// The join requests in `joins/`, sorted by name; files that do not parse are listed with why.
    public func joinRequests() -> [JoinRequestFile] {
        let names = (try? FileIO.entries(joinsURL, directories: false) { $0.hasSuffix(".join.json") }) ?? []
        return names.map { name in
            do {
                let data = try BoundedRead.contents(of: joinsURL.appendingPathComponent(name), maxBytes: JoinRequest.maxBytes)
                return JoinRequestFile(name: name, request: try JoinRequest.parse(data))
            } catch {
                return JoinRequestFile(name: name, request: nil, problem: "\(error)")
            }
        }
    }

    /// The request whose six words (design §6.2 step 2) are `words`, typed on home; nil when none is.
    /// Typing, not comparing, so a near match is not waved through.
    public func joinRequest(matching words: [String]) -> JoinRequest? {
        joinRequests().compactMap(\.request).first { $0.vaultId == vaultId && JoinCodes.matches(words, $0.commitment) }
    }

    /// Whether `name` is a join request's file name (`<8 hex>.join.json`, format.md §15.12).
    public static func isJoinRequestName(_ name: String) -> Bool {
        guard name.hasSuffix(".join.json") else { return false }
        let id = name.dropLast(".join.json".count)
        return id.count == 8 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Declines join requests (design §6.2; build 12: "there's no way to decline a request"): deletes the named files
    /// from `joins/` (also unreadable ones, which can be named only by file). The next sync deletes them on the targets
    /// too (a request one side deleted since both held it), and the device that asked is listed nowhere. Only the
    /// home device declines, as only it approves.
    ///
    /// - Parameter names: request file names (`<id>.join.json`); names of nothing in `joins/` are skipped.
    /// - Returns: the names deleted.
    /// - Throws: `notHome`, what `requireWritable` throws, `io`.
    @discardableResult
    public func declineJoinRequests(_ names: [String]) throws -> [String] {
        try requireWritable()
        guard isHome else { throw VaultError.notHome("only the home device declines join requests (it manages devices)") }
        var removed: [String] = []
        for name in Set(names).sorted() where Self.isJoinRequestName(name) {
            let url = joinsURL.appendingPathComponent(name)
            guard FileIO.exists(url) else { continue }
            // Gone in between (a sync took it): declined all the same (review of #124, note 8).
            do { try FileIO.remove(url) } catch { if FileIO.exists(url) { throw error } }
            removed.append(name)
        }
        return removed
    }

    // MARK: - Home's list changes (design §5.1)

    /// Approves a join request (design §5.1, §6.2 step 3): appends the device's entry with a wrap of the
    /// current key and home's `addSig`, re-tags and re-signs `vault.json`, and deletes the request. Only
    /// home does it, with its signing keys. No file is touched and the epoch does not change.
    ///
    /// - Returns: the six words of the reply (design §6.2 step 3) the new device types to confirm.
    /// - Throws: `notHome`, what `requireWritable` throws, `joinRequestRefused` (another vault, a key
    ///   that is not post-quantum, a bad kind, an id that is a device's the vault lists or listed, too many
    ///   additions),
    ///   `deviceAlreadyListed`, `manifestCorrupt` when `vault.json` changed since it was opened.
    @discardableResult
    public mutating func approveDevice(_ request: JoinRequest, added: Date = Date()) throws -> [String] {
        try requireWritable()
        let key = try requireSecret()
        guard isHome, let signing, let home = deviceEntry else {
            throw VaultError.notHome("only the home device approves devices (it manages devices)")
        }
        guard request.vaultId == vaultId else { throw VaultError.joinRequestRefused("the request names another vault") }
        guard let recipient = try? NativeRecipient(string: request.key), recipient.isPostQuantum else {
            throw VaultError.joinRequestRefused("not a post-quantum key")
        }
        guard JoinRequest.isValidKind(request.kind) else { throw VaultError.joinRequestRefused("kind \(request.kind)") }
        let fingerprint = request.fingerprint
        let id = String(Hex.encode(fingerprint).prefix(8))
        guard !manifest.keys.contains(where: { $0.key == request.key || $0.fingerprint == fingerprint }) else {
            throw VaultError.deviceAlreadyListed(id)
        }
        // Ids are for names only, but no two devices of the vault ever share one (design §3, K11; `DeviceIds`):
        // not a listed device's, nor one the chain ever listed (a takeover may re-admit it). The device
        // generates another key.
        guard DeviceIds.collision(fingerprint, in: DeviceIds.everListed(manifest: manifest, chain: verifiedChain)) == nil else {
            throw VaultError.joinRequestRefused("its id \(id) is a device's this vault lists or listed: generate another key")
        }
        guard manifest.keys.count < EpochChain.maxListSize,
              manifest.devices.filter({ $0.addedEpoch == manifest.epoch && $0.fingerprint != manifest.home }).count
                < EpochChain.maxAdditions else {
            throw VaultError.joinRequestRefused("this epoch has as many additions as it may hold")
        }
        var m = try requireUnchangedOnDisk()
        let claim = EntryClaim(key: request.key, sign: request.sign, kind: request.kind, added: RFC3339.string(added),
                               addedEpoch: m.epoch, addedBy: home.id ?? "")
        let entry = EpochKeyEntry(role: .device, key: request.key, id: id, sign: request.sign, kind: request.kind,
                                  added: claim.added, addedEpoch: claim.addedEpoch, addedBy: claim.addedBy,
                                  addSig: try signing.sign(AuthorMessage.entry(vaultId: vaultId, claim)),
                                  name: DeviceName.clean(request.name),
                                  wrap: try EpochKeyWrap.seal(key, vaultId: vaultId, epoch: m.epoch, to: recipient))
        let at = m.keys.firstIndex { $0.role == .recovery } ?? m.keys.endIndex
        m.keys.insert(entry, at: at)
        try Self.seal(&m, key: key, signing: signing, author: home.id ?? "")
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true)
        listStatus = .verified(.added)
        try rememberList()
        try? FileIO.remove(joinsURL.appendingPathComponent(request.fileName))
        return JoinCodes.words(JoinCodes.reply(vaultId: vaultId, commitment: request.commitment, root: manifest.root,
                                               frontier: manifest.epochId))
    }

    /// Renames a listed device (design §5.1): the one field home may change in place. Only home does
    /// it, with its signing keys.
    ///
    /// - Parameter id: the device's id (8 hex digits), or a unique prefix of 4 or more.
    /// - Throws: `notHome`, `deviceNotFound`, what `requireWritable` throws, `manifestCorrupt` when
    ///   `vault.json` changed since it was opened.
    public mutating func renameDevice(id: String, to name: String) throws {
        try requireWritable()
        let key = try requireSecret()
        guard isHome, let signing, let home = deviceEntry else {
            throw VaultError.notHome("only the home device renames devices (it manages devices)")
        }
        let target = try resolveDevice(id)
        var m = try requireUnchangedOnDisk()
        guard let i = m.keys.firstIndex(where: { $0.role == .device && $0.fingerprint == target.fingerprint }) else {
            throw VaultError.deviceNotFound(id)
        }
        let clean = DeviceName.clean(name)
        guard m.keys[i].name != clean else { return }
        m.keys[i].name = clean
        try Self.seal(&m, key: key, signing: signing, author: home.id ?? "")
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true)
        listStatus = .verified(.renamed)
        try rememberList()
    }

    /// The listed device whose id is `query`, or whose id alone starts with it (4 or more hex digits).
    public func resolveDevice(_ query: String) throws -> EpochKeyEntry {
        let q = query.lowercased()
        if let exact = manifest.devices.first(where: { $0.id == q }) { return exact }
        let matches = q.count >= 4 ? manifest.devices.filter { ($0.id ?? "").hasPrefix(q) } : []
        guard matches.count == 1, let only = matches.first else { throw VaultError.deviceNotFound(query) }
        return only
    }

    // MARK: - The recovery key's passphrase copy (design §8.2, format.md §15.11)

    /// The passphrase copies in `keys/` (normally one).
    public func passphraseCopyNames() -> [String] {
        (try? FileIO.entries(keysURL, directories: false) { $0.hasPrefix("recovery-") && $0.hasSuffix(".key.age") }) ?? []
    }

    /// The recovery identity and the root, from the vault's passphrase copy.
    ///
    /// - Throws: `passphraseCopyMissing`, `emptyPassphrase`, `wrongPassphrase`, `workFactorTooHigh`,
    ///   `passphraseCopyMalformed` (also for a copy of another vault).
    public func openPassphraseCopy(passphrase: String) throws -> RecoveryPassphraseCopy {
        guard !passphrase.isEmpty else { throw VaultError.emptyPassphrase }
        let names = passphraseCopyNames()
        guard !names.isEmpty else { throw VaultError.passphraseCopyMissing }
        var last: Error = VaultError.wrongPassphrase
        for name in names {
            do {
                let data = try BoundedRead.contents(of: keysURL.appendingPathComponent(name),
                                                    maxBytes: RecoveryPassphraseCopy.maxBytes)
                let copy = try Self.openPassphraseCopy(data, passphrase: passphrase)
                guard copy.vaultId == vaultId else { throw VaultError.passphraseCopyMalformed("it names another vault") }
                return copy
            } catch {
                last = error
            }
        }
        throw last
    }

    /// Opens a passphrase copy's bytes (format.md §15.11): one scrypt stanza, work factor at most 20.
    public static func openPassphraseCopy(_ data: Data, passphrase: String) throws -> RecoveryPassphraseCopy {
        guard data.count <= RecoveryPassphraseCopy.maxBytes else { throw VaultError.fileTooLarge("passphrase copy",
                                                                                                limit: RecoveryPassphraseCopy.maxBytes) }
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: [ScryptIdentity(passphrase: passphrase)]) } catch AgeError.noMatchingIdentity {
            throw VaultError.wrongPassphrase
        } catch AgeError.scryptWorkFactor {
            throw VaultError.workFactorTooHigh
        } catch {
            throw VaultError.passphraseCopyMalformed("\(error)")
        }
        do { return try RecoveryPassphraseCopy.parse(plain) } catch {
            throw VaultError.passphraseCopyMalformed("\(error)")
        }
    }
}
