#if canImport(CoreML)
import CoreML
import Foundation
import Sempere

/// Reads handwritten math with a converted model (`MathModelManifest`) on
/// Core ML, on device. Shared by the app and `sempere recognize-math` on
/// macOS. One encoder pass per image, then beam search
/// (`MathBeamSearch`) with one decoder pass per step over the whole padded
/// token sequence (the converted decoders have no KV cache; see
/// tools/math-model/README.md).
public final class CoreMLMathRecognizer: MathRecognizing, @unchecked Sendable {
    public let manifest: MathModelManifest
    public var imageSpec: MathImageSpec { manifest.image }
    private let encoder: MLModel
    private let decoder: MLModel
    private let vocabulary: MathVocabulary
    /// Core ML models may be used from several threads; one reading at a time keeps memory flat.
    private let lock = NSLock()

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case missingFeature(String)
        case badShape(String)
        public var description: String {
            switch self {
            case .missingFeature(let name): return "the model gave no \(name)"
            case .badShape(let why): return "the model's output has an unexpected shape: \(why)"
            }
        }
    }

    /// Loads the model in `folder` (already checked against `manifest`:
    /// `MathModelStore.verify` or `installed`). The `.mlpackage`s are
    /// compiled into `compiledCache` (kept for the next load) or a
    /// temporary folder.
    public init(folder: URL, manifest: MathModelManifest, compiledCache: URL? = nil) throws {
        if let why = manifest.problem { throw MathModelManifest.Failure.malformed(why) }
        self.manifest = manifest
        let config = MLModelConfiguration()
        switch manifest.coreml.computeUnits {
        case "all": config.computeUnits = .all
        case "cpuOnly": config.computeUnits = .cpuOnly
        case "cpuAndNeuralEngine": config.computeUnits = .cpuAndNeuralEngine
        default: config.computeUnits = .cpuAndGPU
        }
        func load(_ package: String) throws -> MLModel {
            let source = folder.appendingPathComponent(package)
            let compiled: URL
            if let cache = compiledCache {
                let target = cache.appendingPathComponent((package as NSString).deletingPathExtension + ".mlmodelc")
                if !FileManager.default.fileExists(atPath: target.path) {
                    let fresh = try MLModel.compileModel(at: source)
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: fresh, to: target)
                }
                compiled = target
            } else {
                compiled = try MLModel.compileModel(at: source)
            }
            return try MLModel(contentsOf: compiled, configuration: config)
        }
        encoder = try load(manifest.coreml.encoder)
        decoder = try load(manifest.coreml.decoder)
        let vocabData = try BoundedRead.contents(of: folder.appendingPathComponent(manifest.vocabulary.file),
                                                 maxBytes: 64 << 20)
        vocabulary = try MathVocabulary.parse(vocabData, joining: manifest.vocabulary.joining)
    }

    public func recognize(_ image: MathInkImage) throws -> MathRecognition {
        lock.lock()
        defer { lock.unlock() }
        let started = Date()
        let spec = manifest.image
        guard image.width == spec.width, image.height == spec.height else {
            throw Failure.badShape("image is \(image.width)×\(image.height), the model reads \(spec.width)×\(spec.height)")
        }
        let values = image.tensor(spec)
        let input = try MLMultiArray(shape: [1, NSNumber(value: spec.channels), NSNumber(value: spec.height),
                                             NSNumber(value: spec.width)], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            // A fresh array is contiguous in C order: the tensor's own layout.
            for i in 0..<min(buffer.count, values.count) { buffer[i] = values[i] }
        }
        let c = manifest.coreml
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [c.image: input]))
        guard let states = encoded.featureValue(for: c.encoderOutput)?.multiArrayValue else {
            throw Failure.missingFeature(c.encoderOutput)
        }
        let d = manifest.decoder
        // One token input per accepted length, reused across steps.
        var inputs: [Int: MLMultiArray] = [:]
        let hypotheses = try MathBeamSearch.search(start: d.start, end: d.end, vocabularySize: d.vocabularySize,
                                                   width: d.beamWidth, maxLength: d.maxLength - 1) { prefix in
            guard let length = d.length(for: prefix.count) else { throw Failure.badShape("prefix of \(prefix.count) tokens") }
            let tokens: MLMultiArray
            if let reused = inputs[length] {
                tokens = reused
            } else {
                tokens = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
                inputs[length] = tokens
            }
            return try self.nextLogits(prefix: prefix, tokens: tokens, states: states)
        }
        let candidates = hypotheses.map { h in
            MathCandidate(latex: LaTeXCleanup.clean(vocabulary.text(h.tokens)), score: h.meanLogProbability)
        }
        var unique: [MathCandidate] = []
        for cand in candidates where !cand.latex.isEmpty && !unique.contains(where: { $0.latex == cand.latex }) {
            unique.append(cand)
        }
        return MathRecognition(candidates: unique, engine: manifest.id, seconds: Date().timeIntervalSince(started))
    }

    /// The decoder's logits for the token after `prefix` (which starts with the start token).
    private func nextLogits(prefix: [Int], tokens: MLMultiArray, states: MLMultiArray) throws -> [Float] {
        let d = manifest.decoder
        let c = manifest.coreml
        let length = tokens.count
        guard !prefix.isEmpty, prefix.count <= length else { throw Failure.badShape("prefix of \(prefix.count) tokens") }
        tokens.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for i in 0..<length { buffer[i] = Int32(i < prefix.count ? prefix[i] : d.pad) }
        }
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            c.tokens: MLFeatureValue(multiArray: tokens), c.encoderStates: MLFeatureValue(multiArray: states),
        ]))
        guard let logits = out.featureValue(for: c.logits)?.multiArrayValue else { throw Failure.missingFeature(c.logits) }
        let shape = logits.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] >= prefix.count, shape[2] == d.vocabularySize else {
            throw Failure.badShape("logits \(shape)")
        }
        let strides = logits.strides.map(\.intValue)
        let row = (prefix.count - 1) * strides[1]
        var result = [Float](repeating: 0, count: d.vocabularySize)
        switch logits.dataType {
        case .float32:
            logits.withUnsafeBufferPointer(ofType: Float.self) { b in
                for v in 0..<d.vocabularySize { result[v] = b[row + v * strides[2]] }
            }
        default:
            for v in 0..<d.vocabularySize {
                result[v] = logits[[0, NSNumber(value: prefix.count - 1), NSNumber(value: v)]].floatValue
            }
        }
        return result
    }
}
#endif
