import ArgumentParser
import Foundation
import Sempere
import SempereSync

// MARK: - vault conflicts (docs/cli.md "vault conflicts", docs/io.md "A vault folder held as a package")

struct VaultConflicts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conflicts",
        abstract: "Report (and merge back) a provider's conflict versions of a vault folder.",
        discussion: """
            For a vault folder in iCloud Drive or another provider (macOS). Without --merge it only reads: whether \
            the provider records the folder as a package (it then syncs it as one item), the unresolved conflict \
            versions of the folder itself and of its mutable files, and for each version the files the folder lacks, \
            by kind, and the mutable files that differ. No key is needed. Exit 0 when there is nothing (no version, \
            not a package), 3 otherwise.

            --merge holds one write of the folder for the whole run (pause Sempere on every device first). It copies \
            back only missing write-once files (epoch records first, then revisions, blobs, inbox files, join \
            requests, notebook records, the current kit's passphrase copy), each checked under the vault's key and \
            placed without ever replacing a file; one that fails goes to the quarantine folder, one the acceptance \
            rule sets aside goes to this machine's set-aside store, one waiting for a device-change record is left. \
            settings.age is merged per key with the current file; vault.json is taken only as a later version by home \
            in the same epoch; anything else is reported and left. Every mutable file of a version, and every unknown \
            file only a version has, is copied into <quarantine>/kept/ (unknown files are never placed). Only then are \
            the versions marked resolved (kept by the system unless --remove-versions; a version with a quarantined \
            or unplaced file is never removed). It needs this machine's device key or --identity (the recovery key \
            opens read-only: it works with --dry-run only). Exit 0 when everything was merged and resolved, 3 when \
            something was left or quarantined (listed), 1 on a failure. --dry-run prints the plan and writes nothing \
            (it works without a key, with structural checks only).
            """
    )

    @Argument(help: ArgumentHelp("The vault folder (default: --vault, $SEMPERE_VAULT).", valueName: "vault"))
    var path: String?

    @Flag(name: .long, help: "Copy missing write-once files back, settle mutable files, then resolve the versions.")
    var merge = false

    @Flag(name: .long, help: "With --merge: only print the plan.")
    var dryRun = false

    @Flag(name: .customLong("remove-versions"),
          help: "With --merge: remove each version once resolved (default: mark it resolved and keep it).")
    var removeVersions = false

    @Option(name: .long, help: ArgumentHelp("With --merge: where quarantined and kept-aside files go (a new or empty folder).",
                                            discussion: "Default: $XDG_STATE_HOME/sempere/conflicts/<vault id>/<time>.",
                                            valueName: "dir"))
    var quarantine: String?

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if (dryRun || removeVersions) && !merge { throw ValidationError("--dry-run and --remove-versions go with --merge") }
        if dryRun && removeVersions { throw ValidationError("--remove-versions does nothing with --dry-run") }
        if quarantine != nil && !merge { throw ValidationError("--quarantine goes with --merge") }
        // The recovery key opens a vault read-only (format.md §15): a merge writes, so it needs a device key.
        if merge && !dryRun && access.recoveryKey != nil {
            throw ValidationError("--recovery-key opens the vault read-only: --merge needs this machine's device key or "
                + "--identity (--merge --dry-run works with the recovery key)")
        }
    }

    func run() throws {
        var a = access
        if let path { a.vault = (path as NSString).expandingTildeInPath }
        let folder = try a.vaultURL().standardizedFileURL
        guard FileManager.default.fileExists(atPath: folder.path) else { throw CLIError.failure("\(folder.path): no such folder") }
        let provider = try Self.provider(for: folder)
        // Nothing here may rewrite the vault's index or sealed summaries at exit: a dry run and the report write nothing,
        // and a real run writes only what the merge decides (main.swift's `refreshWebIndexes`).
        OpenedVaults.shared.forget(folder)
        defer { OpenedVaults.shared.forget(folder) }

        guard merge else {
            let inspection: VaultFolderConflicts.Inspection
            do { inspection = try VaultFolderConflicts.inspect(folder: folder, provider: provider) } catch {
                throw CLIError.failure("\(error)")
            }
            if output.json { try output.emitJSON(InspectOutput(inspection)) } else { printInspection(inspection) }
            if !inspection.isClean { throw ExitCode(ExitStatus.unhealthy) }
            return
        }

        // A dry run checks against a copy of this machine's trust record, so it keeps nothing.
        let vault = try a.openVault(at: folder, dryRun ? .ifPossible : .required,
                                    trust: dryRun ? scratchTrustStore(for: folder) : nil)
        OpenedVaults.shared.forget(vault.url)
        defer { OpenedVaults.shared.forget(vault.url) }
        if !dryRun, !vault.canRead {
            throw CLIError.cannotDecrypt("--merge checks every file under the vault's key: pass --identity or --recovery-key")
        }
        let qdir = quarantine.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? Self.defaultQuarantine(vaultId: vault.vaultId)
        let report: VaultFolderConflicts.MergeReport
        do {
            report = try VaultFolderConflicts.merge(folder: folder, provider: provider, vault: vault,
                                                    options: .init(quarantine: qdir, dryRun: dryRun, removeVersions: removeVersions))
        } catch let e as VaultFolderConflicts.MergeError {
            if case .busy = e { throw CLIError.failure("\(e)") }
            throw CLIError.usage("\(e)")
        } catch let e as VaultFolderConflicts.ListingError {
            throw CLIError.failure("\(e)")
        }
        // Then the Finder's flag, only once everything is back and every version resolved: one less reason for a
        // package. The provider's own record of the folder is read again, so the output says whether it still syncs the
        // folder as one item.
        var bit: BundleBitOutput?
        if !dryRun, report.isComplete {
            let result = FinderBundleBit.clearReporting(at: folder)
            bit = BundleBitOutput(result, after: provider.itemRecord(of: folder))
        }
        if output.json { try output.emitJSON(MergeOutput(report, bundleBit: bit)) } else { printMerge(report, bundleBit: bit) }
        if !report.errors.isEmpty || bit?.result == "failed" { throw ExitCode(ExitStatus.failure) }
        if !report.isComplete { throw ExitCode(ExitStatus.unhealthy) }
    }

    /// The provider of `folder`: recorded versions for tests (`SEMPERE_TEST_PROVIDER_VERSIONS`), else the platform's.
    /// Debug builds only: a release build never takes versions from a folder an environment variable names.
    static func provider(for folder: URL) throws -> any FolderProvider {
        #if DEBUG
        if let store = Env.vars["SEMPERE_TEST_PROVIDER_VERSIONS"], !store.isEmpty {
            return RecordedVersionsProvider(root: folder, store: URL(fileURLWithPath: store))
        }
        #endif
        #if canImport(Darwin)
        return UbiquitousFolderHooks(root: folder)
        #else
        throw CLIError.failure("vault conflicts is not supported on this platform: provider conflict versions "
            + "(NSFileVersion) exist only on macOS")
        #endif
    }

    static func defaultQuarantine(vaultId: UUID) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return DeviceState.defaultURL(environment: Env.vars).deletingLastPathComponent()
            .appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent(vaultId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(f.string(from: Date()), isDirectory: true)
    }

    // MARK: Text

    static func packageLine(_ r: ProviderItemRecord?) -> String {
        guard let r else { return "unknown (the provider records nothing)" }
        let facts = "isPackage \(r.isPackage.map { "\($0)" } ?? "-"), type \(r.contentType ?? "-"), Finder kHasBundle "
            + (r.finderBundleBit.map { $0 ? "set" : "not set" } ?? "-")
        switch r.packageCause {
        case nil: return "no (\(facts))"
        case .finderBundleBit?: return "YES, from the Finder's kHasBundle flag (\(facts)); sync clears it"
        case .providerRecord?: return "YES, the provider's own record (\(facts)); only a new folder is plain (docs/io.md)"
        }
    }

    static func versionLine(_ v: VaultFolderConflicts.Version) -> String {
        let what = v.item.isEmpty ? "the vault folder" : v.item
        let kinds = v.missing.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", ")
        var s = "\(Format.local(v.modified))  \(v.device ?? "?")  of \(what): \(v.files) file(s)"
        let n = v.missing.values.reduce(0) { $0 + $1.count }
        if n > 0 { s += ", \(n) not in the folder (\(kinds))" }
        if !v.differing.isEmpty { s += ", differs: " + v.differing.joined(separator: " ") }
        if !v.skipped.isEmpty { s += ", not followed: " + v.skipped.joined(separator: "; ") }
        if let p = v.problem { s += "; CANNOT BE JUDGED: \(p)" }
        return s
    }

    func printInspection(_ i: VaultFolderConflicts.Inspection) {
        print("FOLDER    \(i.folder)")
        print("PROVIDER  \(i.provider)")
        print("PACKAGE   \(Self.packageLine(i.record))")
        for v in i.versions { print("VERSION   " + Self.versionLine(v)) }
        for p in i.skipped { print("SKIPPED   \(p)") }
        let once = i.writeOnceMissing, mutable = i.mutableToReview
        if !once.isEmpty {
            print("WRITE-ONCE, SAFE TO COPY BACK (\(once.count)):")
            for p in once { print("  \(p)") }
        }
        if !mutable.isEmpty {
            print("MUTABLE, NEED CARE (\(mutable.count)):")
            for p in mutable { print("  \(p)") }
        }
        if i.isClean {
            output.info("No conflict versions; the folder is not a package.")
        } else {
            output.info("\(i.versions.count) unresolved version(s). Merge back with: sempere vault conflicts "
                + "\"\(i.folder)\" --merge --dry-run")
        }
    }

    func printMerge(_ r: VaultFolderConflicts.MergeReport, bundleBit: BundleBitOutput?) {
        let verb = r.dryRun ? "would copy" : "copied"
        print("PACKAGE   \(Self.packageLine(r.inspection.record))")
        for p in r.copied { print("\(verb) \(p)") }
        for (p, whys) in r.quarantined.sorted(by: { $0.key < $1.key }) {
            for why in whys { print((r.dryRun ? "would quarantine " : "quarantined ") + "\(p): \(why)") }
        }
        for p in r.setAside { print((r.dryRun ? "would set aside " : "set aside ") + "\(p) (the acceptance rule does not take it)") }
        for p in r.keptUnknown { print("NOT PLACED \(p): an unknown file only a version has; kept aside, place it by hand if wanted") }
        for v in r.inspection.versions { for p in v.skipped { print("SKIPPED \(p) in version \(v.id)") } }
        for p in r.written { print((r.dryRun ? "would write " : "wrote ") + p) }
        for (p, how) in r.settled.sorted(by: { $0.key < $1.key }) { print("settled \(p): \(how)") }
        for (p, whys) in r.unsettled.sorted(by: { $0.key < $1.key }) { for why in whys { print("LEFT    \(p): \(why)") } }
        for (p, whys) in r.errors.sorted(by: { $0.key < $1.key }) { for why in whys { print("ERROR   \(p): \(why)") } }
        if !r.keptAside.isEmpty { print((r.dryRun ? "would keep aside " : "kept aside ") + "\(r.keptAside.count) mutable file(s)") }
        if let q = r.quarantine { print("QUARANTINE \(q) (report.json)") }
        let resolvedVerb = r.dryRun ? "would resolve" : (r.removed.isEmpty ? "resolved (kept)" : "resolved and removed")
        output.info("\(r.copied.count) file(s) \(verb); \(r.resolved.count) version(s) \(resolvedVerb); \(r.left.count) left.")
        if let b = bundleBit {
            switch b.result {
            case "cleared": print("cleared the Finder's kHasBundle flag on the folder")
            case "failed": print("ERROR   the Finder's kHasBundle flag could not be cleared (errno \(b.errno ?? 0))")
            default: break
            }
        }
        if bundleBit?.heldAsPackageAfter ?? r.inspection.heldAsPackage {
            output.info("The provider still syncs this folder as one item: move it to a new folder (docs/io.md "
                + "\"A vault folder held as a package\").")
        }
    }

    // MARK: JSON

    struct InspectOutput: Encodable {
        var supported = true
        var folder: String
        var provider: String
        var record: ProviderItemRecord?
        var heldAsPackage: Bool
        var packageCause: String?
        var versions: [VaultFolderConflicts.Version]
        var writeOnceMissing: [String]
        var mutableToReview: [String]
        var skipped: [String]

        init(_ i: VaultFolderConflicts.Inspection) {
            skipped = i.skipped
            folder = i.folder; provider = i.provider; record = i.record; heldAsPackage = i.heldAsPackage
            packageCause = i.record?.packageCause?.rawValue; versions = i.versions
            writeOnceMissing = i.writeOnceMissing; mutableToReview = i.mutableToReview
        }
    }

    struct MergeOutput: Encodable {
        var dryRun: Bool
        var complete: Bool
        var copied: [String]
        var quarantined: [String: [String]]
        var setAside: [String]
        var keptAside: [String]
        var keptUnknown: [String]
        var skipped: [String]
        var written: [String]
        var settled: [String: String]
        var unsettled: [String: [String]]
        var resolved: [String]
        var removed: [String]
        var left: [String]
        var errors: [String: [String]]
        var quarantine: String?
        var heldAsPackage: Bool
        var bundleBit: BundleBitOutput?

        init(_ r: VaultFolderConflicts.MergeReport, bundleBit: BundleBitOutput?) {
            self.bundleBit = bundleBit
            dryRun = r.dryRun; complete = r.isComplete; copied = r.copied; quarantined = r.quarantined
            setAside = r.setAside; keptAside = r.keptAside; keptUnknown = r.keptUnknown
            skipped = r.inspection.skipped + r.inspection.versions.flatMap { v in v.skipped.map { "\(v.id): \($0)" } }
            written = r.written; settled = r.settled; unsettled = r.unsettled
            resolved = r.resolved; removed = r.removed; left = r.left; errors = r.errors; quarantine = r.quarantine
            heldAsPackage = r.inspection.heldAsPackage
        }
    }

    /// What clearing the Finder's flag after a merge did, and what the provider records then.
    struct BundleBitOutput: Encodable {
        /// `notSet`, `cleared` or `failed`.
        var result: String
        var errno: Int32?
        /// The provider still syncs the folder as one item after the flag was cleared (its own record).
        var heldAsPackageAfter: Bool?
        var recordAfter: ProviderItemRecord?

        init(_ r: FinderBundleBit.ClearResult, after: ProviderItemRecord?) {
            switch r {
            case .notSet: result = "notSet"
            case .cleared: result = "cleared"
            case .failed(let code): result = "failed"; errno = code
            }
            recordAfter = after
            heldAsPackageAfter = after?.heldAsPackage
        }
    }
}
