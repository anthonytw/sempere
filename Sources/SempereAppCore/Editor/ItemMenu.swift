import Foundation
import Sempere

/// What the selection menu offers for an item (pure, tested): the same
/// entries whichever way the item was selected.
public enum ItemMenu {
    public enum Entry: Equatable {
        case play, playRecording, pauseRecording, showTranscript, editText, copy, duplicate, editMath, crop, replaceImage,
             rotateLeft, rotateRight, bringToFront, delete, paste
    }

    /// An audio item's recording (format.md §8.2.9), when the note has it: whether the
    /// card's Play/Pause is wired, the recording plays, and it has a transcript to show.
    public struct AudioState: Equatable {
        public var canToggle: Bool
        public var isPlaying: Bool
        public var hasTranscript: Bool

        public init(canToggle: Bool, isPlaying: Bool, hasTranscript: Bool) {
            self.canToggle = canToggle
            self.isPlaying = isPlaying
            self.hasTranscript = hasTranscript
        }
    }

    /// The entries for `item` (nil: nothing selected), in order. `audio` is the
    /// recording an audio item shows (nil: none, or the recording is missing).
    public static func entries(for item: Item?, editable: Bool, canPlay: Bool, canCrop: Bool, canReplace: Bool,
                        canPaste: Bool, canEditMath: Bool = false, audio: AudioState? = nil) -> [Entry] {
        var out: [Entry] = []
        if let item {
            if item.kind == .video, canPlay { out.append(.play) }
            if item.kind == .audio, let audio {
                if audio.canToggle { out.append(audio.isPlaying ? .pauseRecording : .playRecording) }
                if audio.hasTranscript { out.append(.showTranscript) }
            }
            if editable, item.kind == .text, item.text != nil { out.append(.editText) }
            out.append(.copy)
            if editable {
                out.append(.duplicate)
                if canEditMath, item.kind == .math, item.math != nil { out.append(.editMath) }
                if canCrop, item.cropBounds != nil { out.append(.crop) }
                if canReplace, item.kind == .image { out.append(.replaceImage) }
                out.append(.rotateLeft)
                out.append(.rotateRight)
                out.append(.bringToFront)
                out.append(.delete)
            }
        }
        if editable, canPaste { out.append(.paste) }
        return out
    }
}
