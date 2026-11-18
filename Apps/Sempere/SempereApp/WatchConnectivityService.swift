import Foundation
import Observation
import Sempere
import SempereAppCore
@preconcurrency import WatchConnectivity

// The iPhone's end of WatchConnectivity (docs/design/1.1-watch.md §3.4, §3.6): the "Use on Apple Watch" provisioning
// (`WatchProvisioner` decides, this sends) and the receiver of the notes the watch records (`WatchReceiver`, called from
// `session(_:didReceive:)`, where the file is only valid during the callback: the receiver copies it first). iPhone only:
// there is no WatchConnectivity on a Mac. Nothing here knows a vault key: the phone gives the watch the capture profile
// (public recipients and the capture key, which cannot read anything), age-encrypted to the watch's own key.

/// What Settings shows about the watch, observed.
@MainActor
@Observable
final class WatchLinkStatus {
    private(set) var isSupported = false
    private(set) var isPaired = false
    private(set) var isWatchAppInstalled = false
    /// Bumped when the provisioner's or the receiver's state changed, so the settings re-read them.
    private(set) var revision = 0
    /// The held Watch files, read off the main actor and cached here (Settings reads this, never the disk).
    private(set) var held: [HeldCapture] = []
    /// Which of them "Add to inbox" can take now (the admission check `addHeld` makes, not the stored reason).
    private(set) var addableIds: Set<UUID> = []
    /// Why each is held now (`WatchReceiver.currentReason`, not the stored reason, which can be stale).
    private(set) var reasons: [UUID: WatchHeldReason] = [:]
    /// Which of them need the user's check before an Add (`WatchReceiver.needsCheck`).
    private(set) var checkIds: Set<UUID> = []
    /// Notes with an add or a delete under way: their buttons stay off, so a second tap cannot start a second add.
    private(set) var busy = false

    func setHeld(_ notes: [HeldCapture], addable: Set<UUID>, reasons: [UUID: WatchHeldReason], check: Set<UUID>) {
        held = notes
        addableIds = addable
        self.reasons = reasons
        checkIds = check
        revision += 1
    }

    /// One test-and-set: false when an add or a delete is under way already.
    func begin() -> Bool {
        guard !busy else { return false }
        busy = true
        revision += 1
        return true
    }

    func end() {
        busy = false
        revision += 1
    }

    func update(from session: WCSession?) {
        isSupported = session != nil
        isPaired = session?.isPaired ?? false
        isWatchAppInstalled = session?.isWatchAppInstalled ?? false
        revision += 1
    }

    func touch() { revision += 1 }
}

