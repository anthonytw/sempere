import Foundation
import Sempere

/// A device-local queue folder of captures that wait for their vault, in the layout `CaptureDelivery` keeps
/// (`<queue>/<vault id>/<id>.capture.age` with `<name>.epoch` beside it: "<epoch> <epoch id hex>"), so one flush serves both.
/// A capture queued here is NOT in the write ledger: it is recorded when it is placed (a ledger entry whose file is not at
/// its path is dropped after an hour).
public enum WatchQueue {
    /// The folder of vault `vault` under the queue root.
    public static func folder(_ root: URL, vault: UUID) -> URL {
        root.appendingPathComponent(vault.uuidString.lowercased(), isDirectory: true)
    }

    /// `<queued file>.epoch`.
    public static func epochSidecar(_ file: URL) -> URL { file.appendingPathExtension("epoch") }

    /// Queues `sealed` in `folder`: its epoch sidecar first (a crash leaves a sidecar without a file, which is ignored, never
    /// a file without its epoch), then the file, never over an existing one.
    public static func store(_ sealed: SealedCapture, in folder: URL) throws {
        if let epoch = sealed.epoch, let id = sealed.epochId {
            try FileIO.createDirectory(folder)
            try Data("\(epoch) \(id.map { String(format: "%02x", $0) }.joined())\n".utf8)
                .write(to: epochSidecar(folder.appendingPathComponent(sealed.name)), options: .atomic)
        }
        try CaptureWriter.store(sealed, in: folder)
    }
}
