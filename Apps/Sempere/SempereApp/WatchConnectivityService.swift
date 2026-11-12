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
    /// Notes with an add or a delete under way: their buttons stay off, so a second tap cannot start a second add.
    private(set) var busy = false

    func setHeld(_ notes: [HeldCapture], addable: Set<UUID>) {
        held = notes
        addableIds = addable
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
        }
        quickCapture.profileChanged = { [weak self] in self?.provisionIfNeeded() }
        refreshHeld()
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
            let addable = Set(notes.filter { receiver.canAddNow($0) }.map(\.id))
            await MainActor.run { self?.status.setHeld(notes, addable: addable) }
        }
    }

    /// "Add to inbox" for one held note, after the user confirmed it, off the main actor. False when it could not be added
    /// now (a vault that cannot be written, a key this device never held).
    func addHeldNote(_ note: HeldCapture) async -> Bool {
        guard let receiver = lock.withLock({ receiver }) else { return false }
        guard await MainActor.run(body: { status.begin() }) else { return false }
        let added = await Task.detached { () -> Bool in
            guard receiver.canAddNow(note) else { return false }
            return (try? receiver.addHeld(note)) != nil
        }.value
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
            await MainActor.run { self?.status.end() }
            self?.refreshHeld()
        }
    }

    /// "Delete All": every held note.
    func deleteHeldNotes() {
        guard let receiver = lock.withLock({ receiver }) else { return }
        Task.detached { [weak self] in
            guard await MainActor.run(body: { self?.status.begin() ?? false }) else { return }
            for note in receiver.heldNotes() { receiver.deleteHeld(note) }
            await MainActor.run { self?.status.end() }
            self?.refreshHeld()
        }
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
        // What the phone holds, so a watch that lost its acknowledgements (a reinstall, a restore) can drop those files.
        if let receiver = lock.withLock({ receiver }) {
            let have = receiver.have()
            if !have.isEmpty { session.transferUserInfo(have.dictionary) }
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
        guard case .request(let recipient, _, let seq)? = WatchProvisioning.message(userInfo) else { return }
        // The watch's own counter is a floor for the phone's: a counter lost on the phone can never make the watch ignore it.
        do { try provisioner.watchRequested(recipient: recipient, seq: seq) } catch { return }
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
