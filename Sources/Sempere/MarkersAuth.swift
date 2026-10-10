import Crypto
import Foundation

// Authenticated version markers (format.md §2.1 "Version markers"; security
// review 2026-10, N3).
//
// `format` and `features` in `vault.json` decide whether a reader may write
// (§7.3). They are plaintext, so whoever can write the vault folder could set
// `format` back or drop a feature this version does not know, and a reader of
// this version would then write to a vault it must only read. `markersTag`
// authenticates both under a key derived from the vault secret, and the
// trust record keeps the last verified markers, so a removed tag, a changed
// marker and a replayed older `vault.json` are each reported as tampering.

extension RecipientsAuth {
    static let markersInfo = "sempere/1 markers key"

    /// `features` as the tag covers them: each once, sorted by UTF-8 bytes.
    static func canonicalFeatures(_ features: [String]) -> [String] {
        var seen = Set<[UInt8]>()
        var out: [[UInt8]] = []
        for f in features where seen.insert(Array(f.utf8)).inserted { out.append(Array(f.utf8)) }
        out.sort { $0.lexicographicallyPrecedes($1) }
        return out.map { String(decoding: $0, as: UTF8.self) }
    }

    /// `"sempere/1" ‖ 0 ‖ "markers" ‖ 0 ‖ vaultId ‖ 0 ‖ format (‖ 0 ‖ feature)*`,
    /// features canonical; nil when a marker holds a NUL (never tagged).
    static func markersMessage(vaultId: UUID, format: String, features: [String]) -> Data? {
        guard !format.utf8.contains(0), !features.contains(where: { $0.utf8.contains(0) }) else { return nil }
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "markers".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(contentsOf: format.utf8)
        for f in canonicalFeatures(features) { m.append(0); m.append(contentsOf: f.utf8) }
        return m
    }

    /// `markersTag` (lowercase hex) of `format` and `features` under `secret`;
    /// nil when a marker holds a NUL.
    public static func markersTag(vaultId: UUID, format: String, features: [String], secret: VaultSecret) -> String? {
        guard let m = markersMessage(vaultId: vaultId, format: format, features: features) else { return nil }
        return hex(Data(HMAC<SHA256>.authenticationCode(for: m, using: derive(secret, markersInfo))))
    }

    /// True when `tag` is 64 lowercase hex digits and verifies over the markers.
    public static func verifyMarkers(_ tag: String, vaultId: UUID, format: String, features: [String],
                                     secret: VaultSecret) -> Bool {
        guard let given = unhex(tag), let m = markersMessage(vaultId: vaultId, format: format, features: features) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: m, using: derive(secret, markersInfo))
    }

    /// Why `manifest`'s markers do not check (format.md §2.1 "Version
    /// markers") for a reader holding `secret` whose trust record is `record`;
    /// nil when they check, or the vault was never tagged and nothing says so.
    static func markersProblem(_ manifest: VaultManifest, secret: VaultSecret,
                               record: RecipientsTrustRecord?) -> RecipientsProblem.Reason? {
        if let tag = manifest.markersTag {
            guard verifyMarkers(tag, vaultId: manifest.vaultId, format: manifest.format, features: manifest.features,
                                secret: secret) else { return .markersMismatch }
        } else if manifest.features.contains(VaultManifest.markersTagFeature) || record?.markers != nil {
            return .markersRemoved
        }
        if let seen = record?.markers, !seen.isCovered(by: manifest) { return .markersRolledBack }
        return nil
    }
}

/// The version markers a device last verified (format.md §2.1 "Trust record").
public struct VaultMarkers: Hashable, Sendable, Codable {
    public var format: String
    /// Canonical: each once, sorted by UTF-8 bytes.
    public var features: [String]

    public init(format: String, features: [String]) {
        self.format = format
        self.features = RecipientsAuth.canonicalFeatures(features)
    }

    /// The markers of `manifest`.
    public init(_ manifest: VaultManifest) { self.init(format: manifest.format, features: manifest.features) }

    /// True when `manifest` names at least this major and every one of these
    /// features. Markers only ever grow (a writer never lowers `format` nor
    /// removes a feature), so anything less is a rollback.
    public func isCovered(by manifest: VaultManifest) -> Bool {
        let mine = SempereFormat.major(of: format) ?? 0
        let theirs = SempereFormat.major(of: manifest.format) ?? 0
        return theirs >= mine && Set(features).isSubset(of: Set(manifest.features))
    }

    /// The larger of two: the higher major, and every feature of either.
    func merged(with other: VaultMarkers) -> VaultMarkers {
        let a = SempereFormat.major(of: format) ?? 0, b = SempereFormat.major(of: other.format) ?? 0
        return VaultMarkers(format: b > a ? other.format : format, features: features + other.features)
    }
}

extension VaultManifest {
    /// Writes `markersTag` (and the feature) under `secret`: every writer does
    /// it in every write of `vault.json` (format.md §2.1 "Version markers").
    public mutating func tagMarkers(secret: VaultSecret) {
        if !features.contains(Self.markersTagFeature) { features.append(Self.markersTagFeature) }
        markersTag = RecipientsAuth.markersTag(vaultId: vaultId, format: format, features: features, secret: secret)
    }

    /// True when `markersTag` is present and verifies under `secret`, or is
    /// absent and nothing says the vault had one (a vault written before
    /// version markers, which the next write tags).
    func markersIntact(secret: VaultSecret) -> Bool {
        guard let tag = markersTag else { return !features.contains(Self.markersTagFeature) }
        return RecipientsAuth.verifyMarkers(tag, vaultId: vaultId, format: format, features: features, secret: secret)
    }
}

