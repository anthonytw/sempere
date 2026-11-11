#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import VaultTestSupport
import Testing

/// Every lock file under `root` that someone holds (an exclusive `flock` on another descriptor is refused).
func heldLockFiles(under root: URL) -> [String] {
    let names = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
    return names.filter { name in
        guard name.hasSuffix(".open") || name.hasSuffix(".write") || name.hasSuffix("lock") else { return false }
        let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}

extension AppModelSuites {
    /// TestFlight 1.1 (67) was killed (RunningBoard `0xdead10cc`) "frequently when not in use", 10 to 19 seconds after
    /// launches into the background (a WatchConnectivity delivery, a background task). The library scene was restored,
    /// reopened the last vault and its note: the vault was leased (the model read the app as active, because SwiftUI's
    /// `App.init` runs before `UIApplication` exists) and the restored editor's recognition wrote a revision, taking the
    /// write ledger's lock with no background time. Both locks are in the App Group container.
    @MainActor
    struct BackgroundLaunchLockTests {
        @MainActor
        struct Launch {
            let model: AppModel
            let library: VaultLibrary
            let id: UUID
            let root: URL
            let fake: FakeLockAssertions
            let installation: FileLockGuard.Installation
            let lifecycle: ManualAppLifecycle

            var leaseHeld: Bool { SuspensionLockTests.leaseHeld(library.vaultStore, id) }

            func close() async {
                model.close()
                await model.closingEditor?.value
                installation.cancel()
            }
        }

        /// A process launched into the background, as `App.init` sees it: not active (and, before `UIApplicationMain`,
        /// not known to be in the background either). Its store vault is opened and unlocked, as the restored library
        /// scene does (`RootView`'s reopen), with the device's write ledger beside the store and every lock under the
        /// fake's background time.
        static func launch(recognizer: (any PageRecognizing)? = nil) async throws -> Launch {
            let root = try BrowserTests.tempDir()
            let fake = FakeLockAssertions()
            let installation = FileLockGuard.install(fake, under: root)
            let library = VaultLibrary(storeURL: root.appendingPathComponent("recents.json"))
            let model = AppModel(deviceStateURL: root.appendingPathComponent("device.json"), recognizer: recognizer,
                                 recognitionDelay: .milliseconds(20))
            model.vaultStore = library.vaultStore
            model.writeStores = DeviceWriteStores(ledgerDirectory: root.appendingPathComponent("Ledger"),
                                                  setAside: SetAsideStore(directory: root.appendingPathComponent("SetAside")),
                                                  key: { Data(repeating: 7, count: 32) })
            model.releasesLocksInBackground = true
            model.backgroundTasks = FakeBackgroundTasks()
            let lifecycle = ManualAppLifecycle(isInBackground: false, isActive: false)
            model.observeAppLifecycle(lifecycle)
            do {
                let (source, key) = try await ModelFixture.vault()
                try await model.copyIn(picked: source, library: library)
                try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
                let id = try #require(library.storedVaults.first).vaultId
                return Launch(model: model, library: library, id: id, root: root, fake: fake, installation: installation,
                              lifecycle: lifecycle)
            } catch {
                model.close()
                installation.cancel()
                throw error
            }
        }

        /// Crash 2 (the idle main thread, nothing running): a launch that was never active holds no lease, and the
        /// first activation (no `willEnterForeground` comes before it) takes it.
        @Test func aLaunchNeverActiveHoldsNoLeaseUntilTheAppIsFirstActive() async throws {
            let launch = try await Self.launch()
            #expect(launch.model.locksSuspended, "not active at launch: the locks wait")
            #expect(launch.model.phase == .unlocked)
            #expect(!launch.leaseHeld, "nothing is held while the process can be suspended")
            #expect(heldLockFiles(under: launch.root).isEmpty)

            launch.lifecycle.send(.didBecomeActive)
            #expect(!launch.model.locksSuspended)
            #expect(launch.leaseHeld, "on screen: the vault is leased")
            #expect(launch.fake.outstanding == 1, "the lease holds an assertion of its own")

            // Leaving lets it go again (the build 8 fix), with its assertion.
            launch.lifecycle.send(.didEnterBackground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { !launch.leaseHeld && launch.fake.outstanding == 0 })
            await launch.close()
        }

        /// Crash 1: the restored editor recognized in a background launch. It no longer does: nobody sees that launch,
        /// so no revision is written and no failure is left for later. The first activation runs the pass, whose
        /// revision and ledger entry are written under background time (each lock its own assertion, ended after).
        @Test func aRestoredEditorInABackgroundLaunchRecognizesOnlyOnceTheAppIsActive() async throws {
            let recognizer = FakeRecognizer()
            let launch = try await Self.launch(recognizer: recognizer)
            let model = launch.model
            let revisions = try #require(model.vault).revisionNames(of: AppModelTests.lecture).count
            model.selectedNoteID = AppModelTests.lecture
            await model.showSelectedNote()
            let editor = try #require(model.editor)
            try await Task.sleep(for: .milliseconds(300))   // well past the recognition delay (20 ms)
            #expect(recognizer.calls.isEmpty, "held while the locks are let go")
            #expect(editor.recognitionsWritten == 0 && editor.recognitionFailure == nil)
            #expect(try #require(model.vault).revisionNames(of: AppModelTests.lecture).count == revisions)
            #expect(heldLockFiles(under: launch.root).isEmpty)

            let before = launch.fake.begun
            launch.lifecycle.send(.didBecomeActive)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { editor.recognitionsWritten > 0 }, "the pass on the return")
            #expect(recognizer.calls.count > 0)
            #expect(try #require(model.vault).revisionNames(of: AppModelTests.lecture).count > revisions)
            #expect(launch.fake.begun > before + 1, "the lease and the write ledger's lock, each under background time")
            #expect(await TS.waitUntil(timeout: .seconds(30)) { launch.fake.outstanding == 1 }, "only the lease's is left")
            #expect(heldLockFiles(under: launch.root).allSatisfy { $0.hasSuffix(".open") })
            await launch.close()
        }

        /// The system giving no time (the app about to be suspended) for a recognition's write: refused before any
        /// lock is taken, the failure is reported, nothing is written, and nothing but the lease is held.
        @Test func withoutBackgroundTimeTheRecognitionWriteIsRefusedAndNothingIsHeld() async throws {
            let gate = Gate()
            await gate.close()
            let launch = try await Self.launch(recognizer: FakeRecognizer(gate: gate))
            let model = launch.model
            launch.lifecycle.send(.didBecomeActive)
            let revisions = try #require(model.vault).revisionNames(of: AppModelTests.lecture).count
            model.selectedNoteID = AppModelTests.lecture
            await model.showSelectedNote()
            let editor = try #require(model.editor)
            await gate.waitForArrivals(1)
            launch.fake.grant = false
            await gate.open()
            #expect(await TS.waitUntil(timeout: .seconds(30)) { editor.recognitionFailure != nil })
            if case .save = editor.recognitionFailure {} else { Issue.record("a save failure: \(String(describing: editor.recognitionFailure))") }
            #expect(editor.recognitionsWritten == 0)
            #expect(launch.fake.refused > 0)
            #expect(launch.fake.outstanding == 1, "the lease's only")
            #expect(heldLockFiles(under: launch.root).allSatisfy { $0.hasSuffix(".open") })
            #expect(try #require(model.vault).revisionNames(of: AppModelTests.lecture).count == revisions)
            launch.fake.grant = true
            await launch.close()
        }

        /// The app leaves the screen during a pass: the pass stops without writing, and the return reads again.
        @Test func aPassInFlightWhenTheAppLeavesWritesNothingAndRunsAgainOnTheReturn() async throws {
            let gate = Gate()
            await gate.close()
            let launch = try await Self.launch(recognizer: FakeRecognizer(gate: gate))
            let model = launch.model
            launch.lifecycle.send(.didBecomeActive)
            let revisions = try #require(model.vault).revisionNames(of: AppModelTests.lecture).count
            model.selectedNoteID = AppModelTests.lecture
            await model.showSelectedNote()
            let editor = try #require(model.editor)
            await gate.waitForArrivals(1)
            launch.lifecycle.send(.didEnterBackground)
            #expect(model.locksSuspended)
            await gate.open()
            try await Task.sleep(for: .milliseconds(300))
            #expect(editor.recognitionsWritten == 0 && editor.recognitionFailure == nil, "stopped, nothing written")
            #expect(try #require(model.vault).revisionNames(of: AppModelTests.lecture).count == revisions)
            launch.lifecycle.send(.willEnterForeground)
            #expect(await TS.waitUntil(timeout: .seconds(30)) { editor.recognitionsWritten > 0 }, "read again on the return")
            await launch.close()
        }
    }
}

