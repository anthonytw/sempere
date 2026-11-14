import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Make a Copy… through the model (`AppModel+MakeCopy`, docs/design/1.2-make-a-copy.md): the open vault, of each
    /// read-only cause or writable, becomes a new store vault with its own keys; progress, cancel and a vault that
    /// closes mid-copy. The copy itself is tested in `VaultCopierTests`.
    @Suite(.serialized)
    @MainActor
    struct MakeCopyTests {
        static let lecture = ModelFixture.lecture

        static func library() -> VaultLibrary {
            let dir = TestTemp.root.appendingPathComponent("copy-lib-\(UUID().uuidString)", isDirectory: true)
            return VaultLibrary(storeURL: dir.appendingPathComponent("recents.json"))
        }

        static func request(_ name: String = "Copy") -> NewVaultRequest {
            var r = NewVaultRequest(name: name, keySource: .generate, passphrase: nil)
            r.workFactor = 10
            return r
        }

        /// The sample vault open and unlocked with its device key, `trust` holding this device's record when given.
        static func opened(trust: (any EpochTrustStore)? = nil) async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), trust: trust,
                                 services: .headless())
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            return model
        }

        @Test func aWritableVaultIsCopiedAndTheCopyOpens() async throws {
            let model = try await Self.opened()
            defer { model.close() }
            let library = Self.library()
            #expect(model.canMakeCopy)
            let made = try await model.makeCopy(Self.request("Fork"), includeDeleted: false, library: library)
            #expect(made.report.notes == 1)
            #expect(made.report.deletedSkipped == 1)
            #expect(made.report.isComplete)
            #expect(made.created.secretKey != nil, "the copy's own recovery key is handed over once")
            #expect(made.entry.url == made.created.url)
            #expect(library.vaultStore.entry(id: made.created.vaultID) != nil)
            #expect(made.created.vaultID != model.vault?.vaultId)
            #expect(!model.isMakingCopy && model.makeCopyProgress == nil)

            try await model.openMadeCopy(made, library: library)
            #expect(model.vaultURL == made.created.url)
            #expect(model.phase == .unlocked)
            #expect(!model.isVaultReadOnly)
            #expect(model.notes.map(\.id) == [Self.lecture])
            #expect(model.vault?.isHome == true)
        }

        @Test func includeDeletedCopiesTheDeletedNoteToo() async throws {
            let model = try await Self.opened()
            defer { model.close() }
            let made = try await model.makeCopy(Self.request(), includeDeleted: true, library: Self.library())
            #expect(made.report.notes == 2)
            #expect(made.report.deletedCopied == 1)
        }

        @Test func aRecoveryKeyVaultCopiesAndTheCopyIsWritable() async throws {
            let (url, _) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), services: .headless())
            defer { model.close() }
            try await model.openVault(at: url)
            let recovery = try String(contentsOf: ModelFixture.fixtures.appendingPathComponent("sample-recovery.key"), encoding: .utf8)
            try await model.unlock(identityText: recovery)
            #expect(model.isRecoveryOpen && model.isVaultReadOnly)
            #expect(model.makeCopyNotices.contains(.recoveryKey))
            let library = Self.library()
            let made = try await model.makeCopy(Self.request(), includeDeleted: false, library: library)
            #expect(made.report.notes == 1)
            try await model.openMadeCopy(made, library: library)
            #expect(!model.isVaultReadOnly)
            #expect(!model.isRecoveryOpen)
        }

        @Test func anUnconfirmedListCopiesWithANotice() async throws {
            // No trust record and no root: this device has not confirmed the vault.
            let model = try await Self.opened(trust: MemoryEpochTrustStore())
            defer { model.close() }
            #expect(model.needsVaultConfirmation)
            #expect(model.makeCopyNotices == [.unconfirmedList])
            let made = try await model.makeCopy(Self.request(), includeDeleted: false, library: Self.library())
            #expect(made.report.notes == 1)
            #expect(made.report.warnings.contains { $0.contains("device list") })
        }

        @Test func aNewerFormatVaultCopiesWhatItUnderstandsAndSaysSo() async throws {
            let (url, keyText) = try await ReadOnlyVaultTests.newerVault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60), services: .headless())
            defer { model.close() }
            try await model.openVault(at: url)
            try await model.unlock(identityText: keyText)
            #expect(model.isVaultReadOnly)
            #expect(model.makeCopyNotices.contains(.newerContent))
            let library = Self.library()
            let made = try await model.makeCopy(Self.request(), includeDeleted: false, library: library)
            #expect(made.report.isMissingNewerContent)
            #expect(made.report.notes >= 1)
            try await model.openMadeCopy(made, library: library)
            #expect(!model.isVaultReadOnly, "the copy holds nothing a newer version wrote")
        }

        @Test func requestsAreOneAtATimeAndClosingClearsThem() async throws {
            let model = try await Self.opened()
            defer { model.close() }
            model.requestMakeCopy()
            let first = try #require(model.makeCopyRequest)
            model.requestMakeCopy(window: UUID())
            #expect(model.makeCopyRequest?.id == first.id)
            model.close()
            #expect(model.makeCopyRequest == nil)
            #expect(!model.canMakeCopy, "nothing is open")
        }

        @Test func aPartialCopyCannotBeCopied() async throws {
            let model = try await Self.opened()
            defer { model.close() }
            model.pendingNoteIDs = [UUID()]
            #expect(!model.canMakeCopy)
            model.requestMakeCopy()
            #expect(model.makeCopyRequest == nil)
            await #expect(throws: CopyError.partialSource) {
                _ = try await model.makeCopy(Self.request(), includeDeleted: false, library: Self.library())
            }
        }

        @Test func aBadNameIsRefusedBeforeAnythingIsWritten() async throws {
            let model = try await Self.opened()
            defer { model.close() }
            let library = Self.library()
            await #expect(throws: VaultStoreError.self) {
                _ = try await model.makeCopy(Self.request("a/b"), includeDeleted: false, library: library)
            }
            #expect(library.vaultStore.list().isEmpty)
        }

        /// A copy paused after its first note (`makeCopyStepHook` waits), so the test can act mid-copy.
        private func pausedCopy(_ model: AppModel, library: VaultLibrary)
            -> (task: Task<MadeCopy, any Error>, reached: AsyncStream<CopyProgress>, resume: @Sendable () -> Void) {
            let (stream, continuation) = AsyncStream.makeStream(of: CopyProgress.self)
            let gate = DispatchSemaphore(value: 0)
            model.makeCopyStepHook = { p in
                continuation.yield(p)
                if p.done == 1 { gate.wait() }
            }
            let task = Task { try await model.makeCopy(Self.request(), includeDeleted: true, library: library) }
            return (task, stream, { gate.signal() })
        }

        @Test func progressIsReportedAndCancelLeavesNoVault() async throws {
            let model = try await Self.opened()
            defer { model.close() }
            let library = Self.library()
            let run = pausedCopy(model, library: library)
            var first: CopyProgress?
            for await p in run.reached { first = p; break }
            #expect(first?.done == 1 && first?.total == 2)
            #expect(model.isMakingCopy)
            model.cancelMakeCopy()
            run.resume()
            await #expect(throws: CopyError.cancelled) { _ = try await run.task.value }
            #expect(!model.isMakingCopy && model.makeCopyProgress == nil)
            #expect(library.vaultStore.list().isEmpty, "a canceled copy leaves no vault")
            library.vaultStore.sweep()
            let staging = library.vaultStore.root.appendingPathComponent(".staging")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
        }

        @Test func closingTheVaultMidCopyStopsItAndLeavesNoVault() async throws {
            let model = try await Self.opened()
            let library = Self.library()
            let run = pausedCopy(model, library: library)
            for await _ in run.reached { break }
            model.close()
            run.resume()
            await #expect(throws: CopyError.cancelled) { _ = try await run.task.value }
            #expect(library.vaultStore.list().isEmpty)
            #expect(model.vault == nil)
            #expect(!model.isMakingCopy)
        }
    }
}
