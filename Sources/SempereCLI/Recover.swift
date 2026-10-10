import Age
import ArgumentParser
import Foundation
import Sempere

struct RecoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Decrypt one revision file and print its JSON, or one attachment blob and print its content.",
        discussion: """
            Needs only an identity file and the .age file. The inner tag is verified when a vault is
            known (--vault, else a vault.json found in a parent directory of the file, else
            $SEMPERE_VAULT) and the identity opens it; otherwise "UNVERIFIED" is printed to standard
            error. The JSON goes to standard output exactly as
            `age -d -i KEY FILE | tail -c +38 | gunzip` prints it.

            A blob (notes/<id>/att/<name>.<kind>.age) prints its content exactly as
            `age -d -i KEY FILE | tail -c +46 | head -c LEN` does (format.md §8.1.7). Its framing,
            padding and content hash are always checked, its name when the vault is known. Content
            streams as it is decrypted: if the command fails, discard the output.
            """
    )

    @Argument(help: ArgumentHelp("The revision file.", valueName: "FILE.age"))
    var file: String

    @Option(name: .customLong("note-id"),
            help: ArgumentHelp("The note id the tag binds to (default: the file's directory name).", valueName: "uuid"))
    var noteId: String?

    @Flag(name: .customLong("no-verify"),
          help: "On a tag mismatch print the body anyway, with a warning, and exit 3 (for damaged vaults).")
    var noVerify = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if output.json { throw ValidationError("recover prints the revision's own JSON; --json does not apply") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let isBlob = BlobName.parse(url.lastPathComponent) != nil

        var ids: [any AgeIdentity] = try access.explicitIdentities()
        let vaultURL = access.vault.map { URL(fileURLWithPath: $0) } ?? findVault(above: url)
            ?? Env.vars["SEMPERE_VAULT"].map { URL(fileURLWithPath: $0) }
        if ids.isEmpty {
            guard let vaultURL else { throw CLIError.cannotDecrypt("no key: pass --identity FILE") }
            ids = [try access.identityFromKeyFiles(of: try Vault.open(at: vaultURL))]
        }

        var vault: Vault?
        var why = "no vault found: pass --vault or keep the file inside its vault"
        if let vaultURL {
            do { vault = try Vault.open(at: vaultURL, identities: ids) } catch {
                why = "vault \(vaultURL.path) did not open: \(CLIError.from(error).message)"
            }
        }
        if isBlob { return try recoverBlob(url, identities: ids, vault: vault, why: why) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw CLIError.failure("cannot read \(file): \(error.localizedDescription)")
        }
        let note = (noteId ?? url.deletingLastPathComponent().lastPathComponent).lowercased()
        if vault != nil, UUID(uuidString: note) == nil {
            vault = nil
            why = "cannot tell the note id from the path; pass --note-id"
        }

        let result: RecoveredRevision
        do {
            result = try Recovery.decrypt(data, noteId: note, filename: url.lastPathComponent, identities: ids,
                                          vault: vault, onMismatch: noVerify ? .allowMismatch : .fail)
        } catch BodyFramingError.tagMismatch {
            throw CLIError.failure("tag mismatch: the file was altered, moved or belongs to another vault "
                + "(check --note-id; use --no-verify to print the body anyway for damaged vaults)")
        }
        FileHandle.standardOutput.write(result.json)
        if result.tagMismatch {
            printStderr("WARNING: tag mismatch, content may be tampered or from another vault")
            throw ExitCode(ExitStatus.unhealthy)
        }
        if !result.verified {
            if !output.quiet { printStderr("UNVERIFIED: tag not checked (\(why))") }
        } else if output.verbose {
            printStderr("tag verified against vault \(vault?.vaultId.uuidString.lowercased() ?? "?")")
        }
    }

    private func recoverBlob(_ url: URL, identities: [any AgeIdentity], vault: Vault?, why: String) throws {
        let result: RecoveredBlob
        do {
            result = try Recovery.decryptBlob(at: url, identities: identities, vault: vault) { piece in
                autoreleasing { FileHandle.standardOutput.write(piece) }
            }
        } catch BlobError.nameMismatch {
            throw CLIError.failure("the blob's name does not match its content under this vault's secret: altered, "
                + "planted, or from another vault (nothing was printed)")
        } catch {
            throw CLIError.failure("\(CLIError.from(error).message); discard the output printed so far")
        }
        if !result.nameVerified {
            if !output.quiet { printStderr("UNVERIFIED NAME: content hash checked, name not (\(why))") }
        } else if output.verbose {
            printStderr("content \(result.header.sha256), \(result.header.length) bytes; name verified")
        }
    }

    /// The nearest ancestor directory holding `vault.json`.
    private func findVault(above file: URL) -> URL? {
        var dir = file.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(Vault.manifestName).path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
