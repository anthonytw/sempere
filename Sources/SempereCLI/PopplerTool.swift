import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// What `PopplerRasterizer` and `PopplerTextExtractor` share: finding the
/// binary, a private temporary directory, and running it as a separate
/// process (an argument vector, never a shell) through `sempere`'s own
/// `__exec-limited` trampoline with a wall-clock timeout.
enum PopplerTool {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// `override` when given (nil unless it is executable), else `binary` on `PATH`.
    static func locate(_ binary: String, override: String?, environment: [String: String]) -> String? {
        if let p = override { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        for dir in (environment["PATH"] ?? "/usr/bin:/usr/local/bin").split(separator: ":") {
            let p = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs `body` with a new mode-0700 directory under the temporary
    /// directory, deleted afterwards.
    static func withTemporaryDirectory<T>(prefix: String, _ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(message: "cannot create a temporary directory") }
        defer { try? fm.removeItem(at: dir) }
        return try body(dir)
    }

    /// Runs `executable args…` with stdio closed, under CPU (`timeout` + 1 s),
    /// memory and output-file-size limits, and waits up to `timeout` seconds;
    /// past that it is sent SIGTERM, then SIGKILL, and this throws. Returns
    /// the finished process for the caller to check its exit.
    static func run(_ executable: String, _ args: [String], name: String, timeout: Double,
                    memoryLimit: Int, fileSizeLimit: Int) throws -> Process {
        let p = Process()
        if let me = Bundle.main.executablePath {
            p.executableURL = URL(fileURLWithPath: me)
            p.arguments = [ExecLimited.command, "--cpu", String(Int(timeout.rounded(.up)) + 1),
                           "--memory", String(memoryLimit), "--file-size", String(fileSizeLimit),
                           "--", executable] + args
        } else {
            p.executableURL = URL(fileURLWithPath: executable)   // no trampoline: the timeout still applies
            p.arguments = args
        }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { throw Failure(message: "cannot run \(executable): \(error.localizedDescription)") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 5)
            }
            throw Failure(message: "\(name) timed out after \(Int(timeout)) s")
        }
        return p
    }
}
