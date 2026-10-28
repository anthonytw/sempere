import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// A small deterministic mutation fuzzer for the parsers of untrusted bytes
// (docs/format.md "Untrusted input"). It runs inside `swift test` on Linux and
// macOS: every case is a seeded mutation of a valid input, run on a worker
// thread under a watchdog, and the run fails on a case that hangs, runs past
// its time budget or grows peak memory past a budget. A trap (overflow, index
// out of range, force unwrap) kills the test process, which is the signal; set
// SEMPERE_FUZZ_DUMP=<dir> to keep the input being run in `<dir>/<target>.last`.
//
// Environment:
//   SEMPERE_FUZZ_LONG=1          100× the iterations, no per-target time cap
//   SEMPERE_FUZZ_ITERATIONS=N    exactly N cases per target
//   SEMPERE_FUZZ_SEED=S          base seed (default 0); each target mixes in its name
//   SEMPERE_FUZZ_DUMP=dir        write each input to dir/<target>.last before running it
//   SEMPERE_FUZZ_VERBOSE=1       print every case index
//   SEMPERE_FUZZ_REPRO=file      run only that saved input (`<target>-<case>.bin` or
//                                 `<target>.last`), on the test thread, in the target it names

/// SplitMix64: tiny, fast and deterministic on every platform.
public struct FuzzRNG: RandomNumberGenerator {
    var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform index in `0..<n` (n > 0).
    public mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }

    /// True with probability `1 / n`.
    public mutating func oneIn(_ n: Int) -> Bool { below(n) == 0 }

    public mutating func pick<T>(_ xs: [T]) -> T { xs[below(xs.count)] }
}

/// Run settings, from the environment.
public struct FuzzConfig: Sendable {
    public var long: Bool
    public var fixedIterations: Int?
    public var seed: UInt64
    public var dump: URL?
    public var verbose: Bool
    /// One case running longer than this fails the target (watchdog).
    public var caseTimeout: TimeInterval
    /// Quick mode stops a target after this long (its cases are a prefix of the long run).
    public var targetSeconds: TimeInterval?
    /// Growth of the process's peak resident memory allowed while one target runs.
    public var memoryBudget: Int

