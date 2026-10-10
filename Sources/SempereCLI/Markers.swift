import ArgumentParser
import Foundation
import Sempere

/// `sempere vault markers`: the authenticated version markers (`format` and
/// `features`, format.md §2.1 "Version markers"; security review 2026-10, N3).
struct VaultMarkersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markers",
        abstract: "Show, tag or repair the authentication of vault.json's format and features.",
        subcommands: [MarkersStatus.self, MarkersTag.self, MarkersRepair.self],
        defaultSubcommand: MarkersStatus.self
    )
}

/// `sempere vault markers [status] --json`.
struct MarkersStatusOutput: Encodable {
    var format: String
    var features: [String]
    /// True when vault.json carries `markersTag`.
    var tagged: Bool
    /// `verified`, `untagged`, `tampered` or `not-checked` (locked).
    var status: String
    /// For `tampered`: `markersMismatch`, `markersRemoved`, `markersRolledBack`, or a device-list reason.
    var reason: String?
    /// The markers this machine's trust record holds (nil: none).
    var recorded: VaultMarkers?

    init(_ vault: Vault) {
        format = vault.manifest.format
        features = vault.manifest.features
        tagged = vault.markersTagged
        recorded = vault.recordedMarkers
        let s = vault.recipientsStatus
        if let p = s.problem {
            status = "tampered"; reason = p.reason.rawValue
        } else if case .notChecked = s {
            status = "not-checked"
        } else {
            status = tagged ? "verified" : "untagged"
        }
    }

    func printText() {
        print("Format:         \(format)" + (features.isEmpty ? "" : " (\(features.joined(separator: ", ")))"))
        let text: String
        switch status {
        case "verified": text = "authenticated"
        case "untagged": text = "not authenticated yet (an older vault; the next write, or `sempere vault markers tag`, tags it)"
        case "not-checked": text = tagged ? "authenticated; not checked (locked; pass --identity)" : "not checked (locked)"
        default:
            text = "TAMPERED (\(reason ?? "?")): writing is refused until "
                + ((reason ?? "").hasPrefix("markers") ? "`sempere vault markers repair`" : "the device list is repaired")
        }
        print("Markers:        \(text)")
        if let recorded {
            print("Last verified:  \(recorded.format) (\(recorded.features.joined(separator: ", ")))")
        }
    }
}

struct MarkersStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether vault.json's format and features are authenticated and check.",
        discussion: "Works without a key (nothing is then checked)."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.ifPossible, migration: true)
        let out = MarkersStatusOutput(vault)
        if output.json { try output.emitJSON(out) } else { out.printText() }
    }
}

struct MarkersTag: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Authenticate the format and features of a vault written before they were (once; needs the key).",
        discussion: """
            What the first write to such a vault does anyway: writes markersTag and the markers-tag feature \
            (older Sempere versions then stop writing to it) and records the markers on this machine. A list \
            or markers that do not check are refused (exit 6).
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required, migration: true)
        try vault.requireTrustedRecipients()
        try vault.requireNotReadOnly()
        let changed = try vault.upgradeMarkers()
        if output.json {
            struct Out: Encodable { var tagged: Bool; var status: MarkersStatusOutput }
            try output.emitJSON(Out(tagged: changed, status: MarkersStatusOutput(vault)))
        } else {
            output.info(changed ? "Format and features are now authenticated." : "Already authenticated; nothing to do.")
        }
    }
}

struct MarkersRepair: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Undo a format or feature change made without the vault's key (needs the key).",
        discussion: """
            For a vault whose markers do not check (format.md §2.1: a tag that does not verify, a removed tag, \
            or an older vault.json put back; writes exit 6). Writes the larger of the markers in vault.json and \
            those this machine last verified (the higher format, every feature of either), tagged. Markers \
            only grow, so nothing a writer set is lost. Refused when the result would name a format or feature \
            this version does not implement: restore vault.json with that version instead.
            """
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        var vault = try access.openVault(.required, migration: true)
        try vault.repairMarkers()
        if output.json { try output.emitJSON(MarkersStatusOutput(vault)); return }
        output.info("Repaired: \(vault.manifest.format) (\(vault.manifest.features.joined(separator: ", "))).")
    }
}
