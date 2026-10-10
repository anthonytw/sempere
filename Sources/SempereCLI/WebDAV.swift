import ArgumentParser
import Foundation
import SempereWebDAV

struct WebDAVCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "webdav",
        abstract: "Check a WebDAV server and find the vaults on it.",
        subcommands: [WebDAVCheckCommand.self]
    )
}

struct WebDAVCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Test a WebDAV URL and list the vaults at it or one folder below it.",
        discussion: """
            Lists the URL (PROPFIND) with the given user and password and says what is there: a vault (the
            URL holds a vault.json), vaults in the folders directly below it (at most 64 folders are looked
            into), or no vault. This is the app's "Test Connection" and vault list. Nothing is written.

            Only https is accepted, plus http to localhost. The password is read from the environment
            variable named by --password-env (default SEMPERE_WEBDAV_PASSWORD). The server's certificate
            must be trusted by the system.

            With --json, a failure is reported as {"reachable": false, "problem": …, "message": …}, the
            problem being offline, unauthorized, certificate, not-found, redirect or failed.

            Exit codes: 0 at least one vault found, 1 no vault there or the server could not be used.
            """
    )

    @Argument(help: ArgumentHelp("The WebDAV collection to check (https://host/path/).", valueName: "url"))
    var url: String

    @OptionGroup var login: WebDAVLoginOptions
    @OptionGroup var output: OutputOptions

    struct Failure: Encodable {
        var url: String
        var reachable = false
        var problem: String
        var message: String
    }

    struct Success: Encodable {
        var url: String
        var reachable = true
        var outcome: String
        var vaults: [WebDAVVaultListing]
        var foldersChecked: Int
        var foldersSkipped: Int
        var unreadable: [String]
    }

    func run() throws {
        guard let remote = URL(string: url) else { throw CLIError.usage("not a URL: \(url)") }
        let client = try login.client(remote)
        let shown = SyncReport.printable(remote.absoluteString)
        let result: WebDAVCheckResult
        do {
            result = try WebDAVConnection.check(client)
        } catch {
            let problem = WebDAVSyncProblem.from(error: error)
            let message = CLIError.from(error).message
            if output.json {
                try output.emitJSON(Failure(url: shown, problem: problem.code, message: message))
            } else {
                printError("\(shown): \(message)")
            }
            throw ExitCode(ExitStatus.failure)
        }
        if output.json {
            try output.emitJSON(Success(url: shown, outcome: result.outcome.rawValue, vaults: result.vaults,
                                        foldersChecked: result.foldersChecked, foldersSkipped: result.foldersSkipped,
                                        unreadable: result.unreadable))
        } else {
            switch result.outcome {
            case .vault: output.info("\(shown): reachable; a vault")
            case .vaultsBelow: output.info("\(shown): reachable; \(result.vaults.count) vault(s) below it")
            case .noVault: output.info("\(shown): reachable; no vault here or one folder below")
            }
            for v in result.vaults {
                print("\(v.vaultId)  \(v.name)  \(v.url)")
            }
            for name in result.unreadable { printStderr("not a vault manifest: \(name)/vault.json") }
            if result.foldersSkipped > 0 { printStderr("\(result.foldersSkipped) folder(s) not looked into") }
        }
        if result.vaults.isEmpty { throw ExitCode(ExitStatus.failure) }
    }
}