    public static var current: FuzzConfig {
        let env = ProcessInfo.processInfo.environment
        let long = env["SEMPERE_FUZZ_LONG"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
        return FuzzConfig(long: long,
                          fixedIterations: env["SEMPERE_FUZZ_ITERATIONS"].flatMap { Int($0) },
                          seed: env["SEMPERE_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0,
                          dump: env["SEMPERE_FUZZ_DUMP"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                          verbose: env["SEMPERE_FUZZ_VERBOSE"] == "1",
                          caseTimeout: long ? 60 : 10,
                          targetSeconds: long ? nil : 3,
                          memoryBudget: 768 << 20)
    }

    /// Cases for a target whose quick run is `quick` cases.
    public func iterations(quick: Int) -> Int {
        if let fixedIterations { return fixedIterations }
        return long ? quick * 100 : quick
    }
}

/// Why a target failed.
public struct FuzzFailure: CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable { case timeout, memory, invariant }
    public var target: String
    public var iteration: Int
    public var kind: Kind
    public var detail: String
    /// The failing input, saved for reproduction (nil if it could not be written).
    public var saved: URL?

    public var description: String {
        "fuzz \(target) case \(iteration): \(kind.rawValue): \(detail)"
            + (saved.map { " (input saved to \($0.path))" } ?? "")
    }
}

/// The summary of one target's run.
public struct FuzzReport: Sendable {
    public var target: String
    public var cases = 0
    public var seconds = 0.0
    public var slowest = 0.0
    public var failures: [FuzzFailure] = []
}

// MARK: - Mutation

public enum Mutator {
    /// Integer-ish replacements for number tokens in text formats (JSON).
    public static let numberTokens = [
        "0", "-1", "1", "-0", "2", "255", "65535", "65536", "2147483647", "-2147483648", "4294967295", "4294967296",
        "9007199254740991", "9007199254740992", "-9007199254740992", "9223372036854775807",
        "-9223372036854775808", "9223372036854775808", "18446744073709551615", "1e308", "-1e308", "1e400",
        "-1e400", "1e-400", "4.9e-324", "1.7976931348623157e308", "NaN", "Infinity", "-Infinity", "0.5",
        "1e9", "-1e9", "1e15", "3.4028235e38",
    ]

    /// Strings to splice over JSON string contents.
    public static let stringTokens = [
        "", "a", "-", "/", "//", " / / ", "../../etc/passwd", "\\u0000", "\\ud800", "%2e%2e", "#FFFFFFFF", "#GGGGGG",
        "00000000", "ffffffff", "aaaaaaaa", "17596320000000000", "99999999999999999", "00000000000000000",
        "17596320000000000-aaaaaaaa", "17596320000000000-aaaaaaaa-1-0", "17596320000000000-aaaaaaaa-0-0",
        "17596320000000000-aaaaaaaa-9223372036854775807-9223372036854775807",
        "00000000-0000-0000-0000-000000000000", "7E57C0DE-0000-4000-8000-000000000001", "snapshot", "delta",
        "addStroke", "removeStroke", "addPage", "removePage", "setPageOrder", "setPageRecognition", "setMeta",
        "deleteNote", "restoreNote", "pageSize", "paper", "notebook", "title", "tags", "favorite",
        String(repeating: "a/", count: 2000), String(repeating: "z", count: 5000),
        "2026-10-05T13:20:16." + String(repeating: "9", count: 800) + "Z", "9999-12-31T23:59:59.999Z",
        "0001-01-01T00:00:00Z", "2024-02-29T23:59:59.9995Z", "2026-10-04T18:20:00+23:59", "1582-10-10T00:00:00Z",
    ]

    static let byteValues: [UInt8] = [0, 1, 0x7F, 0x80, 0xFF, 0x0A, 0x0D, 0x20, 0x22, 0x2C, 0x2D, 0x30, 0x3A,
                                      0x5B, 0x5D, 0x7B, 0x7D, 0x3D]
    static let intValues: [UInt64] = [0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x1_0000,
                                      0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x1_0000_0000,
                                      0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, .max, 1 << 53, 46, 22, 30, 56]

    /// Applies one to four random mutations. `corpus` supplies splice material.
    public static func mutate(_ input: [UInt8], corpus: [[UInt8]], text: Bool, maxSize: Int,
                              rng: inout FuzzRNG) -> [UInt8] {
        var b = input
        let rounds = 1 + rng.below(4)
        for _ in 0..<rounds {
            let choice = rng.below(text ? 13 : 10)
            switch choice {
            case 0: flipBit(&b, &rng)
            case 1: setByte(&b, &rng)
            case 2: truncate(&b, &rng)
            case 3: deleteRange(&b, &rng)
            case 4: duplicateRange(&b, &rng)
            case 5: splice(&b, corpus, &rng)
            case 6, 7: overwriteInt(&b, &rng)
            case 8: insertRandom(&b, &rng)
            case 9: copyRange(&b, &rng)
            case 10, 11: replaceNumber(&b, &rng)
            default: replaceString(&b, &rng)
            }
        }
        if b.count > maxSize { b.removeLast(b.count - maxSize) }
        return b
    }

    static func flipBit(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        guard !b.isEmpty else { return }
        b[rng.below(b.count)] ^= UInt8(1) << UInt8(rng.below(8))
    }

    static func setByte(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        guard !b.isEmpty else { return }
        b[rng.below(b.count)] = rng.oneIn(2) ? rng.pick(byteValues) : UInt8(truncatingIfNeeded: rng.next())
    }

    static func truncate(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        guard !b.isEmpty else { return }
        let n = rng.below(b.count + 1)
        if rng.oneIn(2) { b.removeLast(b.count - n) } else { b.removeFirst(min(n, b.count)) }
    }

    static func range(_ count: Int, _ rng: inout FuzzRNG) -> Range<Int> {
        let start = rng.below(count + 1)
        let len = rng.oneIn(4) ? rng.below(count - start + 1) : min(rng.below(16) + 1, count - start)
        return start..<(start + len)
    }

    static func deleteRange(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        guard !b.isEmpty else { return }
        b.removeSubrange(range(b.count, &rng))
    }

    /// Repeats a range many times: huge arrays, deep nesting, long runs.
    static func duplicateRange(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        guard !b.isEmpty else { return }
        let r = range(b.count, &rng)
        let piece = Array(b[r])
        guard !piece.isEmpty else { return }
        let times = rng.pick([2, 3, 10, 100, 1000])
        var rep: [UInt8] = []
        for _ in 0..<times where rep.count < 1 << 20 { rep += piece }
        b.insert(contentsOf: rep, at: r.upperBound)
    }

    static func copyRange(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        guard b.count > 1 else { return }
        let r = range(b.count, &rng)
        let piece = Array(b[r])
        let at = rng.below(b.count)
        let end = min(at + piece.count, b.count)
        b.replaceSubrange(at..<end, with: piece.prefix(end - at))
    }

    static func splice(_ b: inout [UInt8], _ corpus: [[UInt8]], _ rng: inout FuzzRNG) {
        let other = corpus.isEmpty ? b : rng.pick(corpus)
        guard !other.isEmpty else { return }
        let r = range(other.count, &rng)
        let at = rng.below(b.count + 1)
        if rng.oneIn(2) {
            b.insert(contentsOf: other[r], at: at)
        } else {
            b = Array(b[..<at]) + Array(other[r.lowerBound...])
        }
    }

    static func insertRandom(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        let n = rng.below(8) + 1
        let at = rng.below(b.count + 1)
        b.insert(contentsOf: (0..<n).map { _ in rng.pick(byteValues) }, at: at)
    }

    /// Overwrites 1, 2, 4 or 8 bytes with a boundary integer, little- or big-endian.
    static func overwriteInt(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        let width = rng.pick([1, 2, 4, 8])
        guard b.count >= width else { return }
        let at = rng.below(b.count - width + 1)
        var v = rng.pick(intValues)
        if rng.oneIn(4) { v = v &+ UInt64(rng.below(3)) &- 1 }
        let bigEndian = rng.oneIn(2)
        for i in 0..<width {
            let shift = UInt64(8 * (bigEndian ? width - 1 - i : i))
            b[at + i] = UInt8(truncatingIfNeeded: v >> shift)
        }
    }

    /// Replaces one ASCII number token (`-?[0-9][0-9.eE+-]*`) with a boundary value.
    static func replaceNumber(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        var starts: [Int] = []
        var i = 0
        while i < b.count {
            let c = b[i]
            if (c >= 0x30 && c <= 0x39) || (c == 0x2D && i + 1 < b.count && b[i + 1] >= 0x30 && b[i + 1] <= 0x39) {
                let prev = i > 0 ? b[i - 1] : 0x20
                // Skip digits inside strings and words (ids, hex, dates): only after a JSON delimiter.
                if [0x20, 0x3A, 0x2C, 0x5B, 0x0A].contains(prev) { starts.append(i) }
                i += 1
                while i < b.count, (b[i] >= 0x30 && b[i] <= 0x39) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(b[i]) {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return }
        let s = rng.pick(starts)
        var e = s + 1
        while e < b.count, (b[e] >= 0x30 && b[e] <= 0x39) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(b[e]) { e += 1 }
        b.replaceSubrange(s..<e, with: Array(rng.pick(numberTokens).utf8))
    }

    /// Replaces the contents of one JSON string with a boundary string.
    static func replaceString(_ b: inout [UInt8], _ rng: inout FuzzRNG) {
        var quotes: [Int] = []
        for (i, c) in b.enumerated() where c == 0x22 && (i == 0 || b[i - 1] != 0x5C) { quotes.append(i) }
        guard quotes.count >= 2 else { return }
        let k = rng.below(quotes.count / 2) * 2
        let (open, close) = (quotes[k], quotes[k + 1])
        b.replaceSubrange((open + 1)..<close, with: Array(rng.pick(stringTokens).utf8))
    }
}

// MARK: - Runner

/// Peak resident set size of this process, in bytes.
public func peakResidentBytes() -> Int {
    var usage = rusage()
    #if canImport(Darwin)
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int(usage.ru_maxrss)          // bytes on Darwin
    #else
    guard getrusage(RUSAGE_SELF.rawValue, &usage) == 0 else { return 0 }
    return Int(usage.ru_maxrss) * 1024   // KiB on Linux
    #endif
}

/// One worker thread with a large stack that runs cases handed to it, so the
/// caller can wait with a timeout (a hang fails the target instead of the
/// whole CI job timing out without a culprit).
final class FuzzWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let go = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private var job: (@Sendable () -> String?)?
    private var result: String?
    private var thread: Thread?

    init() {
        let t = Thread { self.loop() }
        t.stackSize = 8 << 20
        thread = t
        t.start()
    }

    private func loop() {
        while true {
            go.wait()
            lock.lock(); let j = job; lock.unlock()
            guard let j else { return }
            // Darwin: a secondary thread has no autorelease pool of its own, so
            // Foundation temporaries would pile up across cases.
            #if canImport(Darwin)
            let r = autoreleasepool { j() }
            #else
            let r = j()
            #endif
            lock.lock(); result = r; lock.unlock()
            done.signal()
        }
    }

    /// Runs `body`; nil when it did not finish within `timeout` (the worker is then stuck for good).
    func run(_ body: @escaping @Sendable () -> String?, timeout: TimeInterval) -> String?? {
        lock.lock(); job = body; result = nil; lock.unlock()
        go.signal()
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return .some(result)
    }

    /// Stops the thread after its current case.
    func stop() {
        lock.lock(); job = nil; lock.unlock()
        go.signal()
    }
}

public enum Fuzz {
    /// Stable 64-bit FNV-1a of a target name, mixed into the base seed.
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    /// Runs `quick` mutation cases (scaled by the environment) against `body`.
    ///
    /// - Parameters:
    ///   - seeds: valid inputs to mutate; every seed is also run unmutated first.
    ///   - text: enable JSON-aware mutations (number and string tokens).
    ///   - maxSize: inputs are cut to this many bytes.
    ///   - generate: optional extra cases built directly (structure-aware), called
    ///     for every fourth case with that case's generator.
    ///   - body: parses one input. Throwing is fine (expected for most inputs);
    ///     return a non-nil string to report a broken invariant.
    public static func run(_ target: String, seeds: [Data], quick: Int, text: Bool = false, maxSize: Int = 1 << 20,
                           config: FuzzConfig = .current,
                           generate: ((inout FuzzRNG) -> Data)? = nil,
                           body: @escaping @Sendable (Data) -> String?) -> FuzzReport {
        var report = FuzzReport(target: target)
        if let repro = ProcessInfo.processInfo.environment["SEMPERE_FUZZ_REPRO"] {
            let url = URL(fileURLWithPath: repro)
            let name = url.deletingPathExtension().lastPathComponent
            report.cases = 1
            guard name == target || name.hasPrefix(target + "-"), let input = try? Data(contentsOf: url) else { return report }
            print("fuzz \(target): reproducing \(url.path) (\(input.count) bytes)")
            let t0 = Date()
            if let problem = body(input) {
                report.failures.append(FuzzFailure(target: target, iteration: 0, kind: .invariant, detail: problem, saved: url))
            }
            print("fuzz \(target): done in \(Date().timeIntervalSince(t0)) s")
            return report
        }
        let corpus = seeds.map { [UInt8]($0) }
        var rng = FuzzRNG(seed: config.seed ^ hash(target))
        let total = config.iterations(quick: quick)
        let worker = FuzzWorker()
        defer { worker.stop() }
        let started = Date()
        let basePeak = peakResidentBytes()
        if let dump = config.dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }

        func save(_ input: Data, _ i: Int) -> URL? {
            let dir = config.dump ?? FileManager.default.temporaryDirectory.appendingPathComponent("sempere-fuzz")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(target)-\(i).bin")
            return (try? input.write(to: url)) == nil ? nil : url
        }

        for i in 0..<(seeds.count + total) {
            if let cap = config.targetSeconds, Date().timeIntervalSince(started) > cap { break }
            let input: Data
            if i < seeds.count {
                input = seeds[i]
            } else if let generate, rng.oneIn(4) {
                input = generate(&rng)
            } else {
                input = Data(Mutator.mutate(rng.pick(corpus), corpus: corpus, text: text, maxSize: maxSize, rng: &rng))
            }
            if let dump = config.dump { try? input.write(to: dump.appendingPathComponent("\(target).last")) }
            if config.verbose { print("fuzz \(target) case \(i) (\(input.count) bytes)") }
            let t0 = Date()
            let outcome = worker.run({ body(input) }, timeout: config.caseTimeout)
            let dt = Date().timeIntervalSince(t0)
            report.cases += 1
            report.slowest = max(report.slowest, dt)
            guard let outcome else {
                report.failures.append(FuzzFailure(target: target, iteration: i, kind: .timeout,
                                                   detail: "no result after \(config.caseTimeout) s",
                                                   saved: save(input, i)))
                // The worker is stuck in the case; nothing more can run on it.
                report.seconds = Date().timeIntervalSince(started)
                return report
            }
            if let problem = outcome {
                report.failures.append(FuzzFailure(target: target, iteration: i, kind: .invariant, detail: problem,
                                                   saved: save(input, i)))
            }
            let grown = peakResidentBytes() - basePeak
            if grown > config.memoryBudget {
                report.failures.append(FuzzFailure(target: target, iteration: i, kind: .memory,
                                                   detail: "peak memory grew \(grown >> 20) MiB",
                                                   saved: save(input, i)))
                break
            }
            if report.failures.count >= 5 { break }
        }
        report.seconds = Date().timeIntervalSince(started)
        print("fuzz \(target): \(report.cases) cases in \(String(format: "%.2f", report.seconds)) s, "
              + "slowest \(String(format: "%.3f", report.slowest)) s, \(report.failures.count) failures")
        return report
    }
}
