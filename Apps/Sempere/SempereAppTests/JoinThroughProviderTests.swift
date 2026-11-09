import Foundation
import Sempere
import SempereAppCore
import SempereSync
import Testing
@testable import SempereApp

/// Where a join stands, in Add Device's and the join screen's words. The sheet's model (`AddDeviceApprovalCore`) over a
/// join through a folder target that a provider holds is `AddDeviceApprovalTests` in `SempereAppCoreTests`; the join
/// itself through the model is `JoinThroughProviderTests` there.
@MainActor
struct JoinThroughProviderTests {
    /// The model's values are `JoinThroughProviderTests` in `SempereAppCoreTests`.
    @Test func theJoinWordsSayWhereTheRequestIs() {
        #expect(AddDeviceText.looking(JoinRequestLookout(requests: [], arriving: true, checked: Date())).contains("on its way"))
        #expect(AddDeviceText.looking(JoinRequestLookout(requests: [], arriving: false, checked: Date())).contains("Still looking"))
        #expect(DeviceChangeText.message(DeviceJoinError.requestNotArrived).contains("iCloud Drive"))
        // Without any target nothing can arrive: the message says nothing of syncs (review of #117, N1).
        #expect(!DeviceChangeText.message(DeviceJoinError.noMatchingRequest).contains("iCloud"))
        #expect(JoinDelivery.waitingForUpload(iCloud: true).text.contains("iCloud Drive"))
    }
}
