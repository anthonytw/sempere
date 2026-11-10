import Foundation
import Sempere

// The iPhone's half of the Apple Watch hand-off (docs/design/1.1-watch.md §3.6): `WatchIntake` (SempereCapture; the checks,
// the received set, the routing by `meta.vault`) over `CaptureDelivery` (the ledger, the inbox, the queue). The app's
// WatchConnectivity delegate (`WatchConnectivityService`, `Apps/`) only hands it files and messages.

/// `WatchDelivery` over the app's `CaptureDelivery` and the stored capture profile.
struct CaptureWatchDelivery: WatchDelivery {
    var delivery: CaptureDelivery
    /// The stored capture profile (the Keychain in the app); nil or unreadable means no current vault.
    var store: any CaptureProfileStore

    private var stored: StoredCaptureProfile? { try? store.load() }

    var currentVault: UUID? { stored?.profile.vaultId }

    private func vaultFolder(_ vault: UUID) -> URL? { delivery.vaultStore?.entry(id: vault)?.url }

    func inboxHolds(id: UUID, vault: UUID) -> Bool {
        guard let url = vaultFolder(vault) else { return false }
        let file = url.appendingPathComponent(CaptureFile.folderName, isDirectory: true)
            .appendingPathComponent(CaptureFile.name(id, .capture))
        return FileManager.default.fileExists(atPath: file.path)
    }

    func deliverToCurrent(_ sealed: SealedCapture) throws -> WatchPlacement {
        guard let stored else { throw QuickCaptureError.profileUnreadable }
        switch try delivery.deliver(sealed, stored) {
        case .vault: return .vault
        case .queued: return .queued
        }
    }

    func holds(vault: UUID) -> Bool { vaultFolder(vault) != nil }

    /// Recorded in `vault`'s ledger under the file's own epoch (no profile of that vault is needed), then placed.
    func recordAndPlace(_ sealed: SealedCapture, in vault: UUID) throws -> Bool {
        guard let url = vaultFolder(vault) else { return false }
        let placed = delivery.bookmarks.withAccess(to: url) { () -> Bool in
            guard CaptureDelivery.acceptsCaptures(at: url, vaultId: vault) else { return false }
            do {
                try WatchLedger.record(sealed, in: delivery.ledger?(vault))   // intent first: never placed unrecorded
                try CaptureWriter.store(sealed, in: url.appendingPathComponent(CaptureFile.folderName, isDirectory: true))
                return true
            } catch {
                return false   // not reachable now: queued by the caller
            }
        }
        if placed { delivery.delivered(vault) }
        return placed
    }

    func queue(_ sealed: SealedCapture, for vault: UUID) throws {
        try WatchQueue.store(sealed, in: delivery.queueFolder(vault))
    }
}

/// What one transferred file came to, for the app to acknowledge and to show.
public struct WatchReceipt: Equatable, Sendable {
    public var result: WatchIntakeResult
    public var meta: WatchTransferMeta?
}

/// Takes the files the watch transfers, copies each into a quarantine folder first (WatchConnectivity's file is only valid
/// during its callback), runs `WatchIntake`, and deletes the copy once delivery returned.
public struct WatchReceiver: Sendable {
    public let intake: WatchIntake
    /// `Application Support/Sempere/WatchQuarantine`.
    public let quarantine: URL

    init(delivery: CaptureDelivery, store: any CaptureProfileStore, received: WatchReceivedSet, quarantine: URL) {
        self.intake = WatchIntake(received: received, delivery: CaptureWatchDelivery(delivery: delivery, store: store))
        self.quarantine = quarantine
    }

    /// Takes a delivery adapter of any kind (tests, other platforms).
    public init(intake: WatchIntake, quarantine: URL) {
        self.intake = intake
        self.quarantine = quarantine
    }

    /// The app's receiver: the quick capture's delivery rules and profile store.
    @MainActor
    public init(quickCapture: QuickCapture, received: WatchReceivedSet = WatchReceiver.defaultReceivedSet(),
                quarantine: URL = WatchReceiver.defaultQuarantine) {
        self.init(delivery: quickCapture.delivery, store: quickCapture.store, received: received, quarantine: quarantine)
    }

    public nonisolated static var defaultQuarantine: URL { AppSupport.folder("WatchQuarantine") }
    public nonisolated static func defaultReceivedSet() -> WatchReceivedSet {
        WatchReceivedSet(url: AppSupport.sempere.appendingPathComponent("WatchReceived.json"))
    }

    /// Takes one file from `session(_:didReceive:)`. Copies it into the quarantine before anything else (the caller's file
    /// goes away when the callback returns), reads the metadata dictionary the watch sent, and delivers.
    /// Returns nil for a transfer whose metadata is not readable (dropped: there is no id to name). A refusal is in the
    /// receipt's result, with the metadata when there was any. Throws when delivery failed after the checks (nothing is
    /// acknowledged: the watch sends the file again).
    public func receive(file: URL, metadata: [String: Any]?) throws -> WatchReceipt? {
        guard let metadata, let meta = WatchTransferMeta(dictionary: metadata) else { return nil }
        let copy: URL
        do { copy = try quarantined(file, id: meta.id) } catch {
            return WatchReceipt(result: WatchIntakeResult(id: meta.id, outcome: .refused(.unreadable("\(error)"))), meta: meta)
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        return WatchReceipt(result: try intake.receive(file: copy, meta: meta), meta: meta)
    }

    /// The acknowledgement for what `receive` has done: the ids the watch may drop.
    public func ack(_ receipts: [WatchReceipt]) -> WatchAck {
        WatchAck(acked: receipts.filter(\.result.acknowledged).map(\.result.id))
    }

    /// What the phone holds, for the watch's activation (`WatchAck.have`).
    public func have() -> WatchAck { intake.have() }

    /// Removes what an earlier run left in the quarantine (a crash between the copy and the delivery): the watch has had no
    /// ack for it, and sends it again.
    public func sweepQuarantine() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: quarantine.path)) ?? [] {
            try? fm.removeItem(at: quarantine.appendingPathComponent(name))
        }
    }

    private func quarantined(_ file: URL, id: UUID) throws -> URL {
        let fm = FileManager.default
        try FileIO.createDirectory(quarantine)
        let copy = quarantine.appendingPathComponent(id.uuidString.lowercased() + "-" + UUID().uuidString.lowercased() + ".part")
        try fm.copyItem(at: file, to: copy)
        return copy
    }
}
