// Trains the built-in scene orientation model.
//
//   train-orientation-model --images DIR --cache FILE[,FILE…] --output FILE [--landscapes FILE]
//                           [--hidden N --decay X] [--epochs 30]
//   train-orientation-model --images DIR --cache FILE --shard I/N --extract-only yes
//
// Feature extraction is slow on CI machines, so it can be split into N shards run in parallel, each writing its own
// cache file; the training run then reads all of them. New features are appended to the first cache file.
//
// Every photo in DIR is assumed to be upright. Each one is shown to Vision turned all four ways, so the labels come
// for free. Photos are split by name into training (75%), validation (10%) and test (15%) sets; the test photos are
// never seen during training and are scored through the same decision logic the app uses.

import Foundation
import ImageIO
import RotatorCore
import RotatorVision

// MARK: Options

var options: [String: String] = [:]
var argumentIterator = CommandLine.arguments.dropFirst().makeIterator()
while let key = argumentIterator.next() {
    guard key.hasPrefix("--"), let value = argumentIterator.next() else {
        FileHandle.standardError.write("Unexpected argument \(key)\n".data(using: .utf8)!)
        exit(2)
    }
    options[String(key.dropFirst(2))] = value
}
let extractOnly = options["extract-only"] != nil
guard let imagesDir = options["images"], let cacheList = options["cache"], extractOnly || options["output"] != nil else {
    print("usage: train-orientation-model --images DIR --cache FILE[,FILE…] (--output FILE | --extract-only yes) [--shard I/N] [--landscapes FILE] [--hidden N --decay X] [--epochs N]")
    exit(2)
}
let cachePaths = cacheList.split(separator: ",").map(String.init)
let cachePath = cachePaths[0]
let shard: (index: Int, count: Int) = {
    let parts = (options["shard"] ?? "0/1").split(separator: "/").compactMap { Int($0) }
    return parts.count == 2 && parts[1] > 0 ? (parts[0], parts[1]) : (0, 1)
}()
let landscapeNames = Set((options["landscapes"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
    .split(whereSeparator: \.isNewline).map(String.init))

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

// MARK: Feature cache
// Each record: UInt16 name length, UTF-8 name, then 4 × dimension Float32 — the features of the photo turned so it
// needs 0, 1, 2 and 3 quarter turns clockwise. A record of all zeros marks a photo that could not be used.
// The dimension is fixed by SceneFeatures, so a change there needs a new cache file name.

let dimension = SceneFeatures.dimension

func loadThumbnail(_ name: String) -> CGImage? {
    let url = URL(fileURLWithPath: imagesDir).appendingPathComponent(name)
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 768,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
}
var features: [String: [[Float]]] = [:]

for path in cachePaths {
    guard let data = FileManager.default.contents(atPath: path) else { continue }
    var offset = 0
    let recordFloats = 4 * dimension
    while offset + 2 <= data.count {
        let length = Int(data[offset]) | Int(data[offset + 1]) << 8
        let end = offset + 2 + length + recordFloats * 4
        guard end <= data.count, let name = String(data: data[(offset + 2)..<(offset + 2 + length)], encoding: .utf8) else { break }
        let floats: [Float] = data[(offset + 2 + length)..<end].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        features[name] = (0..<4).map { Array(floats[($0 * dimension)..<(($0 + 1) * dimension)]) }
        offset = end
    }
    log("Loaded cached features from \(path): \(features.count) photos so far")
}

let allNames = ((try? FileManager.default.contentsOfDirectory(atPath: imagesDir)) ?? [])
    .filter { $0.lowercased().hasSuffix(".jpg") }
    .sorted()
let missing = allNames.enumerated()
    .filter { $0.offset % shard.count == shard.index && features[$0.element] == nil }
    .map(\.element)
log("\(allNames.count) photos; shard \(shard.index + 1) of \(shard.count) has \(missing.count) needing feature extraction")

if !missing.isEmpty {
    if !FileManager.default.fileExists(atPath: cachePath) {
        FileManager.default.createFile(atPath: cachePath, contents: nil)
    }
    let cacheHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: cachePath))
    try cacheHandle.seekToEnd()
    let lock = NSLock()
    var done = 0
    let started = Date()

    DispatchQueue.concurrentPerform(iterations: missing.count) { index in
        let name = missing[index]
        let vectors: [[Float]] = autoreleasepool {
            guard let image = loadThumbnail(name) else { return [] }
            var result: [[Float]] = []
            for quarterTurns in 0..<4 {
                // To make a frame that needs `c` clockwise, turn the upright photo by the inverse of `c`.
                let needed = Rotation(degrees: 90 * quarterTurns)
                guard let vector = try? SceneFeatures.features(of: image, rotatedBy: needed.inverse) else { return [] }
                result.append(vector)
            }
            return result
        }
        let stored = vectors.count == 4 ? vectors : Array(repeating: [Float](repeating: 0, count: dimension), count: 4)

        var record = Data()
        let nameData = name.data(using: .utf8)!
        record.append(UInt8(nameData.count & 0xFF))
        record.append(UInt8(nameData.count >> 8))
        record.append(nameData)
        for vector in stored { vector.withUnsafeBytes { record.append(contentsOf: $0) } }

        lock.lock()
        features[name] = stored
        cacheHandle.write(record)
        done += 1
        if done % 500 == 0 || done == missing.count {
            let rate = Double(done) / Date().timeIntervalSince(started)
            log(String(format: "  features: %d/%d (%.1f photos/s)", done, missing.count, rate))
        }
        lock.unlock()
    }
    try cacheHandle.close()
}

