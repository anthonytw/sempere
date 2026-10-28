import ArgumentParser
import Foundation
import Sempere
import SemperePDF
import SempereRender

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The CLI's `PDFPageRasterizer` (`docs/attachments.md` §10): Poppler's
/// `pdftoppm` run as a separate process on the verified temporary plaintext
/// of a PDF blob. It is started with an argument vector, never a shell,
/// through `sempere`'s own `__exec-limited` trampoline, which sets resource
/// limits (CPU time, address space, output file size, no core files) before
/// it `exec`s Poppler; a wall-clock timeout kills it (SIGTERM, then SIGKILL).
/// Output goes to a private temporary directory that is deleted afterwards,
/// and is read back only up to the size the requested pixels need. A hostile
/// PDF that hangs or crashes Poppler costs one timeout and yields a
/// placeholder, never a hung or crashed export.
struct PopplerRasterizer: PDFPageRasterizer {
    /// `pdftoppm`.
    let executable: String
    /// Wall-clock limit per page, seconds.
    let timeout: Double
    /// Address-space limit for Poppler.
    var memoryLimit = 3 << 30

    typealias Failure = PopplerTool.Failure

    /// `SEMPERE_PDFTOPPM` (unless empty), else `pdftoppm` on `PATH`.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        PopplerTool.locate("pdftoppm", override: environment["SEMPERE_PDFTOPPM"].flatMap { $0.isEmpty ? nil : $0 },
                           environment: environment)
    }

    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage {
        try rasterize(pdf: pdf, pageIndex: pageIndex, pixelWidth: pixelWidth, pixelHeight: pixelHeight, rotation: nil)
    }

    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int, rotation known: Int?) throws -> RGBAImage {
        guard pageIndex >= 0, pageIndex < Int(Int32.max), pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 1 << 20, pixelHeight <= 1 << 20 else { throw Failure(message: "invalid request") }
        // Poppler scales before it applies /Rotate: ask for the unrotated size.
        let rotation = known ?? Self.rotation(pdf: pdf, pageIndex: pageIndex)
        let swap = rotation.map { $0 % 180 != 0 } ?? false
        var image = try run(pdf: pdf, pageIndex: pageIndex, width: swap ? pixelHeight : pixelWidth,
                            height: swap ? pixelWidth : pixelHeight)
        if rotation == nil, image.width == pixelHeight, image.height == pixelWidth, pixelWidth != pixelHeight {
            image = try run(pdf: pdf, pageIndex: pageIndex, width: pixelHeight, height: pixelWidth)
        }
        guard image.width == pixelWidth, image.height == pixelHeight else {
            throw Failure(message: "pdftoppm returned \(image.width)×\(image.height), not \(pixelWidth)×\(pixelHeight)")
        }
        return image
    }

    /// The page's `/Rotate`, from SemperePDF (nil when it cannot read the file).
    static func rotation(pdf: URL, pageIndex: Int) -> Int? {
        guard let data = try? BoundedRead.contents(of: pdf, maxBytes: PDFLimits.standard.maxFileBytes) else { return nil }
        return try? PDFFile(data: data).page(pageIndex).rotation
    }

    private func run(pdf: URL, pageIndex: Int, width: Int, height: Int) throws -> RGBAImage {
        try PopplerTool.withTemporaryDirectory(prefix: "sempere-pdftoppm") { dir in
            let prefix = dir.appendingPathComponent("page")
            let expected = width * height * 3   // ≤ 2^40 + …: fits
            let page = String(pageIndex + 1)
            let popplerArgs = ["-f", page, "-l", page, "-singlefile", "-cropbox", "-aa", "yes", "-aaVector", "yes",
                               "-scale-to-x", String(width), "-scale-to-y", String(height), "--", pdf.path, prefix.path]
            let p = try PopplerTool.run(executable, popplerArgs, name: "pdftoppm", timeout: timeout,
                                        memoryLimit: memoryLimit, fileSizeLimit: expected + (1 << 16))
            if p.terminationReason == .uncaughtSignal {
                throw Failure(message: "pdftoppm was killed by signal \(p.terminationStatus)")
            }
            guard p.terminationStatus == 0 else { throw Failure(message: "pdftoppm exited with status \(p.terminationStatus)") }
            let out = dir.appendingPathComponent("page.ppm")
            let data: Data
            do { data = try BoundedRead.contents(of: out, maxBytes: expected + 4096) } catch {
                throw Failure(message: "pdftoppm wrote no usable image")
            }
            return try Self.decodePPM(data)
        }
    }

    /// A binary PPM (P6, maxval 255) as RGBA.
    static func decodePPM(_ data: Data) throws -> RGBAImage {
        let b = [UInt8](data)
        var i = 0
        func token() -> Int? {
            while i < b.count {
                if b[i] == 0x23 { while i < b.count, b[i] != 0x0A { i += 1 } } else if [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } else { break }
            }
            var v = 0
            var digits = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39, digits < 9 {
                v = v * 10 + Int(b[i] - 0x30); i += 1; digits += 1
            }
            return digits > 0 ? v : nil
        }
        guard b.count > 2, b[0] == 0x50, b[1] == 0x36 else { throw Failure(message: "pdftoppm output is not a PPM") }
        i = 2
        guard let w = token(), let h = token(), let maxval = token(), maxval == 255, w > 0, h > 0, i < b.count else {
            throw Failure(message: "bad PPM header")
        }
        i += 1   // the single white-space byte after maxval
        guard b.count - i >= w * h * 3 else { throw Failure(message: "truncated PPM") }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for k in 0..<(w * h) {
            px[4 * k] = b[i + 3 * k]; px[4 * k + 1] = b[i + 3 * k + 1]; px[4 * k + 2] = b[i + 3 * k + 2]
        }
        return try RGBAImage(width: w, height: h, pixels: px)
    }
}

