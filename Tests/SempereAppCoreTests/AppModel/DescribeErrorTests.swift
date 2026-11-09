import Foundation
import Sempere
import SempereRender
@testable import SempereAppCore
import TempDirSupport
import Testing

extension AppModelSuites {
    /// Every text the model builds from an error goes through `services.describeError` (the app's `AppModel.describe`),
    /// not the error's own description: the app words errors the library does not (docs/design/thin-app.md, step 7b).
    @MainActor @Suite struct DescribeErrorTests {
        static let stub: ErrorDescriber = { "words(\($0))" }

        static func model() async throws -> AppModel {
            let (url, key) = try await ModelFixture.vault()
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60),
                                 services: .headless(describeError: stub))
            try await model.openVault(at: url)
            try await model.unlock(identityText: try await ModelFixture.keyText(key))
            model.selectedNoteID = ModelFixture.lecture
            try await model.openEditor(for: ModelFixture.lecture)
            return model
        }

        @Test func aNoteWhoseEditorCouldNotSaveIsReportedInTheServicesWords() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            editor.saveFailure = "disk full"
            let dir = TestTemp.root.appendingPathComponent("describe-\(UUID().uuidString)")
            let result = try await model.exportNotes([ModelFixture.lecture], options: ShareOptions(format: .pdf), into: dir) { _ in }
            let failure = try #require(result.failures.first)
            #expect(failure.hasSuffix(": words(\(UnsavedChangesError()))"))
        }

        @Test func aBulkExportOfAnUnsavedNoteIsReportedInTheServicesWords() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            editor.saveFailure = "disk full"
            let dir = TestTemp.root.appendingPathComponent("describe-bulk-\(UUID().uuidString)")
            let options = BulkExportOptions(format: .pdf, layout: .flat)
            let jobs = model.bulkExportJobs(.notes([ModelFixture.lecture]), options: options)
            let session = try BulkExportSession(destination: .folder(dir), options: options, jobs: jobs)
            let result = try await model.runBulkExport(jobs, session: session) { _ in }
            let failure = try #require(result.failures.first)
            #expect("\(failure)".contains("words(\(UnsavedChangesError()))"))
        }

        @Test func aNoticeCarriesTheServicesWords() async throws {
            let model = try await Self.model()
            defer { model.close() }
            let editor = try #require(model.editor)
            var missing = Recording(id: UUID(), blob: BlobRef(sha256: String(repeating: "0", count: 64), size: 10, type: "audio/mp4", extra: [:]),
                                    started: Date())
            missing.duration = 1
            await model.play(missing, in: editor)
            guard case .notice(.recordingUnplayable(let reason))? = model.alert else {
                Issue.record("expected recordingUnplayable, got \(String(describing: model.alert))"); return
            }
            #expect(reason.hasPrefix("words("))
        }
    }
}