final class WatchConnectivityService: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConnectivityService()

    let provisioner = WatchProvisioner()
    @MainActor let status = WatchLinkStatus()

    private let lock = NSLock()
    /// Held across `nextMessage` and `updateApplicationContext`: this runs from the main actor and from WatchConnectivity's
    /// queue, and the newer message must be the one left in the persisted context.
    private let sendLock = NSLock()
    private var receiver: WatchReceiver?
    private var profileStore: (any CaptureProfileStore)?
    /// What admission depended on at the last `admitReadyHeldNotes` pass.
    private var lastAdmitKey: String?
    /// The in-app vault store (the vaults this phone holds), for `admitReadyHeldNotes`.
    private var vaultStore: VaultStore?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// At launch, after the quick capture has its vault store and ledger (the receiver delivers through them). A launch by
    /// WatchConnectivity (the watch sent something while the app was not running) comes through here too.
    @MainActor
    func start(quickCapture: QuickCapture) {
        #if targetEnvironment(macCatalyst)
        return
        #else
        // Admitted only while "Use on Apple Watch" is on; anything else is held (WatchIntake).
        let provisioner = self.provisioner
        let receiver = WatchReceiver(quickCapture: quickCapture, enabled: { provisioner.enabled })
        receiver.sweepQuarantine()
        lock.withLock {
            self.receiver = receiver
            self.profileStore = quickCapture.store
            self.vaultStore = quickCapture.vaultStore
        }
        quickCapture.profileChanged = { [weak self] in
            self?.provisionIfNeeded()
            self?.admitReadyHeldNotes()   // notes held only because this phone was behind go in now
        }
        admitReadyHeldNotes()
        guard let session else { return }
        session.delegate = self
        session.activate()
        status.update(from: session)
        #endif
    }

    /// Settings' count: Watch notes that wait for a vault this device has not opened.
    @MainActor
    func waitingForOtherVaults(_ quickCapture: QuickCapture) -> Int { quickCapture.queuedForOtherVaults() }

    // MARK: Held notes (Settings)

    /// The Watch files that were not admitted (the toggle was off, or the key changed since), oldest first.
    func heldNotes() -> [HeldCapture] { lock.withLock { receiver }?.heldNotes() ?? [] }

    /// Reads the held list off the main actor and hands it to Settings.
    func refreshHeld() {
        guard let receiver = lock.withLock({ receiver }) else { return }
        Task.detached { [weak self] in
            let notes = receiver.heldNotes()
            // One verdict per note (each reads the profile and the vault folder's epoch).
            let judged = notes.map { ($0.id, receiver.judge($0)) }
            let addable = Set(judged.filter { $0.1.canAdd }.map(\.0))
            let reasons = Dictionary(uniqueKeysWithValues: judged.map { ($0.0, $0.1.reason) })
            let check = Set(judged.filter { $0.1.needsCheck }.map(\.0))
            await MainActor.run { self?.status.setHeld(notes, addable: addable, reasons: reasons, check: check) }
        }
    }

    /// Places, off the main actor, the held notes that would be admitted now (`WatchReceiver.admitReady`: a refresh to the
    /// vault's epoch, a lifted suspension), then re-reads the list. Notes held for the user's decision stay.
    /// Runs only when what decides admission changed since the last pass (the profile's vault, epoch and suspension, the
    /// toggle, and the vaults on this phone: an `unknownVault` note goes in at the first activation after its vault was
    /// added): every activation calls `profileChanged`, and a pass reads every held note's vault folder.
    func admitReadyHeldNotes() {
        guard let receiver = lock.withLock({ receiver }), let store = lock.withLock({ profileStore }) else { return }
        let vaults = lock.withLock { vaultStore }
        let provisioner = self.provisioner
        Task.detached { [weak self] in
            guard let self else { return }
            // Unreadable before the first unlock: nothing decided, tried at the next change.
            let stored: StoredCaptureProfile?
            do { stored = try store.load() } catch { return }
            guard !receiver.heldNotes().isEmpty else { return }
            let here = (vaults?.list().map { $0.vaultId.uuidString } ?? []).sorted().joined(separator: ",")
            let key = [stored?.profile.vaultId.uuidString ?? "-", "\(stored?.profile.epoch ?? -1)", stored?.profile.epochId ?? "-",
                       "\(stored?.suspended == true)", "\(provisioner.enabled)", here].joined(separator: " ")
            let changed = self.lock.withLock { () -> Bool in
                guard self.lastAdmitKey != key else { return false }
                self.lastAdmitKey = key
                return true
            }
            guard changed else { return }
            self.sendReleased(receiver.admitReady())
            self.refreshHeld()
        }
    }

    /// "Add to inbox" for one held note, after the user confirmed it, off the main actor. False when it could not be added
    /// now (a vault that cannot be written, a key this device never held).
    func addHeldNote(_ note: HeldCapture) async -> Bool {
        guard let receiver = lock.withLock({ receiver }) else { return false }
        guard await MainActor.run(body: { status.begin() }) else { return false }
        let added = await Task.detached { () -> Bool in
            guard receiver.canAddNow(note) else { return false }
            // nil: no longer held, because an earlier add (or `admitReady`) placed it: done, not a failure.
            do { _ = try receiver.addHeld(note); return true } catch { return false }
        }.value
        if added { sendReleased([note.id]) }
        await MainActor.run { status.end() }
        refreshHeld()
        return added
    }

    /// "Delete" for one held note.
    func deleteHeldNote(_ note: HeldCapture) {
        guard let receiver = lock.withLock({ receiver }) else { return }
        Task.detached { [weak self] in
            guard await MainActor.run(body: { self?.status.begin() ?? false }) else { return }
            receiver.deleteHeld(note)
            self?.sendReleased([note.id])
            await MainActor.run { self?.status.end() }
            self?.refreshHeld()
        }
    }

    /// "Delete All": every held note.
    func deleteHeldNotes() {
        guard let receiver = lock.withLock({ receiver }) else { return }
        Task.detached { [weak self] in
            guard await MainActor.run(body: { self?.status.begin() ?? false }) else { return }
            let notes = receiver.heldNotes()
            for note in notes { receiver.deleteHeld(note) }
            self?.sendReleased(notes.map(\.id))
            await MainActor.run { self?.status.end() }
            self?.refreshHeld()
        }
    }

    /// Held notes that left the held store (added to a vault, deleted): the watch kept its copies until now (`WatchAck.held`).
    /// Sent as `acked`, which every watch version drops on. Queued, so it survives the watch being away; one the watch never
    /// gets is repaired at the next activation (the watch re-sends a note the phone no longer lists as held, and the phone
    /// acknowledges the repeat as a duplicate).
    func sendReleased(_ ids: [UUID]) {
        guard !ids.isEmpty, let session, session.activationState == .activated,
              let receiver = lock.withLock({ receiver }) else { return }
        session.transferUserInfo(receiver.released(ids).dictionary)
    }

    // MARK: Provisioning

    /// Gives the watch what it needs now (the profile, or a clear), if anything: at activation, when the toggle or the
    /// profile changes, and when the watch asks. Never acts on a profile it cannot read (before the first unlock the
    /// Keychain refuses; that is not "turned off").
    func provisionIfNeeded() {
        guard let session, session.activationState == .activated, let store = lock.withLock({ profileStore }) else { return }
        let stored: StoredCaptureProfile?
        do { stored = try store.load() } catch { return }
        // Nothing to give a watch that is not there; the state is kept for when it is.
        guard session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try sendLock.withLock {
                guard let message = try provisioner.nextMessage(stored: stored) else { return }
                do { try session.updateApplicationContext(WatchProvisioning.dictionary(message)) } catch {
                    provisioner.sendFailed()
                }
            }
        } catch {
            // The counter could not be saved (or is spent): nothing was sent, and the next change tries again.
        }
        Task { @MainActor in self.status.touch() }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.status.update(from: session) }
        provisionIfNeeded()
        // What the phone holds, so a watch that lost its acknowledgements (a reinstall, a restore) can drop those files, and
        // the notes it holds in no vault (`held`, complete), so a watch that kept one this phone lost (its app was
        // reinstalled) sends it again. Always sent: an empty list is what tells the watch the phone lost them. An earlier
        // such message still queued is out of date: cancelled, so the queue never grows.
        if let receiver = lock.withLock({ receiver }) {
            let have = receiver.have()
            if !have.isEmpty {
                for transfer in session.outstandingUserInfoTransfers where transfer.userInfo["heldAll"] != nil { transfer.cancel() }
                session.transferUserInfo(have.dictionary)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A new watch was paired: the session goes on with it.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.status.update(from: session) }
        provisionIfNeeded()
    }

    /// The watch's request for a profile (`transferUserInfo`). Taken only from this callback: WatchConnectivity says it is
    /// the paired watch; the recipient in it is public (docs/security.md: no sender authentication beyond that).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard case .request(let recipient, _, let seq, let holds)? = WatchProvisioning.message(userInfo) else { return }
        // The watch's own counter is a floor for the phone's: a counter lost on the phone can never make the watch ignore it.
        do { try provisioner.watchRequested(recipient: recipient, seq: seq, holds: holds) } catch { return }
        provisionIfNeeded()
    }

    /// A sealed note from the watch: delivered by its own vault, then acknowledged (`transferUserInfo`, queued, so it
    /// survives either side being away).
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let receiver = lock.withLock({ receiver }) else { return }
        do {
            guard let receipt = try receiver.receive(file: file.fileURL, metadata: file.metadata) else { return }
            if receipt.result.acknowledged {
                provisioner.noteReceived(at: Date())
                let ack = receiver.ack([receipt])
                if !ack.isEmpty { session.transferUserInfo(ack.dictionary) }
            }
        } catch {
            // Delivery failed after the checks (the vault cannot be written now): nothing is acknowledged, and the watch sends
            // the file again.
        }
        Task { @MainActor in self.status.touch() }
        refreshHeld()
    }
}