extension Vault {
    /// Whether `vault.json`'s version markers are tagged (format.md §2.1).
    public var markersTagged: Bool { manifest.markersTag != nil }

    /// Tags the version markers on disk for a vault whose list checks and
    /// whose markers were never tagged (the one-time upgrade, like the
    /// recipients tag's), and saves them in this device's trust record.
    /// Does nothing when the file on disk already carries a tag that verifies.
    ///
    /// - Throws: `manifestCorrupt` when `vault.json` changed since the vault
    ///   was opened (another list, secret or markers that do not verify).
    func tagMarkersOnDisk() throws {
        try requireNotReadOnly()
        let secret = try requireSecret()
        let m = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        guard m.recipients.map(\.key) == manifest.recipients.map(\.key), m.vaultSecret == manifest.vaultSecret,
              m.markersIntact(secret: secret) else {
            throw VaultError.manifestCorrupt("vault.json changed since it was opened; open the vault again")
        }
        guard m.markersTag == nil else { return }
        let written = try Self.writeManifest(m, to: manifestURL, replacing: true, secret: secret)
        try rememberRecipients(markers: VaultMarkers(written))
    }

    /// Repairs version markers that do not check (`markersMismatch`,
    /// `markersRemoved`, `markersRolledBack`; format.md §2.1 "Version
    /// markers"): writes the larger of the markers on disk and this device's
    /// record (the higher major, every feature of either), tagged under the
    /// vault's secret. Markers only grow, so nothing a writer set is lost.
    /// Explicit only: the user runs it after checking where the change came from.
    ///
    /// - Throws: `recipientsNotRepairable` for any other problem, or when the
    ///   repaired markers name a format or feature this version does not
    ///   implement (restore `vault.json` with a newer version instead);
    ///   `readOnly` for a vault already marked newer.
    public mutating func repairMarkers() throws {
        let secret = try requireSecret()
        guard let problem = recipientsStatus.problem else {
            throw VaultError.recipientsNotRepairable("the version markers check; nothing to repair")
        }
        guard problem.reason.isMarkers else {
            throw VaultError.recipientsNotRepairable("the device list does not check: repair it first")
        }
        try requireNotReadOnly()
        var m = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        guard m.recipients.map(\.key) == manifest.recipients.map(\.key), m.vaultSecret == manifest.vaultSecret else {
            throw VaultError.manifestCorrupt("vault.json changed since it was opened; open the vault again")
        }
        m = try Self.restoringMarkers(m, recorded: try trustStore?.record(for: vaultId)?.markers)
        manifest = try Self.writeManifest(m, to: manifestURL, replacing: true, secret: secret)
        recipientsStatus = Self.recipientsStatus(manifest, secret: secret, trust: trustStore)
        if recipientsStatus.allowsWriting { try rememberRecipients(markers: VaultMarkers(manifest)) }
    }
}

extension Vault {
    /// `m` with the larger of its markers and `recorded` (the higher major,
    /// every feature of either; format.md §2.1 "Version markers").
    ///
    /// - Throws: `recipientsNotRepairable` when the result names a format or
    ///   feature this version does not implement.
    static func restoringMarkers(_ m: VaultManifest, recorded: VaultMarkers?) throws -> VaultManifest {
        var out = m
        let target = recorded.map { VaultMarkers(m).merged(with: $0) } ?? VaultMarkers(m)
        for f in target.features where !out.features.contains(f) { out.features.append(f) }
        out.format = target.format
        let reasons = readOnlyReasons(out)
        guard reasons.isEmpty else {
            throw VaultError.recipientsNotRepairable("this device last saw the vault with "
                + "\(reasons.descriptions.joined(separator: "; ")): restore vault.json from a device running that version")
        }
        return out
    }
}

extension RecipientsProblem.Reason {
    /// True for the three version-marker problems (format.md §2.1).
    public var isMarkers: Bool {
        switch self {
        case .markersMismatch, .markersRemoved, .markersRolledBack: return true
        case .tagMismatch, .tagRemoved, .secretUnconfirmed, .recordUnreadable: return false
        }
    }
}

extension Vault {
    /// The version markers this device's trust record holds (format.md §2.1);
    /// nil when it has none, or it cannot be read.
    public var recordedMarkers: VaultMarkers? { (try? trustStore?.record(for: vaultId))??.markers }

    /// Tags the version markers of a vault written before they were
    /// authenticated (format.md §2.1 "Version markers"), once, as the first
    /// write would: every check of `requireWritable` applies first (an
    /// untagged list is tagged too). Returns false, writing nothing, when the
    /// markers are tagged already, the vault is locked or read-only, or its
    /// list does not check.
    @discardableResult
    public mutating func upgradeMarkers() throws -> Bool {
        guard manifest.markersTag == nil, let secret, recipientsStatus.allowsWriting, !isReadOnly else { return false }
        try requireWritable()
        if case .untagged = recipientsStatus {} else { try tagMarkersOnDisk() }   // no-op when just tagged
        manifest = try Self.readManifest(FileIO.read(manifestURL, maxBytes: BoundedRead.maxManifestBytes))
        recipientsStatus = Self.recipientsStatus(manifest, secret: secret, trust: trustStore)
        return manifest.markersTag != nil
    }
}
