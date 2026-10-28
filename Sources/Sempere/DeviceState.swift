import Foundation

/// The per-user device identity and clock a command-line tool keeps between
/// runs (`$XDG_STATE_HOME/sempere/device.json`).
public struct DeviceState: Codable, Equatable, Sendable {
    /// This machine's device id (format.md §5).
    public var device: DeviceID
    /// Last hybrid-clock milliseconds issued.
    public var millis: Int64
    /// Last hybrid-clock counter issued.
    public var counter: Int

    /// The stored clock.
    public var clock: HybridClock {
        get { HybridClock(millis: millis, counter: counter) }
        set { millis = newValue.millis; counter = newValue.counter }
    }

    public init(device: DeviceID, clock: HybridClock = HybridClock()) {
        self.device = device; self.millis = clock.millis; self.counter = clock.counter
    }

    /// `$XDG_STATE_HOME/sempere/device.json`, else
    /// `~/.local/state/sempere/device.json`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".local/state", isDirectory: true)
        }
        return base.appendingPathComponent("sempere/device.json")
    }

    /// Reads the state file, or creates it with a fresh random device id.
    ///
    /// - Throws: `VaultError.io` when the file exists but is unreadable or
    ///   malformed, or cannot be created.
    public static func loadOrCreate(at url: URL) throws -> DeviceState {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try BoundedRead.contents(of: url, maxBytes: BoundedRead.maxSmallFileBytes)
                return try JSONDecoder().decode(DeviceState.self, from: data)
            } catch {
                throw VaultError.io("device state \(url.path): \(error)")
            }
        }
        let state = DeviceState(device: .random())
        try state.save(to: url)
        return state
    }

    /// Writes the state file atomically, creating its directory.
    public func save(to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url, options: .atomic)
        } catch {
            throw VaultError.io("device state \(url.path): \(error)")
        }
    }
}
