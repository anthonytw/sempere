import Age
import Foundation
import Sempere
import SempereRender

/// A key the open vault is encrypted to, as the key window lists it.
struct DeviceKey: Identifiable, Equatable, Sendable {
    /// The `age1pq1…` recipient.
    var recipient: String
    var label: String
    var added: Date
    var isPostQuantum: Bool
    /// The key this window unlocked the vault with: it cannot be removed here.
    var isInUse: Bool
    /// The vault it belongs to: a removal checks it is still the open one.
    var vault: UUID

    var id: String { recipient }

    /// `age1pq1abcdefg…` (1959 characters in full) with its SHA-256 fingerprint,
    /// as printed on the recovery kit.
    var summary: String { Self.abbreviated(recipient) }

    static func abbreviated(_ recipient: String) -> String {
        recipient.count > 40 ? "\(recipient.prefix(14))…  SHA-256 \(PaperKey.fingerprint(recipient))" : recipient
    }
}

/// Key management of the open vault (the Mac key window): list the recipients,
/// add or remove a device key, print the recovery kit. Adding and removing go
/// through `Vault.addRecipient` / `removeRecipient` (docs/post-quantum.md,
/// format.md §3.3), which re-encrypt every note file.
///
/// Open editors hold a copy of the vault with the old secret (`removeRecipient`
/// rotates it), so all of them are saved and closed first, the vault is
/// replaced, and `keyEpoch` tells the views to open their notes again. Edits
/// from the note list wait on the edit gate meanwhile.
extension AppModel {
    enum KeyError: Error, Equatable, CustomStringConvertible {
        case notUnlocked
        case notPostQuantum
        case alreadyListed
        case notListed
        case lastKey
        case inUse
        /// Some files could not be re-encrypted (yet); the change stays pending.
        case incomplete(Int)
        case noIdentity
        /// Another vault was opened while the key window's sheet or dialog was up.
        case vaultChanged
        /// Replace: the key this window unlocked with (it would lose the vault).
        case replaceInUse
        /// Repair: the key this device unlocked with must be kept.
        case keepHeldKey
        /// Repair: this device's key is in neither the list nor its record.
        case heldKeyMissing
        /// Repair: the list checks, or no repair is possible from here.
        case nothingToRepair

        var description: String {
            switch self {
            case .notUnlocked: return String(localized: "Unlock the vault first.")
            case .notPostQuantum: return String(localized: "That is not a post-quantum key. It must start with age1pq1…; create a new key on the other device.")
            case .alreadyListed: return String(localized: "The vault is already encrypted to that key.")
            case .notListed: return String(localized: "That key is not one of the vault's keys.")
            case .lastKey: return String(localized: "The vault needs at least one key. Add another before removing this one.")
            case .inUse: return String(localized: "That is the key this vault was unlocked with. Unlock with another key to remove it.")
            case .incomplete(let n):
                return String(localized: "\(n) files could not be re-encrypted. The change is saved and finishes the next time you try again.")
            case .noIdentity: return String(localized: "This window does not hold a key of the vault, so it cannot print a recovery kit.")
            case .vaultChanged: return String(localized: "Another vault was opened meanwhile. Nothing was changed.")
            case .replaceInUse:
                return String(localized: "That is the key this vault was unlocked with. To replace it, add a new key for this device, unlock with it, then remove this one.")
            case .keepHeldKey:
                return String(localized: "Keep the key this device unlocked the vault with: without it, this device could not open the vault after the repair.")
            case .heldKeyMissing:
                return String(localized: "The key this device unlocked with is not in the list, so a repair from here could lock this device out. Repair it from another device, or with `sempere vault recipients repair --keep`.")
            case .nothingToRepair: return String(localized: "The vault's device list checks, or it cannot be repaired from this device. Nothing was changed.")
            }
        }
    }

    /// The recipients of the open vault, in the manifest's order.
    var deviceKeys: [DeviceKey] {
        guard let vault else { return [] }
        let held = heldRecipients
        return vault.recipients.map { r in
            DeviceKey(recipient: r.key, label: r.label, added: r.added,
                      isPostQuantum: (try? NativeRecipient(string: r.key))?.isPostQuantum == true,
                      isInUse: held.contains(r.key), vault: vault.vaultId)
        }
    }

