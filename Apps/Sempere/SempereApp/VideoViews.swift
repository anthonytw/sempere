import AVFoundation
import AVKit
import CoreTransferable
import Sempere
import SempereRender
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A video item to play (a tap on it, or Play in its menu).
struct VideoPlayRequest: Identifiable {
    let id = UUID()
    let item: Item
    let page: UUID
    let editor: NoteEditor
}

/// Plays a video item (format.md §8.2.7) with `AVPlayer`: the clip is
/// fetched (iCloud) and decrypted into the model's blob cache when the sheet
/// opens, read from that verified private file, and released when it closes.
/// A clip without a poster gets one from its first frames.
struct VideoPlayerSheet: View {
    let request: VideoPlayRequest
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failure: String?
    @State private var holding = false
    @State private var gone = false

    var body: some View {
        NavigationStack {
            ZStack {
                SwiftUI.Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .accessibilityIdentifier("videoPlayer")
                } else if let failure {
                    ContentUnavailableView("Cannot Play This Video", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView("Getting the video…")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
        .onDisappear { stop() }
    }

    private var title: String {
        guard let length = ExportVideos.clock(request.item.duration) else {
            return String(localized: "Video", comment: "Title of the video player when the clip's length is unknown")
        }
        return String(localized: "Video · \(length)", comment: "Title of the video player; the value is the clip's length, such as 1:05")
    }

    private func load() async {
        let note = request.editor.noteID
        let url: URL
        do {
            url = try await model.acquireVideo(request.item, note: note)
        } catch {
            if !gone { failure = String(localized: "The video could not be read. \(AppModel.describe(error))", comment: "The value is a sentence saying why") }
            return
        }
        guard !gone else {
            model.releaseVideo(request.item, note: note)
            return
        }
        holding = true
        // The cached file has no extension: tell AVFoundation what it holds.
        let type = request.item.blob?.type ?? "video/mp4"
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: type])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        AppModel.activateVideoAudio()
        player = p
        p.play()
        await model.addPosterIfMissing(request.item, page: request.page, editor: request.editor, file: url)
    }

    private func stop() {
        gone = true
        player?.pause()
        player = nil
        if holding {
            holding = false
            AppModel.deactivateVideoAudio()
            model.releaseVideo(request.item, note: request.editor.noteID)
        }
    }
}

/// The camera, recording one clip (`UIImagePickerController` in video mode).
/// The recorded file is copied into a work folder at once: the picker's
/// file is only there until it is dismissed.
struct VideoCameraPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        #if !targetEnvironment(macCatalyst)
        // A Mac has no camera here (`InsertOptions.camera`); these are iOS-only settings.
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoExportPreset = AVAssetExportPresetPassthrough
        #endif
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (URL?) -> Void

        init(done: @escaping (URL?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done((info[.mediaURL] as? URL).flatMap { try? VideoPreparation.copyPicked($0) })
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// A clip picked in Photos, received as a file and copied into a work folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try VideoPreparation.copyPicked(received.file))
        }
    }
}

/// Which file the editor's file importer is choosing.
enum EditorFileImport {
    case pdf, video
    /// A picture to replace an image with (Replace Image from Files).
    case image
    /// PDF pages for a pageless note: the note is switched to pages only
    /// once a PDF is picked, so cancelling the picker changes nothing.
    case pdfSwitchingToPages
}