/// `sempere __exec-limited --cpu S --memory B --file-size B -- PROGRAM ARGS…`:
/// sets resource limits, then replaces itself with PROGRAM (`execv`, no
/// shell, no `PATH` search). Internal to the PDF rasterizer; not documented
/// as a command.
enum ExecLimited {
    static let command = "__exec-limited"

    /// Never returns: execs, or exits 127.
    static func main(_ args: [String]) -> Never {
        var cpu: rlim_t?, memory: rlim_t?, fileSize: rlim_t?
        var i = 0
        while i < args.count, args[i] != "--" {
            guard i + 1 < args.count, let v = UInt64(args[i + 1]) else { exit(127) }
            switch args[i] {
            case "--cpu": cpu = rlim_t(v)
            case "--memory": memory = rlim_t(v)
            case "--file-size": fileSize = rlim_t(v)
            default: exit(127)
            }
            i += 2
        }
        let program = Array(args.dropFirst(i + 1))
        guard let path = program.first, path.hasPrefix("/") else { exit(127) }
        limit(.cpu, cpu)
        limit(.memory, memory)
        limit(.fileSize, fileSize)
        limit(.core, 0)
        var cargs: [UnsafeMutablePointer<CChar>?] = program.map { strdup($0) }
        cargs.append(nil)
        execv(path, &cargs)
        exit(127)
    }

    enum Resource { case cpu, memory, fileSize, core }

    private static func limit(_ r: Resource, _ value: rlim_t?) {
        guard let value else { return }
        var rl = rlimit(rlim_cur: value, rlim_max: value)
        #if os(Linux)
        let id: __rlimit_resource_t
        switch r {
        case .cpu: id = __rlimit_resource_t(RLIMIT_CPU.rawValue)
        case .memory: id = __rlimit_resource_t(RLIMIT_AS.rawValue)
        case .fileSize: id = __rlimit_resource_t(RLIMIT_FSIZE.rawValue)
        case .core: id = __rlimit_resource_t(RLIMIT_CORE.rawValue)
        }
        _ = setrlimit(id, &rl)
        #else
        let id: Int32
        switch r {
        case .cpu: id = RLIMIT_CPU
        case .memory: id = RLIMIT_AS
        case .fileSize: id = RLIMIT_FSIZE
        case .core: id = RLIMIT_CORE
        }
        _ = setrlimit(id, &rl)   // macOS may refuse RLIMIT_AS; the timeout still holds
        #endif
    }
}

/// `sempere __rasterize-pdf FILE --page N --width W --height H --out OUT.ppm`:
/// runs the export's PDF rasterizer on a plain PDF file. Hidden; for tests
/// and for checking a Poppler install.
struct RasterizePDFCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__rasterize-pdf", abstract: "Rasterize one PDF page as the exporter does.", shouldDisplay: false)

    @Argument var file: String
    @Option var page: Int = 1
    @Option var width: Int
    @Option var height: Int
    @Option var out: String
    @Option var timeout: Double = 30

    func run() throws {
        guard let tool = PopplerRasterizer.locate() else { throw CLIError.failure("pdftoppm not found") }
        guard page >= 1, width > 0, height > 0, timeout > 0 else { throw CLIError.failure("invalid arguments") }
        let image: RGBAImage
        do {
            image = try PopplerRasterizer(executable: tool, timeout: timeout)
                .rasterize(pdf: URL(fileURLWithPath: file), pageIndex: page - 1, pixelWidth: width, pixelHeight: height)
        } catch {
            throw CLIError.failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        var ppm = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for k in 0..<(image.width * image.height) {
            rgb[3 * k] = image.pixels[4 * k]; rgb[3 * k + 1] = image.pixels[4 * k + 1]; rgb[3 * k + 2] = image.pixels[4 * k + 2]
        }
        ppm.append(contentsOf: rgb)
        do { try ppm.write(to: URL(fileURLWithPath: out)) } catch { throw CLIError.failure("cannot write \(out)") }
    }
}
