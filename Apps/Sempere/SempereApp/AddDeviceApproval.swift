import Foundation
import Observation
import Sempere
import SempereAppCore

/// Add Device's approving (review of #117, B1; the sheet's model, view glue: the approval is `AppModel.approveDevice`): the look every `joinLookInterval`, words typed before their request
/// arrived (approved by the look once it has), and the button. One approval at a time: `approve` claims `working`
/// before its first wait, and nothing approves once the sheet is closed (`cancel`), which every wait re-checks.
@MainActor
@Observable
final class AddDeviceApproval {
    /// Words typed (or a code scanned) before their request arrived.
    struct Pending: Equatable {
        var words: [String]?
        var qr: String?
    }

    /// The sheet's model (set when the sheet shows).
    @ObservationIgnored weak var model: AppModel?
    private(set) var lookout: JoinRequestLookout?
    private(set) var reply: JoinReply?
    private(set) var working = false
    private(set) var failure: String?
    private(set) var pending: Pending?
    /// The sheet was closed: no look and no approval from now on.
    private(set) var closed = false
    /// Approvals this sheet made (at most one).
    private(set) var approvals = 0

    init(model: AppModel? = nil) { self.model = model }

    /// May an approval or a look go on now.
    var active: Bool { !closed && reply == nil }

    /// The sheet went (Cancel, Done, a swipe): what is waiting is dropped, and an approval past its waits stops.
    func close() {
        closed = true
        pending = nil
    }

    /// Other words typed: the ones waiting for their request are dropped.
    func wordsChanged() { pending = nil }

    /// Approves `words` or `qr`; false when another approval is going, the sheet is closed or a reply is in.
    @discardableResult
    func approve(words: [String]?, qr: String?) async -> Bool {
        guard let model, active, !working else { return false }
        working = true   // before any wait: a second trigger meanwhile does nothing
        failure = nil
        defer { working = false }
        do {
            let r = try await model.approveDevice(words: words, qr: qr) { [weak self] in self?.closed == false }
            reply = r
            pending = nil
            approvals += 1
            return true
        } catch is CancellationError {
        } catch let error as DeviceJoinError where error == .requestNotArrived || error == .requestArriving {
            // Not here yet: approved when it arrives (`look`), unless other words are typed.
            if active { pending = Pending(words: words, qr: qr) }
            failure = DeviceChangeText.message(error)
        } catch {
            pending = nil
            failure = DeviceChangeText.message(error)
        }
        return false
    }

    /// Declines `request` (its Decline button): gone from the list at once, from the targets with the next run. Words
    /// waiting for it are dropped.
    @discardableResult
    func decline(_ request: JoinRequest) async -> Bool {
        guard let model, active, !working else { return false }
        working = true
        failure = nil
        defer { working = false }
        do {
            try await model.declineJoinRequest(request.fileName)
            lookout?.requests.removeAll { $0.fileName == request.fileName }
            if let p = pending, let words = p.words, JoinCodes.matches(words, request.commitment) { pending = nil }
            return true
        } catch {
            failure = DeviceChangeText.message(error)
            return false
        }
    }

    /// One look: a sync of every target and the copy's requests; then the waiting words, if their request is here.
    func look() async {
        guard let model, active, !working else { return }
        let found = await model.lookForJoinRequests()
        guard active else { return }
        lookout = found
        guard let p = pending, !working else { return }
        let here = await model.hasJoinRequest(words: p.words, qr: p.qr)
        guard here, active, !working, pending == p else { return }
        await approve(words: p.words, qr: p.qr)
    }
}
