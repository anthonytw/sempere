import Crypto
import Foundation
import Sempere

// MARK: - Shared settings (format.md §13, docs/settings-sync.md §8)
//
// `settings.age` is a mutable file like `vault.json`, but its content merges
// per key, so a change on both sides is not a conflict: with the vault
// unlocked, both copies are opened (decrypted, tag verified), merged, and the
// result written to whichever side lacks it. A copy that does not verify never
// replaces one that does. Locked, the file follows the `vault.json` rule (keep
// both, report a conflict). Push-only runs never write locally: unlocked (and
// with keys that match vault.json on disk) they upload the merge of both
// copies and leave a server copy that is newer or needs a newer reader alone;
// locked, they upload the local copy. A file that needs a newer reader
// (`$minReaderVersion`) is left alone on both sides.

extension SyncEngine {
    func syncSharedSettings(remote: RemoteEntry?) throws {
        let name = SharedSettings.fileName
        guard let vault, vault.canRead, !options.pushOnly || vault.keysMatchManifestOnDisk() else {
            return options.pushOnly ? try pushMutable(name, remote: remote) : try syncMutable(name, remote: remote)
        }
        // A vault.json pulled by this run (a key change elsewhere) may carry a secret `vault`
        // does not know: the server's copy would then look unusable and be overwritten.
        if manifestHash() != checkerBaseManifest {
            report.skipped.append(.init(path: name, message: "vault.json changed in this run; synced on the next run"))
            return
        }

        let localURL = root.appendingPathComponent(name)
        let local = FileManager.default.fileExists(atPath: localURL.path)
            ? try BoundedRead.contents(of: localURL, maxBytes: SharedSettings.maxFileBytes) : nil
        var remoteData: Data?
        var etag: String?
        if remote != nil {
            let got = try transport.read([name], maxBytes: SharedSettings.maxFileBytes)
            try budget.downloaded(got.data.count)
            remoteData = got.data
            etag = remote?.etag ?? got.etag
        }
        let stamp = remote?.etag ?? etag ?? remote?.lastModified
        if local == nil && remoteData == nil { return }
        if let local, let remoteData, FileDigest.sha256(local) == FileDigest.sha256(remoteData) {
            state.mutable[name] = .init(hash: FileDigest.sha256(local), stamp: stamp)
            return
        }

        var newer: Set<String> = []
        func open(_ data: Data?, side: String) -> SharedSettings? {
            guard let data else { return nil }
            do { return try vault.openSharedSettings(data).settings } catch SharedSettingsError.needsNewerReader {
                newer.insert(side)
                return nil
            } catch {
                // Not verifying under this vault's secret (an older app's stale copy after a rotation, or junk):
                // it never replaces a copy that verifies, and is replaced by one.
                report.skipped.append(.init(path: name, message: SyncReport.printable("the \(side) copy is unusable: \(Self.describe(error))")))
                return nil
            }
        }
        let mine = open(local, side: "local")
        let theirs = open(remoteData, side: "server")
        // Push-only: what the server has that this side lacks stays there, never comes here.
        func take(_ data: Data) throws {
            if options.pushOnly { return }
            try download(name, data, stamp: stamp)
        }
        switch (newer.contains("local"), newer.contains("server")) {
        case (true, true):
            return options.pushOnly ? try pushMutable(name, remote: remote) : try syncMutable(name, remote: remote)
        case (true, false): return try upload(name, local: local ?? Data(), over: remote, etag: etag)
        case (false, true):
            if options.pushOnly {
                report.skipped.append(.init(path: name, message: "the server copy needs a newer reader; kept on the server"))
            }
            return try take(remoteData ?? Data())
        case (false, false): break
        }

        switch (mine, theirs) {
        case (nil, nil):
            return
        case (_?, nil):
            try upload(name, local: local ?? Data(), over: remote, etag: etag)
        case (nil, _?):
            try take(remoteData ?? Data())
        case (let m?, let t?):
            let merged = m.merging(t)
            if m == t {
                // The same settings sealed twice (two devices merged the same change): different
                // bytes, nothing to take or give. Taking the server's bytes here made a device
                // that syncs with two remotes holding such copies download one, then the
                // other, on every run (NDeviceStressTests).
                state.mutable[name] = .init(hash: FileDigest.sha256(local ?? Data()), stamp: stamp)
            } else if merged == t {
                try take(remoteData ?? Data())
            } else if merged == m {
                try upload(name, local: local ?? Data(), over: remote, etag: etag)
            } else if options.pushOnly {
                report.merged.append(name)
                guard !options.dryRun else { return }
                try upload(name, local: try vault.sealSharedSettings(merged), over: remote, etag: etag)
            } else {
                try requireLocalWrite("write \(name)")
                report.merged.append(name)
                guard !options.dryRun else { return }
                try vault.writeSharedSettings(merged)
                let written = try BoundedRead.contents(of: localURL, maxBytes: SharedSettings.maxFileBytes)
                try upload(name, local: written, over: remote, etag: etag)
            }
        }
    }

    private func upload(_ name: String, local: Data, over remote: RemoteEntry?, etag: String?) throws {
        let condition: PutCondition = remote == nil ? .create : Self.replaceCondition(etag: etag)
        if try push(name, local, condition: condition) {
            try recordMutable(name, hash: FileDigest.sha256(local))
        } else {
            report.skipped.append(.init(path: name, message: "the server copy changed while uploading; merged on the next run"))
        }
    }

    private func download(_ name: String, _ data: Data, stamp: String?) throws {
        try requireLocalWrite("write \(name)")
        report.downloaded.append(name)
        guard !options.dryRun else { return }
        try LocalFS.write(data, to: root.appendingPathComponent(name), replacing: true)
        state.mutable[name] = .init(hash: FileDigest.sha256(data), stamp: stamp)
    }
}
