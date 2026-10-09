// Evaluates the converted Core ML orientation network through the same Vision path the app uses.
//
//   evaluate-orientation-net --model OrientationNet.mlpackage --images DIR --names FILE
//                            [--landscapes FILE] [--output FILE]
//
// Each listed photo is assumed upright and tested in all four orientations, scored by the app's four-pass averaging
// and decision logic.

import Foundation
import ImageIO
import RotatorCore
import RotatorVision

var options: [String: String] = [:]
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let key = iterator.next() {
    guard key.hasPrefix("--"), let value = iterator.next() else { print("Unexpected argument \(key)"); exit(2) }
    options[String(key.dropFirst(2))] = value
}
guard let modelPath = options["model"], let imagesDir = options["images"], let namesPath = options["names"] else {
    print("usage: evaluate-orientation-net --model PATH --images DIR --names FILE [--landscapes FILE] [--output FILE]")
    exit(2)
}

func lines(_ path: String?) -> [String] {
    (path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
        .split(whereSeparator: \.isNewline).map(String.init)
}

let names = lines(namesPath)
let landscapeNames = Set(lines(options["landscapes"]))
let network = try OrientationNetwork.load(from: URL(fileURLWithPath: modelPath))
print("Evaluating \(names.count) photos")

let lock = NSLock()
var results: [String: [[Double]]] = [:]
DispatchQueue.concurrentPerform(iterations: names.count) { index in
    let name = names[index]
    let probabilities: [[Double]]? = autoreleasepool {
        let url = URL(fileURLWithPath: imagesDir).appendingPathComponent(name)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return nil }
        var all: [[Double]] = []
        for quarterTurns in 0..<4 {
            // To make a frame that needs `c` clockwise, turn the upright photo by the inverse of `c`.
            let needed = Rotation(degrees: 90 * quarterTurns)
            guard let p = try? network.probabilities(of: image, rotatedBy: needed.inverse) else { return nil }
            all.append(p)
        }
        return all
    }
    lock.lock()
    results[name] = probabilities
    if results.count % 500 == 0 { print("  \(results.count)/\(names.count)") }
    lock.unlock()
}

// The same predictions scored under different assumptions about how common each turn is.
let variants: [(name: String, prior: OrientationPrior, agreement: Bool)] = [
    ("As trained: all four turns equally likely", .equal, false),
    ("As trained, and all four passes must agree", .equal, true),
    ("Prior: 90% upright, 4.5% each sideways, 1% upside down", OrientationPrior(upright: 0.90, sideways: 0.045, upsideDown: 0.01), false),
    ("Prior: 97% upright, 1.35% each sideways, 0.3% upside down", OrientationPrior(upright: 0.97, sideways: 0.0135, upsideDown: 0.003), false),
    ("Prior: 99% upright, 0.45% each sideways, 0.1% upside down", OrientationPrior(upright: 0.99, sideways: 0.0045, upsideDown: 0.001), false),
    ("Prior: 97% upright …, and all four passes must agree", OrientationPrior(upright: 0.97, sideways: 0.0135, upsideDown: 0.003), true),
]
var evaluations = variants.map { OrientationEvaluation(weight: 1.0, prior: $0.prior, requireAgreement: $0.agreement) }
var landscapeEvaluations = evaluations
var correctSingle = 0, totalSingle = 0, landscapeCount = 0
for name in names {
    guard let p = results[name] else { continue }
    for i in evaluations.indices { evaluations[i].add(p) }
    if landscapeNames.contains(name) {
        for i in landscapeEvaluations.indices { landscapeEvaluations[i].add(p) }
        landscapeCount += 1
    }
    for (needed, probabilities) in p.enumerated() {
        totalSingle += 1
        if probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) == needed { correctSingle += 1 }
    }
}

var sections = [
    "Core ML model, run through Vision as in the app, on \(results.count) held-out photos.",
    "Single-pass accuracy: \(String(format: "%.1f%%", 100 * Double(correctSingle) / Double(max(totalSingle, 1)))).",
]
for (i, variant) in variants.enumerated() {
    sections.append("")
    sections.append("### \(variant.name)")
    sections.append(evaluations[i].report(title: "All test photos"))
    sections.append(landscapeEvaluations[i].report(title: "Landscape test photos (\(landscapeCount) photos)"))
}
let report = sections.joined(separator: "\n")
print("\n" + report)
if let output = options["output"] {
    try report.write(toFile: output, atomically: true, encoding: .utf8)
}
