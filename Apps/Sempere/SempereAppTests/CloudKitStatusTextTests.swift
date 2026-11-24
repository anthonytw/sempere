import Foundation
import SempereAppCore
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// The words of an iCloud (CloudKit) target's status (docs/design/1.4-cloudkit.md §4, §9): every state the design names has a
/// line, the bar shows a problem only for a definite one, a quiet failure shows nothing, and "synced" never waits for iCloud.
@MainActor
struct CloudKitStatusTextTests {
    private func status(_ problems: [WebDAVSyncProblem] = [], unconfirmed: Int = 0, last: Date? = nil) -> SyncStatus {
        SyncStatus(syncing: false, problems: problems, unconfirmed: unconfirmed, arriving: 0, twoWay: true, lastSuccess: last, cloudKit: true)
    }

    @Test func everyProblemHasItsOwnLineAndTheRightButton() {
        let all: [CloudProblem] = [.storageFull, .zoneGone, .zoneDeletedByUser, .signedOut, .restricted, .otherAccount, .updateNeeded,
                                   .notAccepted(since: Date(timeIntervalSince1970: 1_700_000_000)), .notAccepted(since: nil)]
        var lines = Set<String>()
        for p in all {
            let s = status([.cloud(p)])
            #expect(s.needsAttention, "\(p) is a problem the bar shows")
            #expect(s.headline == p.text)
            #expect(!p.text.isEmpty)
            lines.insert(p.text)
        }
        #expect(lines.count == all.count)
        #expect(CloudProblem.signedOut.remedy == .openSettings)
        #expect(CloudProblem.zoneGone.remedy == .uploadAgain && CloudProblem.zoneDeletedByUser.remedy == .uploadAgain)
        #expect(CloudProblem.otherAccount.remedy == .useThisAccount)
        #expect(CloudProblem.storageFull.remedy == nil)
        #expect(CloudProblem.storageFull.text == CloudProblem.storageFull.message, "the app and the CLI say the same words in English")
        #expect(CloudProblem.otherAccount.text == CloudProblem.otherAccount.message)
    }

    @Test func syncedOfflineAndQuietStatesNeverCryProblem() {
        let synced = status(last: Date().addingTimeInterval(-120))
        #expect(synced.kind == .synced && !synced.needsAttention)
        #expect(synced.headline.hasPrefix("Synced with iCloud"))
        #expect(!synced.headline.localizedCaseInsensitiveContains("waiting"))
        #expect(status().headline == "Synced with iCloud")
        #expect(status([.offline], unconfirmed: 3).kind == .offline)
        #expect(!status([.offline], unconfirmed: 3).needsAttention)
        #expect(status([.offline]).headline.contains("iCloud"))
        // A quiet failure leaves no problem at all (the session lists it in Vault Details).
        #expect(status([]).kind == .synced)
        #expect(status(unconfirmed: 4).headline.contains("4"))
        #expect(SyncStatus(syncing: true, problems: [], unconfirmed: 0, arriving: 0, twoWay: true, lastSuccess: nil, cloudKit: true).headline
                == "Syncing with iCloud…")
    }

    @Test func errorsMapToProblemsLikeTheDesignTable() {
        #expect(WebDAVSyncProblem.from(error: CloudRecordError.otherAccount) == .cloud(.otherAccount))
        #expect(WebDAVSyncProblem.from(error: CloudRecordError.zoneGone(userDeleted: true)) == .cloud(.zoneDeletedByUser))
        #expect(WebDAVSyncProblem.from(error: CloudRecordError.account(.noAccount)) == .cloud(.signedOut))
        #expect(WebDAVSyncProblem.from(error: CloudRecordError.account(.managedAccountRestricted)) == .cloud(.restricted))
        #expect(WebDAVSyncProblem.from(error: CloudStoreError(.quotaExceeded)) == .cloud(.storageFull))
        #expect(WebDAVSyncProblem.from(error: CloudStoreError(.networkUnavailable)) == .offline)
        #expect(WebDAVSyncProblem.from(error: CloudRecordError.newerSchema(path: nil)) == .cloud(.updateNeeded))
    }

    @Test func theCloudKitTargetProblemsAreWorded() {
        let problems: [CloudKitTargetProblem] = [.unavailable, .account(.noAccount), .account(.restricted), .account(.temporarilyUnavailable),
                                                 .notAStoreVault, .duplicate, .noSuchVault, .other("x")]
        for p in problems { #expect(!p.text.isEmpty) }
    }
}