    /// Recipients of the identities the vault was unlocked with.
    var heldRecipients: Set<String> {
        Set(unlockIdentities.compactMap { ($0 as? NativeIdentity)?.recipient.string })
    }

    /// A generated device key: its secret, and why the change is not finished
    /// when it is not (the vault is already encrypted to the key, so the
    /// secret must be shown whatever happened after).
    struct GeneratedKey: Sendable {
        var secret: String
        var problem: String?
        /// The key as a file (`sempere keys generate`), with its label.
        var file: KeyFile
    }

    /// Asks the device owner to authenticate before a change that lets
    /// another key read the vault (security review 2026-10, P1): the same
    /// check as Save Key… (`SystemOwnerAuthenticator`: Face ID or Touch ID
    /// when enrolled, else the passcode). Throws `vaultChanged` when another
    /// vault was opened, or this one locked, while the prompt was up.
    func requireOwner(_ authenticator: any OwnerAuthenticator, reason: String, vault vaultID: UUID) async throws {
        let gen = generation
        try await authenticator.authenticate(reason: reason)
        guard gen == generation, vault?.vaultId == vaultID, phase == .unlocked else { throw KeyError.vaultChanged }
    }

    /// The vault's display name for an authentication prompt.
    private var promptVaultName: String {
        vaultName ?? String(localized: "Vault", comment: "Name shown for a vault that has none")
    }

