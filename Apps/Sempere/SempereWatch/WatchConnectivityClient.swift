import Foundation
import SempereCapture
@preconcurrency import WatchConnectivity

// The watch's end of WatchConnectivity (docs/design/1.1-watch.md §3.4, §3.6): provisioning arrives as an
// `applicationContext` (the age-encrypted profile, or a clear), acknowledgements as `userInfo`; the watch sends a request
// (`transferUserInfo`) and each sealed outbox file (`transferFile`). Provisioning is taken only from these callbacks.

/// A property list that crosses to the main actor (WatchConnectivity's dictionaries are not `Sendable`; they are value
/// property lists, copied here once).
private struct PropertyList: @unchecked Sendable { let value: [String: Any] }

@MainActor
final class WatchConnectivityClient: NSObject, WatchTransport {
    private weak var model: WatchModel?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private let delegateProxy = Proxy()

    func attach(_ model: WatchModel) {
        self.model = model
        delegateProxy.owner = self
    }

    func activate() {
        guard let session else { return }
        if session.delegate == nil { session.delegate = delegateProxy }
        if session.activationState != .activated { session.activate() } else { activated() }
    }

    var isActivated: Bool { session?.activationState == .activated }

    func requestProvisioning(recipient: String, seq: Int) -> Bool {
        guard let session, session.activationState == .activated else { return false }
        // One request in flight: a launch does not queue another while the system still holds the last.
        let key = WatchProvisioning.requestKey
        guard !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo[key] != nil }) else { return true }
        session.transferUserInfo(WatchProvisioning.dictionary(WatchProvisioning.Message.request(
            recipient: recipient, version: WatchProfilePayload.currentVersion, seq: seq)))
        return true
    }

    func transfer(file: URL, meta: WatchTransferMeta) -> Bool {
        guard let session, session.activationState == .activated else { return false }
        session.transferFile(file, metadata: meta.dictionary)
        return true
    }

    var pendingTransfers: Set<UUID> {
        guard let session else { return [] }
        return Set(session.outstandingFileTransfers.compactMap { ($0.file.metadata?["id"] as? String).flatMap(UUID.init(uuidString:)) })
    }

    /// Activation finished (or the session was already active): the context that arrived while the app was not running is read
    /// again, and unsent files are handed over.
    fileprivate func activated() {
        guard let session else { return }
        let context = session.receivedApplicationContext
        if !context.isEmpty { model?.receive(context) }
        model?.requestProvisioningIfNeeded()
        model?.flushOutbox(launch: true)
        model?.refreshScreen()
    }

    /// The delegate: callbacks arrive on a background queue.
    private final class Proxy: NSObject, WCSessionDelegate, @unchecked Sendable {
        nonisolated(unsafe) weak var owner: WatchConnectivityClient?

        func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
            guard activationState == .activated else { return }
            Task { @MainActor in self.owner?.activated() }
        }

        func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
            let box = PropertyList(value: applicationContext)
            Task { @MainActor in self.owner?.model?.receive(box.value) }
        }

        func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
            let box = PropertyList(value: userInfo)
            Task { @MainActor in
                if let ack = WatchAck(dictionary: box.value) { self.owner?.model?.receive(ack: ack) }
                if WatchProvisioning.message(box.value) != nil { self.owner?.model?.receive(box.value) }
            }
        }

        func sessionReachabilityDidChange(_ session: WCSession) {
            Task { @MainActor in self.owner?.model?.flushOutbox() }
        }

        func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
            let id = (fileTransfer.file.metadata?["id"] as? String).flatMap(UUID.init(uuidString:))
            let failed = error != nil
            guard let id else { return }
            Task { @MainActor in self.owner?.model?.transferFinished(id: id, failed: failed) }
        }
    }
}
