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

    func setHeld(_ notes: [HeldCapture]) {
        held = notes
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
            await MainActor.run { self?.status.setHeld(notes) }
        }
    }

    /// "Add to inbox": every held note that can be added, off the main actor. Returns how many could not be (a vault that
    /// cannot be written now).
    func addHeldNotes() async -> Int {
        guard let receiver = lock.withLock({ receiver }) else { return 0 }
        let failed = await Task.detached { () -> Int in
            var failed = 0
            for note in receiver.heldNotes() where note.canAdd {
                do { try receiver.addHeld(note) } catch { failed += 1 }
            }
            return failed
        }.value
        refreshHeld()
        return failed
    }

    /// "Delete": every held note.
    func deleteHeldNotes() {
        guard let receiver = lock.withLock({ receiver }) else { return }
        Task.detached { [weak self] in
            for note in receiver.heldNotes() { receiver.deleteHeld(note) }
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
