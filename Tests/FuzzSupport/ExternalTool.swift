import Foundation

/// Finding and running the external tools some tests compare against (`age`, `zip`, `pdftotext`, `zbarimg`, …).
/// What a missing tool means (skip, fail, or carry on) stays with each test; see `RequiredTools`.
public enum ExternalTool {
    /// The executable `name` on PATH or in the usual install folders, if there is one.
    public static func find(_ name: String) -> URL? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// The outcome of one run.
    public struct Result {
        public var status: Int32
        public var out: Data
        public var err: Data
        public var errText: String { String(decoding: err, as: UTF8.self) }
    }

    /// Runs `exe` with `args` (empty stdin) and waits. Both output pipes are drained while it runs, so a large
    /// output cannot stall the child. Checking the status is the caller's job.
    @discardableResult
    public static func run(_ exe: URL, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let err = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: out, err: err.data)
    }

    /// `s` quoted for a POSIX shell.
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var data: Data {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