if extractOnly {
    log("Extraction finished")
    exit(0)
}
let outputPath = options["output"]!

// MARK: Layout grids (cheap, so recomputed every run rather than cached)

var grids: [String: [Float]] = [:]
do {
    let lock = NSLock()
    let names = allNames.filter { features[$0] != nil }
    DispatchQueue.concurrentPerform(iterations: names.count) { index in
        let name = names[index]
        let grid: [Float]? = autoreleasepool {
            guard let image = loadThumbnail(name) else { return nil }
            return SceneGrid.rgb(of: image)
        }
        lock.lock()
        grids[name] = grid
        lock.unlock()
    }
    log("Computed layout grids for \(grids.count) photos")
}

/// Model input for the photo turned so that it needs `quarterTurns` clockwise: feature print + layout features.
func input(_ name: String, needing quarterTurns: Int) -> [Float] {
    let needed = Rotation(degrees: 90 * quarterTurns)
    return features[name]![quarterTurns] + GridFeatures.features(grids[name]!, rotatedBy: needed.inverse)
}

// MARK: Split

/// FNV-1a, so a photo always lands in the same split however many photos there are.
func bucket(_ name: String) -> Int {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    return Int(hash % 100)
}

let usable = allNames.filter { name in
    grids[name] != nil && (features[name].map { !$0[0].allSatisfy { $0 == 0 } } ?? false)
}
let testNames = usable.filter { bucket($0) < 15 }
let validationNames = usable.filter { (15..<25).contains(bucket($0)) }
let trainNames = usable.filter { bucket($0) >= 25 }
log("Usable photos: \(usable.count) — train \(trainNames.count), validation \(validationNames.count), test \(testNames.count)")

func samples(_ names: [String]) -> [LabeledFeatures] {
    names.flatMap { name in (0..<4).map { LabeledFeatures(features: input(name, needing: $0), label: $0) } }
}

// MARK: Train

// Several sizes and regularisation strengths; the one with the best validation accuracy is kept.
let trainingSet = samples(trainNames), validationSet = samples(validationNames)
var configurations: [(hidden: Int, decay: Float)] = [(0, 1e-3), (128, 1e-2), (256, 5e-2)]
if let hidden = options["hidden"].flatMap(Int.init) { configurations = [(hidden, Float(options["decay"] ?? "") ?? 1e-2)] }
var trainer = OrientationTrainer()
trainer.epochs = Int(options["epochs"] ?? "") ?? 30
var model: OrientationClassifier!
var bestValidation = -1.0
for configuration in configurations {
    var candidateTrainer = trainer
    candidateTrainer.hiddenSize = configuration.hidden
    candidateTrainer.weightDecay = configuration.decay
    log("Training: hidden \(configuration.hidden), weight decay \(configuration.decay), epochs \(trainer.epochs)")
    let started = Date()
    let candidate = candidateTrainer.train(trainingSet, validation: validationSet) { _ in }
    let accuracy = candidate.accuracy(on: validationSet)
    log(String(format: "  → validation accuracy %.2f%% (%.0f s)", 100 * accuracy, Date().timeIntervalSince(started)))
    if accuracy > bestValidation {
        bestValidation = accuracy
        model = candidate
        trainer = candidateTrainer
    }
}

// MARK: Evaluate on the held-out test photos, through the app's decision logic

var everything = OrientationEvaluation(weight: 0.9)
var landscapes = OrientationEvaluation(weight: 0.9)
for name in testNames {
    let probabilities = (0..<4).map { model.probabilities(input(name, needing: $0)) }
    everything.add(probabilities)
    if landscapeNames.contains(name) { landscapes.add(probabilities) }
}

let testAccuracy = model.accuracy(on: samples(testNames))
let summary = """
Scene orientation model: Vision feature print revision 2 + 8×8 colour and edge layout → \(trainer.hiddenSize > 0 ? "\(trainer.hiddenSize)-unit hidden layer" : "linear") (weight decay \(trainer.weightDecay)) → 4 classes.
Trained on \(trainNames.count) photos (×4 rotations); validated on \(validationNames.count); tested on \(testNames.count) held-out photos.
Single-pass test accuracy: \(String(format: "%.1f%%", 100 * testAccuracy)).

\(everything.report(title: "All test photos"))

\(landscapes.report(title: "Landscape test photos (\(testNames.filter { landscapeNames.contains($0) }.count) photos)"))
"""
log("\n" + summary)

// MARK: Write the weights into the app

let indentedSummary = summary.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
let source = """
// Generated by `swift run -c release train-orientation-model`. Do not edit by hand.
// See .github/workflows/train-scene-model.yml.
enum SceneModelWeights {
    static let summary = #\"\"\"
\(indentedSummary)
    \"\"\"#

    static let encoded = "\(model.encoded().base64EncodedString())"
}

"""
try source.write(toFile: outputPath, atomically: true, encoding: .utf8)
log("Wrote \(outputPath)")
