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

var everything = OrientationEvaluation(weight: 1.0)
var landscapes = OrientationEvaluation(weight: 1.0)
var correctSingle = 0, totalSingle = 0, landscapeCount = 0
for name in names {
    guard let p = results[name] else { continue }
    everything.add(p)
    if landscapeNames.contains(name) {
        landscapes.add(p)
        landscapeCount += 1
    }
    for (needed, probabilities) in p.enumerated() {
        totalSingle += 1
        if probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) == needed { correctSingle += 1 }
    }
}

let report = """
Core ML model, run through Vision as in the app, on \(results.count) held-out photos.
Single-pass accuracy: \(String(format: "%.1f%%", 100 * Double(correctSingle) / Double(max(totalSingle, 1)))).

\(everything.report(title: "All test photos"))

\(landscapes.report(title: "Landscape test photos (\(landscapeCount) photos)"))
"""
print("\n" + report)
if let output = options["output"] {
    try report.write(toFile: output, atomically: true, encoding: .utf8)
}
