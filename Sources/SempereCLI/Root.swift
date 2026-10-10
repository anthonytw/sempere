import ArgumentParser
import Sempere

struct SempereCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sempere",
        abstract: "Keys, verification, export and recovery for Sempere vaults.",
        discussion: """
            A vault is a folder of age-encrypted note revisions. This tool manages the keys and the
            vault, checks it, creates and edits notes as the app does (titles, tags, notebooks, paper,
            pages), exports notes to PDF, SVG or JSON, and recovers data with nothing but an identity
            file.

            Exit codes: 0 ok, 1 failure, 2 usage error, 3 unhealthy verify (vault or backup) or incomplete rewrap,
            4 cannot decrypt (wrong key or passphrase), 5 legacy vault (classic key: migrate first with
            `sempere vault recipients replace OLD NEW`).

            Environment: SEMPERE_VAULT, SEMPERE_IDENTITY, SEMPERE_PASSPHRASE, XDG_STATE_HOME.
            """,
        version: SempereAbout.versionText(program: "sempere", version: sempereVersion),
        subcommands: [
            KeysCommand.self, VaultCommand.self, NotesCommand.self, NotebooksCommand.self, TagsCommand.self,
            PagesCommand.self, AttachCommand.self, ItemsCommand.self, RecordingsCommand.self, ExportCommand.self,
            RecoverCommand.self, BlobsCommand.self, CompactCommand.self, SnapshotCommand.self, ImportCommand.self, SearchCommand.self, RecognizeCommand.self, RecognizeMathCommand.self, TranscribeCommand.self, InboxCommand.self,
            BackupCommand.self, RestoreCommand.self, SettingsCommand.self,
            SyncCommand.self, WebDAVCommand.self, RasterizePDFCommand.self, AboutCommand.self,
        ]
    )
}
