import Foundation
import Observation
import Sempere

/// Add Device's approving (review of #117, B1; the sheet's model, view glue: the approval is `AppModel.approveDevice`): the look every `joinLookInterval`, words typed before their request
/// arrived (approved by the look once it has), and the button. One approval at a time: `approve` claims `working`
/// before its first wait, and nothing approves once the sheet is closed (`cancel`), which every wait re-checks.
@MainActor
@Observable
public final class AddDeviceApprovalCore<Host: AppModelHost> {
    /// Words typed (or a code scanned) before their request arrived.
    public struct Pending: Equatable {
        public var words: [String]?
        public var qr: String?

        public init(words: [String]?, qr: String?) {
            self.words = words
            self.qr = qr
        }
    }

    /// The sheet's model (set when the sheet shows).
    @ObservationIgnored public weak var model: AppModelCore<Host>?
    public private(set) var lookout: JoinRequestLookout?
    public private(set) var reply: JoinReply?
    public private(set) var working = false
    /// What the last approval, decline or look failed with (the sheet words it: `AddDeviceApproval.failure`).
    public private(set) var failedWith: (any Error)?
    public private(set) var pending: Pending?
    /// The sheet was closed: no look and no approval from now on.
    public private(set) var closed = false
    /// Approvals this sheet made (at most one).
    public private(set) var approvals = 0

    public init(model: AppModelCore<Host>? = nil) { self.model = model }

    /// May an approval or a look go on now.
    public var active: Bool { !closed && reply == nil }

    /// The sheet went (Cancel, Done, a swipe): what is waiting is dropped, an approval past its waits stops, and the
    /// nearby link stops advertising.
    public func close() {
        closed = true
        pending = nil
        model?.stopNearbyApproving()
    }

    /// The sheet showed: devices nearby can send their requests (docs/design/nearby-join.md) while it is open, the reply
    /// too (a device approved already gets its approval over the link at once).
    public func startNearby() {
        guard !closed else { return }
        model?.startNearbyApproving()
    }

    /// The list again from the copy, without a sync (a request arrived nearby, `AppModelCore.nearbyArrivals`); then the
    /// waiting words, if their request is here now.
    public func refresh() async {
        guard let model, active else { return }
        let requests = stableOrder(await model.pendingJoinRequests())
        guard active else { return }
        lookout = JoinRequestLookout(requests: requests, arriving: lookout?.arriving ?? false, checked: lookout?.checked ?? Date())
        guard let p = pending, !working else { return }
        let here = await model.hasJoinRequest(words: p.words, qr: p.qr)
        guard here, active, !working, pending == p else { return }
        await approve(words: p.words, qr: p.qr)
    }

    /// `requests` in the order the list already shows them, new ones last (docs/design/1.2-join-confirm.md §3.5): a request
    /// that arrives while the user compares never moves a row that has been on screen under their finger.
    func stableOrder(_ requests: [JoinRequest]) -> [JoinRequest] {
        let shown = lookout?.requests.map(\.commitment) ?? []
        let known = shown.compactMap { c in requests.first { $0.commitment == c } }
        return known + requests.filter { r in !shown.contains(r.commitment) }
    }

    /// Other words typed: the ones waiting for their request are dropped.
    public func wordsChanged() { pending = nil }

    /// Approves `words` or `qr`; false when another approval is going, the sheet is closed or a reply is in.
    @discardableResult
    public func approve(words: [String]?, qr: String?) async -> Bool {
        guard let model, active, !working else { return false }
        working = true   // before any wait: a second trigger meanwhile does nothing
        failedWith = nil
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
            failedWith = error
        } catch {
            pending = nil
            failedWith = error
        }
        return false
    }

    /// Approves a request the sheet lists (a row's "They Match", docs/design/1.2-join-confirm.md §3.1), by its commitment;
    /// false when another approval is going, the sheet is closed or a reply is in. A failure is in `failedWith`.
    @discardableResult
    public func approve(request: JoinRequest) async -> Bool {
        guard let model, active, !working else { return false }
        working = true   // before any wait: a second tap meanwhile does nothing
        failedWith = nil
        defer { working = false }
        do {
            let r = try await model.approveDevice(request: request) { [weak self] in self?.closed == false }
            reply = r
            pending = nil
            approvals += 1
            return true
        } catch is CancellationError {
        } catch {
            failedWith = error
        }
        return false
    }

    /// Declines `request` (its Decline button): gone from the list at once, from the targets with the next run. Words
    /// waiting for it are dropped.
    @discardableResult
    public func decline(_ request: JoinRequest) async -> Bool {
        guard let model, active, !working else { return false }
        working = true
        failedWith = nil
        defer { working = false }
        do {
            try await model.declineJoinRequest(request)
            lookout?.requests.removeAll { $0.commitment == request.commitment }
            if let p = pending, let words = p.words, JoinCodes.matches(words, request.commitment) { pending = nil }
            return true
        } catch {
            failedWith = error
            return false
        }
    }

    /// One look: a sync of every target and the copy's requests; then the waiting words, if their request is here.
    public func look() async {
        guard let model, active, !working else { return }
        var found = await model.lookForJoinRequests()
        guard active else { return }
        found.requests = stableOrder(found.requests)
        lookout = found
        guard let p = pending, !working else { return }
        let here = await model.hasJoinRequest(words: p.words, qr: p.qr)
        guard here, active, !working, pending == p else { return }
        await approve(words: p.words, qr: p.qr)
    }
}
