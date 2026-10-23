import ArgumentParser
import Foundation
import Sempere

/// `sempere vault summaries`: the published summaries file (format.md §12)
/// the web viewer lists a vault from without decrypting every note.
struct VaultSummaries: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summaries",
        abstract: "Write sempere-summaries.sealed, the encrypted note summaries the web viewer lists the vault from.",
        discussion: """
            The file (format.md §12) holds each note's title, tags, notebook, flags, page count and searchable
            text, with the names of the revision files it was made from, sealed (AES-256-GCM) under a key
            derived from the vault key: only the vault's keys open it. It is a hint: a reader uses an entry
            only while the note's revision files are exactly those, and reads the note otherwise. Notes with
            unreadable revisions get no entry. An existing file's entries for unchanged notes are reused, so
            only changed notes are read (and the summary cache, unless --no-cache).

            Once it exists it stays current: every sempere command that unlocks the vault rewrites it when a
            note changed, and sync webdav keeps the server's copy current (or creates it with --web-viewer).
            --out - prints the sealed file; --plaintext writes the JSON content instead (for checks; it holds
            note titles and text in the clear, so it needs --out).
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var cache: CacheOptions
    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Where to write it (default <vault>/sempere-summaries.sealed; - for stdout).")
    var out: String?

    @Flag(name: .long, help: "Write the decrypted JSON content instead of the sealed file.")
    var plaintext = false

    @Flag(name: .long, help: "Write this machine's own file, summaries/<device>.sealed (format.md §12.5), instead of the root file.")
    var deviceFile = false

    func run() throws {
        // Plaintext only where the user names it, never at the vault's sealed path by default.
        if plaintext && out == nil { throw CLIError.usage("--plaintext needs --out (a file outside the vault, or -)") }
        if deviceFile && out != nil { throw CLIError.usage("--device-file writes into the vault; give it or --out, not both") }
        let vault = try access.openVault(.required)
        try vault.requireCompleteCopy()   // entries come from the local notes: missing ones would be dropped
        // Into the vault only if it may be written (format.md §7.3: exit 7), as `vault index`.
        if out == nil { try vault.requireWritable() }
        var inVault = vault.publishedSummariesURL
        var device: DeviceID?
        if deviceFile {
            let id = try vault.writerDevice ?? DeviceState.loadOrCreate(at: DeviceState.defaultURL()).device
            device = id
            inVault = vault.devicePublishedSummariesURL(id)
        }
        let target = out.map { $0 == "-" ? nil : URL(fileURLWithPath: $0) } ?? inVault
        let reuse = target.map { url -> [UUID: PublishedSummaries.Entry] in
            guard let data = try? BoundedRead.contents(of: url, maxBytes: PublishedSummaries.maxFileBytes) else { return [:] }
            return (try? vault.openPublishedSummaries(data)) ?? [:]
        } ?? [:]
        let (entries, read) = try vault.publishedSummaryEntries(reuse: reuse, cache: cache.cache(for: vault))
        let notes = try vault.noteIDs().count
        let data: Data
        if let device {
            // The device's own file names it and carries its next version (format.md §12.5), or no other
            // device takes it.
            data = try vault.writeDevicePublishedSummaries(entries, device: device)
        } else {
            data = plaintext ? try PublishedSummaries.encode(entries, vaultId: vault.vaultId)
                : try vault.sealPublishedSummaries(entries)
        }
        guard let target else {
            FileHandle.standardOutput.write(data)
            return
        }
        // The plaintext holds titles and text: owner-only from the moment it exists (0600), never chmod'ed later.
        // (The device file was written above.)
        if plaintext {
            try writePrivateFile(data, to: target)
        } else if device == nil {
            try data.write(to: target, options: .atomic)
        }
        if output.json {
            try output.emitJSON(Report(path: target.path, notes: notes, entries: entries.count, read: read,
                                       bytes: data.count))
        } else {
            output.info("Wrote \(target.path): \(entries.count) of \(notes) notes (\(read) read, the rest reused), "
                        + "\(data.count) bytes")
        }
    }

    private struct Report: Encodable {
        var path: String
        /// Notes in the vault.
        var notes: Int
        /// Notes with an entry (the others have unreadable revisions).
        var entries: Int
        /// Notes summarized again (not reused from the existing file).
        var read: Int
        var bytes: Int
    }
}
