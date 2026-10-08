import Foundation

/// A small neural network that reads an image's feature vector and estimates which correction the image needs.
///
/// Output `c` (0...3) is the probability that the image needs `c` quarter turns clockwise to be upright.
/// With `hiddenSize == 0` it is plain softmax regression.
public struct OrientationClassifier: Sendable, Equatable {
    public static let classCount = 4

    public var inputSize: Int
    public var hiddenSize: Int
    /// Inputs are standardised as `(x - mean) * scale` before the first layer.
    public var mean: [Float]
    public var scale: [Float]
    /// Row-major `hiddenSize × inputSize`; empty when `hiddenSize == 0`.
    public var w1: [Float]
    public var b1: [Float]
    /// Row-major `classCount × (hiddenSize, or inputSize when there is no hidden layer)`.
    public var w2: [Float]
    public var b2: [Float]

    public init(inputSize: Int, hiddenSize: Int, mean: [Float], scale: [Float],
                w1: [Float], b1: [Float], w2: [Float], b2: [Float]) {
        self.inputSize = inputSize
        self.hiddenSize = hiddenSize
        self.mean = mean
        self.scale = scale
        self.w1 = w1
        self.b1 = b1
        self.w2 = w2
        self.b2 = b2
    }

    var outputInputSize: Int { hiddenSize > 0 ? hiddenSize : inputSize }

    public func probabilities(_ features: [Float]) -> [Double] {
        precondition(features.count == inputSize, "expected \(inputSize) features, got \(features.count)")
        var x = [Float](repeating: 0, count: inputSize)
        for i in 0..<inputSize { x[i] = (features[i] - mean[i]) * scale[i] }

        var h = x
        if hiddenSize > 0 {
            h = [Float](repeating: 0, count: hiddenSize)
            w1.withUnsafeBufferPointer { w in
                for j in 0..<hiddenSize {
                    var sum = b1[j]
                    let row = j * inputSize
                    for i in 0..<inputSize { sum += w[row + i] * x[i] }
                    h[j] = max(sum, 0)
                }
            }
        }
        let n = outputInputSize
        var logits = [Double](repeating: 0, count: Self.classCount)
        for c in 0..<Self.classCount {
            var sum = b2[c]
            for j in 0..<n { sum += w2[c * n + j] * h[j] }
            logits[c] = Double(sum)
        }
        return softmax(logits)
    }

    /// Scores for each correction from one analysis pass, for averaging over the four passes.
    ///
    /// In the pass where Vision rotated the photo by `pass`, output `c` means the photo needs `pass + c` overall.
    /// Averaging over all four passes cancels out the model's own direction biases.
    public static func passScores(_ probabilities: [Double], pass: Rotation, passCount: Int = 4) -> [Rotation: Double] {
        var scores: [Rotation: Double] = [:]
        for (c, p) in probabilities.enumerated() {
            scores[Rotation(degrees: pass.degrees + 90 * c), default: 0] += p / Double(passCount)
        }
        return scores
    }

    // MARK: Serialisation (little-endian: 4 × Int32 header, then the Float32 arrays in declaration order)

    private static let magic: Int32 = 0x524F_5431 // "ROT1"

    public enum DecodingError: Error { case badHeader, truncated }

    public func encoded() -> Data {
        var data = Data()
        for value in [Self.magic, 1, Int32(inputSize), Int32(hiddenSize)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        for array in [mean, scale, w1, b1, w2, b2] {
            for value in array {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        func int32() throws -> Int32 {
            guard offset + 4 <= bytes.count else { throw DecodingError.truncated }
            let value = bytes[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            offset += 4
            return Int32(bitPattern: value)
        }
        func floats(_ count: Int) throws -> [Float] {
            var result = [Float]()
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(Float(bitPattern: UInt32(bitPattern: try int32()))) }
            return result
        }
        guard try int32() == Self.magic, try int32() == 1 else { throw DecodingError.badHeader }
        let input = Int(try int32()), hidden = Int(try int32())
        guard input > 0, hidden >= 0 else { throw DecodingError.badHeader }
        let output = hidden > 0 ? hidden : input
        self.init(
            inputSize: input, hiddenSize: hidden,
            mean: try floats(input), scale: try floats(input),
            w1: try floats(hidden * input), b1: try floats(hidden),
            w2: try floats(Self.classCount * output), b2: try floats(Self.classCount)
        )
        guard offset == bytes.count else { throw DecodingError.truncated }
    }
}

func softmax(_ logits: [Double]) -> [Double] {
    let top = logits.max() ?? 0
    let exps = logits.map { exp($0 - top) }
    let total = exps.reduce(0, +)
    return exps.map { $0 / total }
}
