import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// Opening the fixture's note in an editor, for the app's editor suites. The editor's own tests (autosave, page
/// gestures, merges) run on every platform: `Tests/SempereAppCoreTests/NoteEditor`.
@MainActor
enum NoteEditorTests {
    static let lecture = AppModelTests.lecture

    static func open(_ vault: Vault, note: UUID = lecture, debounce: Duration = .milliseconds(300))
        async throws -> (NoteEditor, DeviceClock) {
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: vault, noteID: note, clock: clock, debounce: debounce)
        return (editor, clock)
    }

    /// Deltas this device wrote to `note`, oldest first.
    static func myDeltas(_ vault: Vault, _ clock: DeviceClock, note: UUID = lecture) throws -> [[Op]] {
        try vault.loadNote(note).revisions.filter { $0.device == clock.device }.sorted { $0.seq < $1.seq }.map {
            if case .delta(let ops) = $0.body { return ops }
            return []
        }
    }
}
