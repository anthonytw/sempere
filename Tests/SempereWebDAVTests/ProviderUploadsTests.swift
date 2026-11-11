import Foundation
import SempereSync
import TempDirSupport
import Testing

/// Files a folder target's runs wrote into a provider's folder that it has not uploaded yet (`ProviderUploads`,
/// offline audit P15): the record a run keeps, its limits and an interrupted run's rescan. The bar's words for an
/// upload error are tested in the app.
struct ProviderUploadsTests {
    @Test func filesTheProviderHasNotUploadedAreCountedAndDropOnceUploaded() throws {
        let dir = try TestTemp.directory("provider-state")
        let folder = try TestTemp.directory("provider-folder")
        let uploaded = Set(["notes/a/1.delta.age"])
        let check: ProviderUploads.Check = { url in
            let path = url.path
            if path.hasSuffix("local.age") { return nil }   // not a provider's file
            return uploaded.contains { path.hasSuffix($0) } ? .uploaded : .waiting
        }
        let n = ProviderUploads.update(folder: folder, stateDirectory: dir, written: [
            "notes/a/1.delta.age", "notes/a/2.delta.age", "inbox/c.capture.age", "local.age"], check: check)
        #expect(n.count == 2 && !n.truncated && n.error == nil)
        #expect(Set(ProviderUploads.pending(in: dir)) == ["notes/a/2.delta.age", "inbox/c.capture.age"])
        // A later run asks again: everything is up now, and the file goes.
        #expect(ProviderUploads.update(folder: folder, stateDirectory: dir, written: [], check: { _ in .uploaded }).count == 0)
        #expect(!FileManager.default.fileExists(atPath: ProviderUploads.url(in: dir).path))
    }

    /// Review of #91, S3: past the limit the record says truncated; a run that never recorded what it wrote (it
    /// threw, or the app was killed) makes the next look at the whole folder; an upload error is a visible problem.
    @Test func providerUploadsSurviveOverflowInterruptionAndErrors() throws {
        let dir = try TestTemp.directory("provider-state")
        let folder = try TestTemp.directory("provider-folder")
        let many = (0...ProviderUploads.limit).map { "notes/n/\($0).delta.age" }
        let waiting: ProviderUploads.Check = { _ in .waiting }
        let big = ProviderUploads.update(folder: folder, stateDirectory: dir, written: many, check: waiting)
        #expect(big.count == ProviderUploads.limit && big.truncated)
        _ = ProviderUploads.update(folder: folder, stateDirectory: dir, written: [], check: { _ in .uploaded })

        // A run marked in flight that never recorded its report: the next run rescans the folder.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes/x"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("notes/x/1.delta.age"))
        #expect(!ProviderUploads.begin(stateDirectory: dir), "nothing interrupted yet")
        // (the run throws here: no update)
        #expect(ProviderUploads.begin(stateDirectory: dir), "the last run never recorded its files")
        let rescanned = ProviderUploads.update(folder: folder, stateDirectory: dir, written: [], rescan: true, check: waiting)
        #expect(ProviderUploads.pending(in: dir) == ["notes/x/1.delta.age"], "\(rescanned)")
        // A rescan that stops at its cap says so: the record is then truncated, never taken as complete.
        try Data([2]).write(to: folder.appendingPathComponent("notes/x/2.delta.age"))
        #expect(ProviderUploads.files(below: folder, cap: 1).capped)
        #expect(!ProviderUploads.files(below: folder, cap: 5).capped)
        #expect(ProviderUploads.files(below: folder, cap: 5).paths.count == 2)

        // iCloud refusing to upload (its storage full): an error the bar shows as a problem.
        // `CocoaError.ubiquitousFileUbiquityServerNotAvailable` (4355), by its number: the same on every platform.
        let full = ProviderUploads.State.failed(code: 4355, domain: NSCocoaErrorDomain, message: "full")
        let failing = ProviderUploads.update(folder: folder, stateDirectory: dir, written: ["notes/x/1.delta.age"], check: { _ in full })
        #expect(failing.error == full)
        #expect(full.isStorageUnavailable)
        #expect(!ProviderUploads.State.failed(code: 1, domain: "provider", message: "x").isStorageUnavailable)
        #expect(!ProviderUploads.State.waiting.isStorageUnavailable)
    }

    /// The system's answer for a provider's file (TestFlight 1.1.0 (69)): only a provider that says it uploaded the file
    /// counts it uploaded; no answer is waiting only while the file is fresh (`aProviderFileWithoutAnAnswerWaitsOnlyWhileFresh`).
    @Test func aProviderFileWithoutAnUploadAnswerIsWaiting() {
        let now = Date()
        #expect(ProviderUploads.state(isUploaded: true, isUploading: false, error: nil) == .uploaded)
        #expect(ProviderUploads.state(isUploaded: true, isUploading: nil, error: nil) == .uploaded)
        #expect(ProviderUploads.state(isUploaded: false, isUploading: false, error: nil) == .waiting)
        #expect(ProviderUploads.state(isUploaded: nil, isUploading: true, error: nil) == .waiting)
        #expect(ProviderUploads.state(isUploaded: nil, isUploading: nil, error: nil, modified: now, now: now) == .waiting)
        let full = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [NSLocalizedDescriptionKey: "full"])
        #expect(ProviderUploads.state(isUploaded: nil, isUploading: nil, error: full)
            == .failed(code: 640, domain: NSCocoaErrorDomain, message: "full"))
    }

    /// A provider that never answers must not strand its files: an old path with no answer counts as uploaded, a
    /// fresh one as waiting (the review of 1.1-x, B3).
    @Test func aProviderFileWithoutAnAnswerWaitsOnlyWhileFresh() {
        let now = Date()
        let fresh = now.addingTimeInterval(-10)
        let old = now.addingTimeInterval(-(ProviderUploads.settleTime + 60))
        #expect(ProviderUploads.state(isUploaded: nil, isUploading: nil, error: nil, modified: fresh, now: now) == .waiting)
        #expect(ProviderUploads.state(isUploaded: nil, isUploading: nil, error: nil, modified: old, now: now) == .uploaded)
        #expect(ProviderUploads.state(isUploaded: nil, isUploading: nil, error: nil, modified: nil, now: now) == .uploaded)
        // An answer always wins over age.
        #expect(ProviderUploads.state(isUploaded: false, isUploading: nil, error: nil, modified: old, now: now) == .waiting)
        #expect(ProviderUploads.state(isUploaded: true, isUploading: nil, error: nil, modified: fresh, now: now) == .uploaded)
    }
}
