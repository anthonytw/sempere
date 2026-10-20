import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere

/// The in-app vault store (`VaultStore`, docs/design/device-first-sync.md §2, §4.2): every vault is a
/// complete copy under `<root>/<vaultId>/`, created or copied in through a staging folder so that
/// nothing partial is ever listed, each vault isolated by its own locks.
final class InAppVaultStoreTests: TempDirTestCase {
    private var store: VaultStore!
    private var identity: NativeIdentity!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = VaultStore(root: tmp.appendingPathComponent("Vaults", isDirectory: true))
        identity = try IdentityFile.parse(String(contentsOf: FixtureTests.bundled("sample.key"), encoding: .utf8))
    }

    /// A private copy of the sample vault, outside the store.
    private func sourceVault(_ name: String = "Notes.sempere") throws -> URL {
        let url = tmp.appendingPathComponent("outside", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FixtureTests.bundled("sample.sempere"), to: url)
        return url
    }

    private func newVault(_ name: String) throws -> VaultStore.Entry {
        try store.create(name: name) { url in
            try Vault.create(at: url, recipients: [identity.recipient], identities: [identity])
        }.entry
    }

    /// Every regular file under `root`, relative path → bytes (hidden names skipped).
    private func files(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            let rel = String(url.standardizedFileURL.resolvingSymlinksInPath().path
                .dropFirst(root.standardizedFileURL.resolvingSymlinksInPath().path.count + 1))
            out[rel] = try Data(contentsOf: url)
        }
        return out
    }

    private func stagingLeftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".staging").path)) ?? []
    }

    // MARK: - Create

    func testCreateInstallsUnderTheVaultIdAndLists() throws {
        let a = try newVault("Work")
        let b = try newVault("Home")
        XCTAssertEqual(store.list().map(\.name), ["Home", "Work"])
        XCTAssertEqual(a.url.lastPathComponent, "Work.sempere")
        XCTAssertEqual(a.url.deletingLastPathComponent().lastPathComponent, a.vaultId.uuidString.lowercased())
        XCTAssertEqual(try Vault.open(at: a.url).vaultId, a.vaultId)
        XCTAssertNil(a.problem)
        XCTAssertEqual(store.entry(id: b.vaultId)?.url, b.url)
        XCTAssertEqual(store.entry(containing: a.url.appendingPathComponent("notes"))?.vaultId, a.vaultId)
        XCTAssertNil(store.entry(containing: tmp))
        XCTAssertTrue(stagingLeftovers().isEmpty)
        // Two vaults may share a name: they are told apart by id.
        let again = try newVault("Work")
        XCTAssertNotEqual(again.vaultId, a.vaultId)
        XCTAssertEqual(store.list().filter { $0.name == "Work" }.count, 2)
    }

    func testAFailedCreateLeavesNothing() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(try store.create(name: "Broken") { url -> Void in
            _ = try Vault.create(at: url, recipients: [identity.recipient])
            throw Boom()
        })
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(stagingLeftovers().isEmpty)
        // A build that makes no vault is refused, not installed.
        XCTAssertThrowsError(try store.create(name: "Empty") { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        })
        XCTAssertTrue(store.list().isEmpty)
    }

    func testNamesAreChecked() throws {
        XCTAssertEqual(try VaultStore.folderName(for: "  Notes "), "Notes.sempere")
        for bad in ["", "  ", ".hidden", "a/b", "a:b", "x.sempere", "tab\there", String(repeating: "n", count: 250)] {
            XCTAssertThrowsError(try VaultStore.folderName(for: bad), bad) {
                XCTAssertEqual($0 as? VaultStoreError, .invalidName(bad))
            }
        }
    }

    // MARK: - Copy in

    func testCopyInIsByteForByteAndLeavesTheSourceAlone() throws {
        let source = try sourceVault()
        try Data("finder".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try Data("capture".utf8).write(to: source.appendingPathComponent("inbox/0f.capture.age"))
        let before = try files(source)
        let progress = Progress(totalUnitCount: 0)
        let entry = try store.importVault(from: source, options: .init(progress: { done, total in
            progress.totalUnitCount = Int64(total)
            progress.completedUnitCount = Int64(done)
        }))
        XCTAssertEqual(entry.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(entry.name, "Notes")
        XCTAssertEqual(entry.url.path, store.root.appendingPathComponent(SampleFixture.vaultId.uuidString.lowercased())
            .appendingPathComponent("Notes.sempere").path)
        XCTAssertEqual(try files(entry.url), before, "every file, the inbox too, byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.url.appendingPathComponent(".DS_Store").path))
        XCTAssertEqual(try files(source), before, "the source is never written")
        XCTAssertEqual(progress.completedUnitCount, Int64(before.count))
        // The copy opens and reads with the key.
        let vault = try Vault.open(at: entry.url, identities: [identity])
        XCTAssertEqual(try vault.reconstruct(noteId: SampleFixture.lecture).meta.title, "Fixture lecture")
        XCTAssertTrue(vault.verify().isHealthy)
        XCTAssertTrue(stagingLeftovers().isEmpty)
    }

    func testThePlainFolderNameAndAnOverrideNameTheCopy() throws {
        let plain = try sourceVault("Old notes")
        XCTAssertEqual(try store.importVault(from: plain).url.lastPathComponent, "Old notes.sempere")
        let other = try makeScratchDirectory()
        let second = other.appendingPathComponent("x.sempere")
        try FileManager.default.copyItem(at: FixtureTests.bundled("items.sempere"), to: second)
        XCTAssertEqual(try store.importVault(from: second, options: .init(name: "Items")).name, "Items")
    }

    func testTheSameVaultIsNotCopiedInTwice() throws {
        let source = try sourceVault()
        try store.importVault(from: source)
        XCTAssertThrowsError(try store.importVault(from: source)) {
            XCTAssertEqual($0 as? VaultStoreError, .alreadyInStore(vaultId: SampleFixture.vaultId, name: "Notes"))
        }
        XCTAssertEqual(store.list().count, 1)
    }

    /// An interruption at any file leaves no vault listed: either an error (staging removed) or a crash
    /// (staging left, swept at the next operation); a later copy-in then works.
    func testAnInterruptedCopyInIsNeverVisible() throws {
        let source = try sourceVault()
        let total = try files(source).count
        struct Cut: Error {}
        for stop in [1, total / 2, total] {
            let count = StoreHookCounter()
            XCTAssertThrowsError(try store.importVault(from: source, options: .init(afterEachFile: { _ in
                if count.next() == stop { throw Cut() }
            })), "stop at \(stop)")
            XCTAssertTrue(store.list().isEmpty, "stop at \(stop)")
            XCTAssertTrue(stagingLeftovers().isEmpty, "an error removes its staging folder")
        }
        // A crash: the staging folder stays, unlisted, until the next operation sweeps it.
        var crash = VaultStore.ImportOptions(afterEachFile: { _ in throw Cut() })
        crash.keepStagingOnFailure = true
        XCTAssertThrowsError(try store.importVault(from: source, options: crash))
        XCTAssertEqual(stagingLeftovers().count, 1)
        XCTAssertTrue(store.list().isEmpty)
        let entry = try store.importVault(from: source)
        XCTAssertTrue(stagingLeftovers().isEmpty, "swept")
        XCTAssertEqual(try files(entry.url), try files(source))
    }

    /// A crash after claiming the id folder and before the vault moved in: not listed, swept, and the id
    /// can be used again.
    func testAClaimedButEmptyIdFolderIsNotAVault() throws {
        let id = SampleFixture.vaultId.uuidString.lowercased()
        let claimed = store.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: claimed.appendingPathComponent("Notes.sempere/notes"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(store.list().isEmpty, "no vault.json: nothing listed")
        store.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.path))
        try FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)
        XCTAssertEqual(try store.importVault(from: try sourceVault()).vaultId, SampleFixture.vaultId)
    }

    func testIncompleteOrUnsafeSourcesAreRefused() throws {
        let fm = FileManager.default
        func refused(_ prepare: (URL) throws -> Void, file: StaticString = #filePath, line: UInt = #line,
                     _ check: (VaultStoreError?) -> Bool) throws {
            let source = makeScratch().appendingPathComponent("V.sempere")
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: FixtureTests.bundled("sample.sempere"), to: source)
            try prepare(source)
            XCTAssertThrowsError(try store.importVault(from: source), file: file, line: line) {
                XCTAssertTrue(check($0 as? VaultStoreError), "\($0)", file: file, line: line)
            }
            XCTAssertTrue(store.list().isEmpty, file: file, line: line)
            XCTAssertTrue(stagingLeftovers().isEmpty, file: file, line: line)
        }
        let lecture = "notes/\(SampleFixture.lecture.uuidString.lowercased())"
        try refused({ try fm.createDirectory(at: $0.appendingPathComponent(".sempere-partial"), withIntermediateDirectories: true) }) {
            if case .partialCopy = $0 { return true } else { return false }
        }
        try refused({ try Data().write(to: $0.appendingPathComponent("\(lecture)/.sempere-pending")) }) {
            if case .partialCopy = $0 { return true } else { return false }
        }
        try refused({ try Data().write(to: $0.appendingPathComponent(".sempere-restore.json")) }) {
            if case .unfinishedRestore = $0 { return true } else { return false }
        }
        try refused({ src in
            let names = try fm.contentsOfDirectory(atPath: src.appendingPathComponent(lecture).path).filter { $0.hasSuffix(".age") }
            let name = try XCTUnwrap(names.first)
            try fm.moveItem(at: src.appendingPathComponent("\(lecture)/\(name)"),
                            to: src.appendingPathComponent("\(lecture)/.\(name).icloud"))
        }) {
            if case .notDownloaded(_, let count) = $0 { return count == 1 } else { return false }
        }
        try refused({ src in
            try fm.createSymbolicLink(at: src.appendingPathComponent("notes/link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        }) {
            $0 == .unsupportedEntry("notes/link")
        }
        try refused({ try fm.removeItem(at: $0.appendingPathComponent("vault.json")) }) {
            if case .notAVault = $0 { return true } else { return false }
        }
        // A source inside the store.
        let inside = store.root.appendingPathComponent("elsewhere.sempere")
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        try fm.copyItem(at: FixtureTests.bundled("sample.sempere"), to: inside)
        XCTAssertThrowsError(try store.importVault(from: inside)) {
            XCTAssertEqual($0 as? VaultStoreError, .sourceInsideStore(inside.standardizedFileURL.path))
        }
    }

    func testASourceThatChangesWhileCopiedIsRefused() throws {
        let source = try sourceVault()
        let added = source.appendingPathComponent("notes/\(SampleFixture.lecture.uuidString.lowercased())/late.delta.age")
        XCTAssertThrowsError(try store.importVault(from: source, options: .init(afterEachFile: { _ in
            if !FileManager.default.fileExists(atPath: added.path) { try Data("late".utf8).write(to: added) }
        }))) {
            XCTAssertEqual($0 as? VaultStoreError, .sourceChanged(source.standardizedFileURL.path))
        }
        XCTAssertTrue(store.list().isEmpty)
        // A file rewritten in place after it was copied (same size) differs byte for byte.
        try FileManager.default.removeItem(at: added)
        let keyFolder = source.appendingPathComponent("keys")
        let keyName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: keyFolder.path).first)
        let key = keyFolder.appendingPathComponent(keyName)
        let original = try Data(contentsOf: key)
        XCTAssertThrowsError(try store.importVault(from: source, options: .init(afterEachFile: { path in
            guard path == "keys/\(keyName)" else { return }
            var flipped = original
            flipped[flipped.count - 1] ^= 0xFF
            try flipped.write(to: key)
        }))) {
            XCTAssertEqual($0 as? VaultStoreError, .copyMismatch("keys/\(keyName)"))
        }
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(stagingLeftovers().isEmpty)
    }

    // MARK: - Restore

    /// A backup folder of the sample vault (`Backup.run`).
    private func backupFolder() throws -> URL {
        let dest = tmp.appendingPathComponent("backups/Notes Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report = try Backup.run(source: try Vault.open(at: try sourceVault("for-backup.sempere")), to: dest)
        XCTAssertTrue(report.errors.isEmpty)
        return dest
    }

    func testRestoreIntoTheStoreAndReplaceOnlyWhenAsked() throws {
        let backup = try backupFolder()
        let (first, report) = try store.restore(from: backup, options: .init(name: "Notes"))
        XCTAssertEqual(first.vaultId, SampleFixture.vaultId)
        XCTAssertEqual(first.name, "Notes")
        XCTAssertFalse(report.restored.isEmpty)
        XCTAssertTrue(try Vault.open(at: first.url, identities: [identity]).verify().isHealthy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.appendingPathComponent(".sempere-restore.json").path))

        // The id is there: refused unless replacing.
        XCTAssertThrowsError(try store.restore(from: backup)) {
            XCTAssertEqual($0 as? VaultStoreError, .alreadyInStore(vaultId: SampleFixture.vaultId, name: "Notes"))
        }
        // A note written since the backup: a replace brings back the backup as it was.
        let note = UUID()
        try Vault.open(at: first.url, identities: [identity]).write(SampleFixture.delta(note, SampleFixture.devA, 1, 9000,
                                                                                       [.addPage(Page(id: note, order: "a0"))]))
        // Not while the vault is open.
        let lease = try store.lease(first.vaultId)
        XCTAssertThrowsError(try store.restore(from: backup, options: .init(replace: true))) {
            XCTAssertEqual($0 as? VaultStoreError, .inUse(first.vaultId))
        }
        XCTAssertTrue(try Vault.open(at: first.url).noteIDs().contains(note), "nothing changed")
        lease.release()
        let (replaced, _) = try store.restore(from: backup, options: .init(replace: true))
        XCTAssertEqual(replaced.name, "Notes", "keeps the name of the copy it replaces")
        XCTAssertEqual(store.list().map(\.vaultId), [SampleFixture.vaultId])
        XCTAssertFalse(try Vault.open(at: replaced.url).noteIDs().contains(note))
        XCTAssertTrue(VaultStore.setAside(in: replaced.url.deletingLastPathComponent()).isEmpty)
        XCTAssertTrue(stagingLeftovers().isEmpty)
    }

    /// A crash between moving the old copy aside and moving the new one in: the next sweep puts the old
    /// copy back, whole.
    func testAReplaceCutBetweenItsRenamesKeepsTheOldCopy() throws {
        let backup = try backupFolder()
        let first = try store.restore(from: backup, options: .init(name: "Notes")).entry
        let note = UUID()
        try Vault.open(at: first.url, identities: [identity]).write(SampleFixture.delta(note, SampleFixture.devA, 1, 9000,
                                                                                       [.addPage(Page(id: note, order: "a0"))]))
        let before = try files(first.url)
        var crash = VaultStore.RestoreOptions(replace: true)
        crash.crashAfterSettingAside = true
        XCTAssertThrowsError(try store.restore(from: backup, options: crash))
        XCTAssertEqual(VaultStore.setAside(in: first.url.deletingLastPathComponent()).count, 1)
        store.sweep()
        XCTAssertEqual(store.list().map(\.url), [first.url])
        XCTAssertEqual(try files(first.url), before, "the old copy is back, note included")
        XCTAssertTrue(VaultStore.setAside(in: first.url.deletingLastPathComponent()).isEmpty)
    }

    func testAnIncompleteRestoreAddsNothing() throws {
        let backup = try backupFolder()
        let lecture = backup.appendingPathComponent("notes/\(SampleFixture.lecture.uuidString.lowercased())")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: lecture.path).first { $0.hasSuffix(".delta.age") })
        var bytes = try Data(contentsOf: lecture.appendingPathComponent(name))
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: lecture.appendingPathComponent(name))
        XCTAssertThrowsError(try store.restore(from: backup)) {
            XCTAssertEqual($0 as? VaultStoreError, .restoreIncomplete(1))
        }
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(stagingLeftovers().isEmpty)
    }

    // MARK: - Several vaults

    /// Two vaults open at once: each has its own lease and write lock, writes to one never wait for
    /// the other, and removing one leaves the other untouched.
    func testTwoVaultsOpenAtOnceAreIsolated() throws {
        let imported = try store.importVault(from: try sourceVault())
        let created = try newVault("Second")
        let leaseA = try store.lease(imported.vaultId)
        let leaseB = try store.lease(created.vaultId)
        let a = try Vault.open(at: imported.url, identities: [identity])
        let b = try Vault.open(at: created.url, identities: [identity])

        let lockA = store.writeLock(for: imported.vaultId)
        let lockB = store.writeLock(for: created.vaultId)
        XCTAssertTrue(lockA === store.writeLock(for: imported.vaultId), "one lock per vault per process")
        XCTAssertFalse(lockA === lockB)

        // While A's lock is held on another thread, B's is free and A's is not.
        let holding = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let thread = Thread {
            try? lockA.withLock {
                holding.signal()
                done.wait()
            }
        }
        thread.start()
        holding.wait()
        XCTAssertNil(try lockA.withLockIfFree { true }, "the same vault's writers exclude each other")
        XCTAssertEqual(try lockB.withLockIfFree { true }, true, "another vault's writer does not wait")
        XCTAssertThrowsError(try lockA.withLock(timeout: 0.1) {}) {
            XCTAssertEqual($0 as? VaultFileLock.LockError, .timedOut(lockA.url.path))
        }
        done.signal()
        XCTAssertEqual(try lockA.withLock(timeout: 5) { true }, true)

        // Concurrent writes, each under its own vault's lock.
        let note = UUID()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let (vault, lock) = i == 0 ? (a, lockA) : (b, lockB)
            for seq in 1...5 {
                try? lock.withLock {
                    try vault.write(SampleFixture.delta(note, SampleFixture.devA, seq, Int64(seq) * 1000,
                                                        (seq == 1 ? [.addPage(Page(id: note, order: "a0"))] : [])
                                                            + [.setMeta(.title("Vault \(i)"))]))
                }
            }
        }
        XCTAssertEqual(try a.revisionNames(of: note).count, 5)
        XCTAssertEqual(try b.revisionNames(of: note).count, 5)
        XCTAssertEqual(try a.reconstruct(noteId: note).meta.title, "Vault 0")
        XCTAssertEqual(try b.reconstruct(noteId: note).meta.title, "Vault 1")

        // An open vault is not removed; another one is, and the first stays as it was.
        XCTAssertThrowsError(try store.remove(imported.vaultId)) {
            XCTAssertEqual($0 as? VaultStoreError, .inUse(imported.vaultId))
        }
        leaseB.release()
        let filesA = try files(imported.url)
        try store.remove(created.vaultId)
        XCTAssertEqual(store.list().map(\.vaultId), [imported.vaultId])
        XCTAssertEqual(try files(imported.url), filesA)
        XCTAssertTrue(try Vault.open(at: imported.url, identities: [identity]).verify().isHealthy)
        leaseA.release()
        try store.remove(imported.vaultId)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.remove(imported.vaultId)) {
            XCTAssertEqual($0 as? VaultStoreError, .notFound(imported.vaultId.uuidString.lowercased()))
        }
        let trash = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".trash").path)
        XCTAssertTrue(trash.isEmpty)
    }

    func testRemoveWaitsForAWriter() throws {
        let entry = try newVault("Busy")
        let holding = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lock = store.writeLock(for: entry.vaultId)
        let thread = Thread {
            try? lock.withLock {
                holding.signal()
                done.wait()
            }
        }
        thread.start()
        holding.wait()
        XCTAssertThrowsError(try store.remove(entry.vaultId, timeout: 0.2)) {
            XCTAssertEqual($0 as? VaultStoreError, .busy(entry.vaultId))
        }
        done.signal()
        XCTAssertNotNil(store.entry(id: entry.vaultId))
    }

    func testResolveByIdPrefixOrName() throws {
        let a = try newVault("Alpha")
        let b = try newVault("Beta")
        _ = try newVault("Beta")
        XCTAssertEqual(try store.resolve(a.vaultId.uuidString).vaultId, a.vaultId)
        XCTAssertEqual(try store.resolve(String(b.vaultId.uuidString.lowercased().prefix(8))).vaultId, b.vaultId)
        XCTAssertEqual(try store.resolve("Alpha").vaultId, a.vaultId)
        XCTAssertThrowsError(try store.resolve("Beta")) {
            guard case .ambiguous = $0 as? VaultStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try store.resolve("Gamma")) { XCTAssertEqual($0 as? VaultStoreError, .notFound("Gamma")) }
    }
}

/// A thread-safe counter for `@Sendable` test hooks.
private final class StoreHookCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
