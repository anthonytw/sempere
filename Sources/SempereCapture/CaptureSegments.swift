import Foundation
import Sempere

// The recording folder of a quick voice note (docs/quick-capture.md, format.md §11): its manifest, its segment files and
// what a seal may do with them. Foundation and `Sempere` only, so the iPhone app, the Apple Watch app and the CLI share it
// (docs/design/1.1-watch.md §3.2). Moved out of `SempereAppCore`, which re-exports this module.

/// On disk, next to a recording's audio: enough to save what was recorded if
/// the app is killed before the recording is stopped (the app's `RecordingRecovery`, `CaptureSegments.Leftover`).
public struct RecordingManifest: Codable, Equatable, Sendable {
    /// The manifest's file name in a recording folder.
    public static let fileName = "manifest.json"

    public var note: UUID
    public var recording: UUID
    public var started: Date?
    public var codec: String
    /// Segment file names in order; the last may be unfinished.
    public var segments: [String]
    /// Segments known to be complete.
    public var finished: Int

    public init(note: UUID, recording: UUID, started: Date?, codec: String, segments: [String], finished: Int) {
        self.note = note
        self.recording = recording
        self.started = started
        self.codec = codec
        self.segments = segments
        self.finished = finished
    }
}

// MARK: - Segments and the seal's rules

/// A quick voice note's recording folder: its segment files, what was left of an interrupted one, and what a
/// seal may do with what it holds (never delete audio that was not sealed: docs/quick-capture.md).
public enum CaptureSegments {
    /// The container of quick voice notes' segment files: ADTS, whose every frame stands alone, so
    /// a recording cut off by a force quit, a crash or a restart keeps its audio up to the last frame.
    /// MPEG-4 (`m4a`, what in-note recordings use) is unreadable until the recorder finishes the file:
    /// a voice note interrupted by a restart was lost whole (TestFlight 1.0.0 (6), iPhone).
    public static let segmentExtension = "aac"

    /// The format quick voice notes record in: the recording settings, but AAC for Apple Lossless
    /// (ADTS carries only AAC; `segmentExtension`).
    public static func captureFormat(_ preferred: RecordingFormat) -> RecordingFormat {
        preferred.codec == .alac ? .default : preferred
    }

    /// The segment files of a recording folder, in order: those `listed`
    /// (the session's, or its manifest's), then every other
    /// `segment-NNN.aac` in `folder` by number. A segment begun just before
    /// the app died may be missing from the manifest (its write failed or had
    /// not happened yet); sealing without it and deleting the folder would
    /// lose its audio.
    public static func files(listed: [URL], in folder: URL) -> [URL] {
        let names = Set(listed.map(\.lastPathComponent))
        let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let extra = present.compactMap { name -> (Int, String)? in
            guard !names.contains(name), let n = number(name) else { return nil }
            return (n, name)
        }.sorted { $0.0 < $1.0 }
        return listed + extra.map { folder.appendingPathComponent($0.1) }
    }

    /// The number of a segment file name (`segment-007.aac` is 7, as `RecordingSession` names them); nil for any
    /// other name.
    public static func number(_ name: String) -> Int? {
        guard name.hasPrefix("segment-"), name.hasSuffix(".aac") else { return nil }
        let digits = name.dropFirst("segment-".count).dropLast(".aac".count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// The size of the file at `url` (0 when it is missing).
    public static func byteCount(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// What a segment file holds (the app reads it with AVFoundation).
    public enum Audio: Equatable, Sendable {
        /// No byte, or a file AVFoundation reads whose audio track is zero
        /// seconds long (a segment stopped before its first frame): nothing to keep.
        case none
        /// Audio of some length (`RecordingAssembly.readable`).
        case audio
        /// Bytes AVFoundation cannot read as audio (unfinished by a crash, or damaged).
        case undecodable
    }

    /// What a seal does with a recording folder's segments.
    public enum SealPlan: Equatable, Sendable {
        /// Not a byte recorded, or only finished files of no length (stopped, or the app died, before the
        /// recorder wrote any audio): nothing to keep, the folder goes.
        case nothingRecorded
        /// A complete segment (one of the first `finished`) that does not decode: it is not skipped, since
        /// sealing the others and deleting the folder would lose its audio. The folder waits, as an
        /// unreadable one does.
        case completeSegmentUndecodable(String)
        /// Bytes of which nothing decodes (the app died in the first segment): kept too.
        case noReadableAudio
        /// Merge these segments, in order, and seal them. Only a segment after the first `finished`, the
        /// one being written when the app died, may have been left out as undecodable (docs/attachments.md
        /// §13: a crash loses at most that segment).
        case seal([URL])

        /// Whether the folder may be deleted without sealing (only when nothing was recorded).
        public var discardsFolder: Bool { self == .nothingRecorded }
    }

    /// The seal's rule for `held` (every segment file, `files(listed:in:)`, with what it holds), of which the
    /// first `finished` of `listed` (all of them when nil) are complete.
    public static func plan(held: [(url: URL, audio: Audio)], listed: [URL], finished: Int?) -> SealPlan {
        if held.allSatisfy({ $0.audio == .none }) { return .nothingRecorded }
        let complete = Set(listed.prefix(max(0, finished ?? listed.count)).map(\.lastPathComponent))
        if let bad = held.first(where: { $0.audio == .undecodable && complete.contains($0.url.lastPathComponent) }) {
            return .completeSegmentUndecodable(bad.url.lastPathComponent)
        }
        let audio = held.filter { $0.audio == .audio }.map(\.url)
        return audio.isEmpty ? .noReadableAudio : .seal(audio)
    }

    /// What a recording folder left in `root` holds, from its manifest when
    /// it can be read, else from its files: a session's folder is named by
    /// its recording id, and its segments by number (`files(listed:in:)`). Without
    /// a manifest every segment but the last counts as complete.
    public struct Leftover: Equatable, Sendable {
        public var id: UUID?
        public var segments: [URL]
        public var finished: Int?
        public var started: Date?

        public static let maxManifestBytes = 1 << 20

        /// Nil when the manifest is there but cannot be read now.
        public init?(folder: URL) {
            let fm = FileManager.default
            let url = folder.appendingPathComponent(RecordingManifest.fileName)
            var manifest: RecordingManifest?
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
            if let size, size <= Self.maxManifestBytes {
                guard let data = try? BoundedRead.contents(of: url, maxBytes: Self.maxManifestBytes) else { return nil }
                manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data)
            }
            // Only names a session gives its segments: never a path out of the folder.
            let listed = (manifest?.segments ?? []).filter { CaptureSegments.number($0) != nil }
                .map { folder.appendingPathComponent($0) }
            segments = CaptureSegments.files(listed: listed, in: folder)
            if let manifest {
                id = manifest.recording
                finished = min(max(0, manifest.finished), listed.count)
                started = manifest.started
            } else {
                id = UUID(uuidString: folder.lastPathComponent)
                finished = max(0, segments.count - 1)
                started = segments.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date }.min()
            }
        }
    }
}

