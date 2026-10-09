import ArgumentParser
import Foundation
import Sempere
import SemperePDF
import SempereRender

/// How PDF pages get their `pageText` (format.md §8.2.6) in commands that add PDF pages.
enum PDFTextMode: String, ExpressibleByArgument, CaseIterable {
    /// Poppler's `pdftotext` when installed, else the built-in reader.
    case auto
    /// The built-in pure-Swift reader (`SemperePDF.PDFText`).
    case builtin
    /// Poppler's `pdftotext` (an error when it is not installed).
    case poppler
    /// No text.
    case none
}

struct PDFTextOptions: ParsableArguments {
    @Option(name: .customLong("pdf-text"),
            help: ArgumentHelp("Store each PDF page's text for search: auto (pdftotext if installed, else built in), builtin, poppler or none.",
                               valueName: "mode"))
    var mode: PDFTextMode = .auto

    /// The extractor for `mode`; nil for `none`.
    ///
    /// - Throws: `CLIError` for `poppler` without `pdftotext`.
    func extractor(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (any PDFTextExtracting)? {
        switch mode {
        case .none: return nil
        case .builtin: return BuiltinPDFTextExtractor()
        case .poppler:
            guard let p = PopplerTextExtractor.locate(environment: environment) else {
                throw CLIError.failure("--pdf-text poppler: pdftotext is not installed (or SEMPERE_PDFTOTEXT is not executable)")
            }
            return PopplerTextExtractor(executable: p)
        case .auto:
            return PopplerTextExtractor.locate(environment: environment).map { PopplerTextExtractor(executable: $0) }
                ?? BuiltinPDFTextExtractor()
        }
    }
}

/// Poppler's `pdftotext`, run like `PopplerRasterizer` runs `pdftoppm`: an
/// argument vector (no shell) through the `__exec-limited` trampoline
/// (CPU, memory and output size limits), a wall-clock timeout, output in a
/// private temporary directory read back with a size bound. One run reads
/// every page; pages are split at the form feeds `pdftotext` ends each page with.
struct PopplerTextExtractor: PDFTextExtracting {
    let executable: String
    var timeout = 120.0
    var memoryLimit = 3 << 30
    /// Largest text file read back (a page's text is cut at 64 KiB when stored).
    var maxOutputBytes = 256 << 20

    var engine: String { "pdftotext" + (Self.version(executable).map { "-" + $0 } ?? "") }

    typealias Failure = PopplerTool.Failure

    /// `SEMPERE_PDFTOTEXT` (none when it is set but empty), else `pdftotext` on `PATH`.
    static func locate(environment: [String: String]) -> String? {
        PopplerTool.locate("pdftotext", override: environment["SEMPERE_PDFTOTEXT"], environment: environment)
    }

    /// `pdftotext -v` prints `pdftotext version 24.02.0` on standard error.
    static func version(_ executable: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-v"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(4096)
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "version ") else { return nil }
        let v = text[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : String(v)
    }

    func pageTexts(_ data: Data, pages: [Int]) throws -> [Int: String] {
        guard let first = pages.min(), let last = pages.max(), first >= 0, last < Int(Int32.max) else { return [:] }
        return try PopplerTool.withTemporaryDirectory(prefix: "sempere-pdftotext") { dir in
            let input = dir.appendingPathComponent("in.pdf"), output = dir.appendingPathComponent("out.txt")
            guard FileManager.default.createFile(atPath: input.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw Failure(message: "cannot write a temporary file")
            }
            let args = ["-enc", "UTF-8", "-f", String(first + 1), "-l", String(last + 1), "--", input.path, output.path]
            let p = try PopplerTool.run(executable, args, name: "pdftotext", timeout: timeout,
                                        memoryLimit: memoryLimit, fileSizeLimit: maxOutputBytes)
            guard p.terminationReason == .exit, p.terminationStatus == 0 else {
                throw Failure(message: "pdftotext failed (status \(p.terminationStatus))")
            }
            let text: Data
            do { text = try BoundedRead.contents(of: output, maxBytes: maxOutputBytes) } catch {
                throw Failure(message: "pdftotext wrote no usable text")
            }
            return Self.split(String(decoding: text, as: UTF8.self), first: first, wanted: Set(pages))
        }
    }

    /// Pages of `pdftotext` output (each ends with a form feed) from page `first`.
    static func split(_ text: String, first: Int, wanted: Set<Int>) -> [Int: String] {
        var out: [Int: String] = [:]
        var parts = text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
        if parts.last?.allSatisfy(\.isWhitespace) == true { parts.removeLast() }
        for (k, part) in parts.enumerated() where wanted.contains(first + k) { out[first + k] = String(part) }
        return out
    }
}
