import ArgumentParser
import Foundation
import Sempere

/// `sempere vault index`: the file listing a static web server cannot give
/// the web viewer (docs/web-viewer.md "Hosting").
struct VaultIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Write sempere-index.json, the note and revision listing the web viewer reads on a static server.",
        discussion: """
            A plain static web server cannot list folders, so the web viewer (web/, docs/web-viewer.md) reads
            this file instead: {"format": "sempere-index/1", "notes": {"<noteId>": ["<revision file>", ...]}}.
            It holds only names that storage already shows (note ids and revision file names), never
            content, and needs no key. Once it exists it stays current: every sempere command that opens the
            vault rewrites it when the listing changed, and sync webdav rewrites the server's copy. A
            WebDAV server needs no index. --out - prints it instead of writing <vault>/sempere-index.json.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Where to write the index (default <vault>/sempere-index.json; - for stdout).")
    var out: String?

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let notes = try vault.webIndexListing()
        let revisions = notes.values.reduce(0) { $0 + $1.count }
        let data = try WebIndex.encode(notes)
        if out == "-" {
            FileHandle.standardOutput.write(data)
            return
        }
        // Into the vault only if it may be written (format.md §7.3: exit 7).
        if out == nil { try vault.requireWritable() }
        let url = out.map { URL(fileURLWithPath: $0) } ?? vault.webIndexURL
        try data.write(to: url, options: .atomic)
        if output.json {
            try output.emitJSON(Report(path: url.path, notes: notes.count, revisions: revisions))
        } else {
            output.info("Wrote \(url.path): \(notes.count) notes, \(revisions) revisions")
        }
    }

    private struct Report: Encodable {
        var path: String
        var notes: Int
        var revisions: Int
    }
}

/// The vaults this run of `sempere` opened, so that `sempere-index.json`
/// is brought up to date once the command is done (`WebIndex`): one
/// rewrite per command, whatever it wrote, and no command can forget it.
final class OpenedVaults: @unchecked Sendable {
    static let shared = OpenedVaults()
    private let lock = NSLock()
    private var urls: [URL] = []
    /// The vaults this run unlocked, so their published summaries (format.md §12) can be refreshed too.
    private var unlocked: [URL: Vault] = [:]

    func recordUnlocked(_ vault: Vault) {
        lock.lock(); defer { lock.unlock() }
        unlocked[vault.url.standardizedFileURL] = vault
    }

    /// Leaves `url` alone at exit (a push-only sync writes nothing in its vault).
    func forget(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let u = url.standardizedFileURL
        urls.removeAll { $0 == u }
        unlocked[u] = nil
    }

    /// Leaves `url` alone at exit because the command cannot have written to
    /// it (read-only by construction: `notes list`, `notes show`, `search`,
    /// `notes search`),
    /// so it does not list the vault again for nothing.
    func markUnchanged(_ url: URL) { forget(url) }

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let u = url.standardizedFileURL
        if !urls.contains(u) { urls.append(u) }
    }

    /// Refreshes the index of every vault opened; a failure is a warning,
    /// never the command's exit status.
    func refreshWebIndexes() {
        lock.lock()
        let all = urls
        let keys = unlocked
        urls = []
        unlocked = [:]
        lock.unlock()
        for url in all {
            // One listing serves both files (each used to list the vault itself).
            var listing: [String: [String]]?
            do {
                guard let vault = try? Vault.open(at: url) else { continue }
                if FileManager.default.fileExists(atPath: vault.webIndexURL.path)
                    || (keys[url] != nil && FileManager.default.fileExists(atPath: vault.publishedSummariesURL.path)) {
                    listing = try? vault.webIndexListing()
                }
                try vault.refreshWebIndex(listing: listing)
            } catch {
                printStderr("warning: cannot update \(url.appendingPathComponent(WebIndex.fileName).path): "
                    + CLIError.from(error).message)
            }
            // Only where it exists and the vault was unlocked (it needs the key); unchanged notes are reused.
            guard let unlockedVault = keys[url] else { continue }
            do {
                try unlockedVault.refreshPublishedSummaries(cacheDirectory: SummaryCache.cliDirectory(), ownListing: listing)
            } catch {
                printStderr("warning: cannot update \(url.appendingPathComponent(PublishedSummaries.fileName).path): "
                    + CLIError.from(error).message)
            }
        }
    }
}
