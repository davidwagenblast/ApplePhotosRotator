import Foundation

public struct LabeledFeatures: Sendable {
    public var features: [Float]
    /// Quarter turns clockwise the image needs, 0...3.
    public var label: Int

    public init(features: [Float], label: Int) {
        self.features = features
        self.label = label
    }
}

/// Trains an `OrientationClassifier` with mini-batch AdamW. Deterministic for a given seed.
public struct OrientationTrainer {
    public var hiddenSize = 128
    public var epochs = 30
    public var batchSize = 64
    public var learningRate: Float = 1e-3
    public var weightDecay: Float = 1e-4
    public var seed: UInt64 = 42

    public init() {}

    /// Trains on `samples`. When `validation` is non-empty, returns the epoch with the best validation accuracy.
    public func train(
        _ samples: [LabeledFeatures],
        validation: [LabeledFeatures] = [],
        log: (String) -> Void = { _ in }
    ) -> OrientationClassifier {
        precondition(!samples.isEmpty)
        let n = samples.count, d = samples[0].features.count, H = hiddenSize, C = OrientationClassifier.classCount
        let inner = H > 0 ? H : d

        // Standardise each input dimension.
        var mean = [Float](repeating: 0, count: d), variance = [Float](repeating: 0, count: d)
        for s in samples { for i in 0..<d { mean[i] += s.features[i] } }
        for i in 0..<d { mean[i] /= Float(n) }
        for s in samples { for i in 0..<d { let t = s.features[i] - mean[i]; variance[i] += t * t } }
        let scale = variance.map { 1 / max(($0 / Float(n)).squareRoot(), 1e-6) }
        var X = [Float](repeating: 0, count: n * d)
        for (k, s) in samples.enumerated() { for i in 0..<d { X[k * d + i] = (s.features[i] - mean[i]) * scale[i] } }
        let Y = samples.map(\.label)

        var rng = SplitMix64(seed: seed)
        var w1 = H > 0 ? (0..<(H * d)).map { _ in rng.normal() * (2 / Float(d)).squareRoot() } : []
        var b1 = [Float](repeating: 0, count: H)
        var w2 = (0..<(C * inner)).map { _ in rng.normal() * (1 / Float(inner)).squareRoot() }
        var b2 = [Float](repeating: 0, count: C)
        var adam = (w1: Adam(count: w1.count), b1: Adam(count: H), w2: Adam(count: w2.count), b2: Adam(count: C))

        var gw1 = [Float](repeating: 0, count: w1.count), gb1 = [Float](repeating: 0, count: H)
        var gw2 = [Float](repeating: 0, count: w2.count), gb2 = [Float](repeating: 0, count: C)
        var h = [Float](repeating: 0, count: inner), dh = [Float](repeating: 0, count: H)
        var order = Array(0..<n)
        var step = 0
        let totalSteps = epochs * ((n + batchSize - 1) / batchSize)

        func snapshot() -> OrientationClassifier {
            OrientationClassifier(inputSize: d, hiddenSize: H, mean: mean, scale: scale, w1: w1, b1: b1, w2: w2, b2: b2)
        }
        var best: (accuracy: Double, model: OrientationClassifier)?

        for epoch in 1...epochs {
            rng.shuffle(&order)
            var loss = 0.0, correct = 0
            for start in stride(from: 0, to: n, by: batchSize) {
                let batch = order[start..<min(start + batchSize, n)]
                for i in gw1.indices { gw1[i] = 0 }
                for i in gb1.indices { gb1[i] = 0 }
                for i in gw2.indices { gw2[i] = 0 }
                for i in gb2.indices { gb2[i] = 0 }

                X.withUnsafeBufferPointer { X in
                    w1.withUnsafeBufferPointer { w1 in
                        gw1.withUnsafeMutableBufferPointer { gw1 in
                            for k in batch {
                                let x = UnsafeBufferPointer(rebasing: X[(k * d)..<(k * d + d)])
                                // Forward.
                                if H > 0 {
                                    for j in 0..<H {
                                        var sum = b1[j]
                                        let row = j * d
                                        for i in 0..<d { sum += w1[row + i] * x[i] }
                                        h[j] = max(sum, 0)
                                    }
                                } else {
                                    for i in 0..<d { h[i] = x[i] }
                                }
                                var logits = [Double](repeating: 0, count: C)
                                for c in 0..<C {
                                    var sum = b2[c]
                                    for j in 0..<inner { sum += w2[c * inner + j] * h[j] }
                                    logits[c] = Double(sum)
                                }
                                let p = softmax(logits)
                                let y = Y[k]
                                loss -= Foundation.log(max(p[y], 1e-12))
                                if p.indices.max(by: { p[$0] < p[$1] }) == y { correct += 1 }

                                // Backward.
                                var dl = [Float](repeating: 0, count: C)
                                for c in 0..<C { dl[c] = Float(p[c]) - (c == y ? 1 : 0) }
                                for c in 0..<C {
                                    gb2[c] += dl[c]
                                    for j in 0..<inner { gw2[c * inner + j] += dl[c] * h[j] }
                                }
                                guard H > 0 else { continue }
                                for j in 0..<H {
                                    guard h[j] > 0 else { dh[j] = 0; continue }
                                    var sum: Float = 0
                                    for c in 0..<C { sum += w2[c * inner + j] * dl[c] }
                                    dh[j] = sum
                                }
                                for j in 0..<H where dh[j] != 0 {
                                    gb1[j] += dh[j]
                                    let row = j * d, g = dh[j]
                                    for i in 0..<d { gw1[row + i] += g * x[i] }
                                }
                            }
                        }
                    }
                }

                step += 1
                // Linear warm-down to 10% of the base rate.
                let lr = learningRate * (1 - 0.9 * Float(step) / Float(totalSteps))
                let inverseBatch = 1 / Float(batch.count)
                adam.w1.update(&w1, gradient: gw1, scale: inverseBatch, lr: lr, decay: weightDecay)
                adam.b1.update(&b1, gradient: gb1, scale: inverseBatch, lr: lr, decay: 0)
                adam.w2.update(&w2, gradient: gw2, scale: inverseBatch, lr: lr, decay: weightDecay)
                adam.b2.update(&b2, gradient: gb2, scale: inverseBatch, lr: lr, decay: 0)
            }

            var message = String(format: "epoch %d: loss %.4f, train accuracy %.2f%%", epoch, loss / Double(n), 100 * Double(correct) / Double(n))
            if !validation.isEmpty {
                let model = snapshot()
                let accuracy = model.accuracy(on: validation)
                message += String(format: ", validation accuracy %.2f%%", 100 * accuracy)
                if accuracy > (best?.accuracy ?? -1) { best = (accuracy, model) }
            }
            log(message)
        }
        return best?.model ?? snapshot()
    }
}