/// The Watch's notes in a launch by WatchConnectivity (`session(_:didReceive:)` on WatchConnectivity's queue, the app
/// never on screen): the ledger entry is written under background time, and with none the note is queued (no lock)
/// and still acknowledged, so the watch drops it and nothing is lost.
struct WatchBackgroundLaunchLockTests {
    static func receiver(_ rig: WatchReceiverTests.Rig) -> WatchReceiver {
        let ledgers = rig.dir.appendingPathComponent("Ledger", isDirectory: true)
        let delivery = CaptureDelivery(queueRoot: rig.dir.appendingPathComponent("queue"), vaultStore: VaultStore(root: rig.storeRoot),
                                       bookmarks: PathBookmarks(),
                                       ledger: { FileWriteLedger(directory: ledgers, vaultId: $0, keyBytes: { Data(repeating: 7, count: 32) }) },
                                       delivered: { _ in })
        return WatchReceiver(delivery: delivery, store: rig.profileStore, received: WatchReceivedSet(url: nil),
                             quarantine: rig.dir.appendingPathComponent("quarantine"), held: rig.held, enabled: { true })
    }

    @Test func aWatchDeliveryLocksOnlyUnderBackgroundTimeAndQueuesWithoutIt() throws {
        let rig = try WatchReceiverTests.rig()
        let fake = FakeLockAssertions()
        let installation = FileLockGuard.install(fake, under: rig.dir)
        defer { installation.cancel() }
        let receiver = Self.receiver(rig)
        let vault = rig.current.stored.profile.vaultId

        let first = try WatchReceiverTests.transfer(rig.current.stored.profile, in: rig)
        let placed = try #require(try receiver.receive(file: first.file, metadata: first.metadata))
        #expect(placed.result.outcome == .placed(.vault))
        #expect(WatchReceiverTests.inbox(rig.current.url) == [first.sealed.name])
        #expect(fake.begun > 0, "the ledger's lock was taken under background time")
        #expect(fake.outstanding == 0)
        #expect(heldLockFiles(under: rig.dir).isEmpty)

        // The system gives no time: no lock, the note waits in the queue, and the watch may drop it.
        fake.grant = false
        let second = try WatchReceiverTests.transfer(rig.current.stored.profile, in: rig)
        let queued = try #require(try receiver.receive(file: second.file, metadata: second.metadata))
        #expect(queued.result.outcome == .placed(.queued))
        #expect(queued.result.acknowledged)
        #expect(WatchReceiverTests.inbox(rig.current.url) == [first.sealed.name])
        #expect(QuickCaptureLogicTests.names(WatchQueue.folder(rig.dir.appendingPathComponent("queue"), vault: vault))
            .contains(second.sealed.name))
        #expect(fake.refused > 0)
        #expect(fake.outstanding == 0)
        #expect(heldLockFiles(under: rig.dir).isEmpty)
    }
}