    /// Encrypts the vault to another device's public key, after the owner
    /// authenticates. `expectedVault`: the vault the request was made for
    /// (the key window's sheet).
    func addDeviceKey(recipient text: String, label: String, expectedVault: UUID? = nil,
                      authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws {
        let recipient = try Self.parseRecipient(text)
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireLocalKeyChanges()   // before any prompt
        if let expectedVault, expectedVault != vault.vaultId { throw KeyError.vaultChanged }
        guard !vault.recipients.contains(where: { $0.key == recipient.string }) else { throw KeyError.alreadyListed }
        try await requireOwner(authenticator, reason: String(localized: "Add a device key to “\(promptVaultName)”"),
                               vault: vault.vaultId)
        let name = Self.cleanLabel(label)
        let policy = RewrapSettings.policy()
        try await changeRecipients { try $0.addRecipient(recipient, label: name, policy: policy) }
    }

    /// Generates a post-quantum key for another device, encrypts the vault to
    /// it, and returns its secret text. Nothing else holds it: the caller
    /// shows it once. Once the vault's manifest lists the key, the secret is
    /// returned even if the rest of the change failed or the vault was
    /// closed meanwhile (`problem` says so): otherwise the vault would be
    /// encrypted to a key nobody has. The owner authenticates first.
    func generateDeviceKey(label: String, expectedVault: UUID? = nil,
                           authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws -> GeneratedKey {
        guard let start = vault, phase == .unlocked else { throw KeyError.notUnlocked }
        if let expectedVault, expectedVault != start.vaultId { throw KeyError.vaultChanged }
        try requireLocalKeyChanges()   // before any prompt
        try await requireOwner(authenticator, reason: String(localized: "Create a device key for “\(promptVaultName)”"),
                               vault: start.vaultId)
        guard let vault else { throw KeyError.notUnlocked }
        let identity = try NativeIdentity.generate(.postQuantum)
        guard !vault.recipients.contains(where: { $0.key == identity.recipient.string }) else { throw KeyError.alreadyListed }
        let name = Self.cleanLabel(label)
        let recipient = identity.recipient
        let policy = RewrapSettings.policy()
        return try await changeShowingSecret(identity, label: name) {
            try $0.addRecipient(recipient, label: name, policy: policy)
        }
    }

    /// Runs a change that makes the vault readable by the new `identity` and
    /// returns its secret. Once the manifest lists the key the secret is
    /// returned whatever failed after (`problem`): otherwise the vault would
    /// be encrypted to a key nobody has.
    private func changeShowingSecret(_ identity: NativeIdentity, label name: String,
                                     _ change: @escaping @Sendable (inout Vault) throws -> Vault.RewrapReport) async throws -> GeneratedKey {
        guard let vault else { throw KeyError.notUnlocked }
        let recipient = identity.recipient
        var applied = false
        let url = vault.url
        let identities = unlockIdentities
        do {
            try await changeRecipients(change, applied: { applied = true })
        } catch {
            // The rewrap can also throw after it wrote the manifest: look at it.
            let listed = applied || ((try? Vault.open(at: url, identities: identities))?.recipients
                .contains { $0.key == recipient.string } ?? false)
            guard listed else { throw error }
            let problem = error is CancellationError
                ? String(localized: "The vault was closed before the change finished. It finishes when the vault is opened and its keys are changed again.")
                : "\(error)"
            return GeneratedKey(secret: identity.string, problem: problem, file: KeyFile(identity: identity, label: name))
        }
        return GeneratedKey(secret: identity.string, file: KeyFile(identity: identity, label: name))
    }

    /// Stops encrypting the vault to `recipient` and re-encrypts every note
    /// with a new vault secret. That device can read nothing it has not
    /// already copied. `expectedVault`: the vault the request was made for.
    func removeDeviceKey(_ recipient: String, expectedVault: UUID? = nil) async throws {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        try requireLocalKeyChanges()   // before any prompt
        if let expectedVault, expectedVault != vault.vaultId { throw KeyError.vaultChanged }
        guard vault.recipients.contains(where: { $0.key == recipient }) else { throw KeyError.notListed }
        guard vault.recipients.count > 1 else { throw KeyError.lastKey }
        guard !heldRecipients.contains(recipient) else { throw KeyError.inUse }
        let parsed = try NativeRecipient(string: recipient)
        let policy = RewrapSettings.policy()
        try await changeRecipients { try $0.removeRecipient(parsed, policy: policy) }
    }

    /// Replaces another device's key by a pasted public key in one change
    /// (`Vault.replaceRecipient`, the CLI's `vault recipients replace`): the
    /// vault secret rotates and every file is re-encrypted once, so the old
    /// key opens nothing new and the new one opens everything. An empty
    /// `label` keeps the old one. The owner authenticates first (a new key
    /// can read the vault, P1). The key this window unlocked with cannot be
    /// replaced here (`replaceInUse`): this device would lose the vault, and
    /// an interrupted replace of it could only be finished with both keys.
    func replaceDeviceKey(_ old: String, with text: String, label: String, expectedVault: UUID? = nil,
                          authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws {
        let new = try Self.parseRecipient(text)
        let oldKey = try checkReplaceable(old, expectedVault: expectedVault)
        guard let vault else { throw KeyError.notUnlocked }
        guard !vault.recipients.contains(where: { $0.key == new.string }) else { throw KeyError.alreadyListed }
        try await requireOwner(authenticator, reason: String(localized: "Replace a device key of “\(promptVaultName)”"),
                               vault: vault.vaultId)
        let name = Self.replacementLabel(label)
        let policy = RewrapSettings.policy()
        try await changeRecipients { try $0.replaceRecipient(oldKey, with: new, label: name, policy: policy) }
    }

    /// Replaces another device's key by a newly generated one and returns
    /// its secret, shown once, as `generateDeviceKey` does (also when the
    /// change failed after the manifest named the new key).
    func generateReplacementKey(for old: String, label: String, expectedVault: UUID? = nil,
                                authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws -> GeneratedKey {
        _ = try checkReplaceable(old, expectedVault: expectedVault)
        guard let start = vault else { throw KeyError.notUnlocked }
        try await requireOwner(authenticator, reason: String(localized: "Replace a device key of “\(promptVaultName)”"),
                               vault: start.vaultId)
        let oldKey = try checkReplaceable(old, expectedVault: start.vaultId)
        let identity = try NativeIdentity.generate(.postQuantum)
        let name = Self.replacementLabel(label)
        let shown = name ?? start.recipients.first { $0.key == old }?.label ?? "Device"
        let recipient = identity.recipient
        let policy = RewrapSettings.policy()
        return try await changeShowingSecret(identity, label: shown) {
            try $0.replaceRecipient(oldKey, with: recipient, label: name, policy: policy)
        }
    }

    /// The listed, replaceable key `old` of the open (expected) vault.
    private func checkReplaceable(_ old: String, expectedVault: UUID?) throws -> NativeRecipient {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        if let expectedVault, expectedVault != vault.vaultId { throw KeyError.vaultChanged }
        guard vault.recipients.contains(where: { $0.key == old }) else { throw KeyError.notListed }
        guard !heldRecipients.contains(old) else { throw KeyError.replaceInUse }
        return try NativeRecipient(string: old)
    }

    /// A replacement's label: nil (keep the old one) when blank.
    static func replacementLabel(_ label: String) -> String? {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleanLabel(label)
    }

    /// The recovery kit (docs/cli.md "Keys"): the key this vault was unlocked
    /// with as a QR code and checked text. The PDF holds the secret key, so
    /// the owner authenticates first, as for Save Key… (P1).
    func recoveryKitPDF(a4: Bool = false,
                        authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws -> Data {
        guard let vault, phase == .unlocked else { throw KeyError.notUnlocked }
        guard heldIdentity != nil else { throw KeyError.noIdentity }
        try await requireOwner(authenticator, reason: String(localized: "Print the recovery kit of “\(promptVaultName)”"),
                               vault: vault.vaultId)
        guard let identity = heldIdentity else { throw KeyError.noIdentity }
        return try recoveryKit(secret: identity.string, recipient: identity.recipient.string, a4: a4)
    }

    /// The recovery kit PDF of one of the open vault's keys.
    func recoveryKit(secret: String, recipient: String, a4: Bool) throws -> Data {
        guard let vault else { throw KeyError.notUnlocked }
        var kit = RecoveryKit(secret: .identity(secret), recipient: recipient,
                              vault: .init(vault: vault, name: vaultName ?? "vault"), printed: Date())
        if a4 { kit.useA4() }
        return try kit.pdf()
    }

    // MARK: - Helpers

    static func parseRecipient(_ text: String) throws -> NativeRecipient {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recipient = try? NativeRecipient(string: trimmed) else { throw KeyError.notPostQuantum }
        guard recipient.isPostQuantum else { throw KeyError.notPostQuantum }
        return recipient
    }

    /// A label: trimmed, one line, at most 80 characters, "Device" when empty.
    static func cleanLabel(_ label: String) -> String {
        let oneLine = label.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? "Device" : String(oneLine.prefix(80))
    }

    /// Runs one recipient change on a copy of the vault with every editor
    /// closed, under the edit gate, coordinated in iCloud Drive (after every
    /// note is local: a file the rewrap cannot see would stay encrypted to
    /// the old set). The vault is adopted even when files remain, as the
    /// change then stays pending.
    ///
    /// `applied` is called once the change is on disk (the manifest names the
    /// new recipient set), before anything else can fail.
    func changeRecipients(_ change: @escaping @Sendable (inout Vault) throws -> Vault.RewrapReport,
                                  applied: () -> Void = {}) async throws {
        guard phase == .unlocked, let start = vault else { throw KeyError.notUnlocked }
        try requireLocalKeyChanges()   // a WebDAV copy: the server would keep the old files
        isChangingKeys = true
        defer { isChangingKeys = false }
        await editGate.acquire()
        defer { editGate.release() }
        let gen = generation
        try await openEditor(for: nil)   // saved, and closed: it holds the old secret
        await closeWindowEditors()
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        if isCloudVault { try await downloadEverything(start.url, gen: gen) { _ in } }
        let (next, report) = try await offMain { () throws -> (Vault, Vault.RewrapReport) in
            try CloudVault.coordinatedWrite(coordinate) { () throws -> (Vault, Vault.RewrapReport) in
                var copy = start
                let report = try change(&copy)
                return (copy, report)
            }
        }
        applied()
        try ensureCurrent(gen)
        adoptRewrapped(next)
        guard report.isComplete else { throw KeyError.incomplete(report.failures.count) }
    }
}