extension OrientationClassifier {
    public func accuracy(on samples: [LabeledFeatures]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let correct = samples.filter { s in
            let p = probabilities(s.features)
            return p.indices.max(by: { p[$0] < p[$1] }) == s.label
        }.count
        return Double(correct) / Double(samples.count)
    }
}

private struct Adam {
    var m: [Float], v: [Float], t: Float = 0
    let beta1: Float = 0.9, beta2: Float = 0.999, epsilon: Float = 1e-8

    init(count: Int) {
        m = [Float](repeating: 0, count: count)
        v = [Float](repeating: 0, count: count)
    }

    mutating func update(_ w: inout [Float], gradient g: [Float], scale: Float, lr: Float, decay: Float) {
        t += 1
        let c1 = 1 - pow(beta1, t), c2 = 1 - pow(beta2, t)
        for i in w.indices {
            let gi = g[i] * scale
            m[i] = beta1 * m[i] + (1 - beta1) * gi
            v[i] = beta2 * v[i] + (1 - beta2) * gi * gi
            w[i] -= lr * ((m[i] / c1) / ((v[i] / c2).squareRoot() + epsilon) + decay * w[i])
        }
    }
}

/// Small, fast, seedable random numbers so training is reproducible.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal via Box–Muller.
    public mutating func normal() -> Float {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12), u2 = Double.random(in: 0..<1, using: &self)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }

    public mutating func shuffle<T>(_ array: inout [T]) {
        array.shuffle(using: &self)
    }
}
