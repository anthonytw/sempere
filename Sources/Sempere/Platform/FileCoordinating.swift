import Foundation

/// Coordinated reads and writes of files a provider (iCloud Drive, another app's storage) may touch at the same
/// time: `NSFileCoordinator` in the app (`SystemFileCoordinator`), nothing in tests, the CLI and on Linux
/// (`UncoordinatedFiles`). Never nest two coordinated writes of one item: the second waits for the first for ever
/// (CLAUDE.md "Folder targets"). The open vault is local and is never coordinated.
public protocol FileCoordinating: Sendable {
    /// Runs `body` inside a coordinated read of `url`.
    func coordinateReading<T>(_ url: URL, _ body: () throws -> T) throws -> T
    /// Runs `body` inside a coordinated write of `url`, so a provider uploads what `body` put there.
    func coordinateWriting<T>(_ url: URL, _ body: () throws -> T) throws -> T
}

extension FileCoordinating {
    /// `coordinateReading`, or `body` alone when `url` is nil (a folder that needs no coordination).
    public func coordinatedRead<T>(_ url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        return try coordinateReading(url, body)
    }

    /// `coordinateWriting`, or `body` alone when `url` is nil.
    public func coordinatedWrite<T>(_ url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        return try coordinateWriting(url, body)
    }
}

/// `FileCoordinating` that coordinates nothing: `body` runs at once (tests, the CLI, Linux).
public struct UncoordinatedFiles: FileCoordinating {
    public init() {}
    public func coordinateReading<T>(_ url: URL, _ body: () throws -> T) throws -> T { try body() }
    public func coordinateWriting<T>(_ url: URL, _ body: () throws -> T) throws -> T { try body() }
}
