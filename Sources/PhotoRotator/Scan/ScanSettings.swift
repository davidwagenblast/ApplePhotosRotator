import Foundation

struct ScanSettings: Codable, Equatable, Sendable {
    var useFaces = true
    var useBodyPose = true
    var useText = true
    /// The built-in scene model, for photos without people or text (landscapes, buildings, objects).
    var useScene = true
    /// Optional Core ML orientation classifier (see README).
    var modelPath: String?

    /// Long edge, in pixels, of the image handed to Vision. Larger finds smaller faces and text but is slower.
    var analysisSize = 768
    /// Photos analysed in parallel.
    var concurrency = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

    var skipScreenshots = true
    /// Photos that already have edits in Photos. Rotating them bakes those edits into the new version
    /// (Revert to Original still restores the untouched original).
    var skipEditedPhotos = false
    /// Download iCloud-only photos to analyse them. Off: such photos are analysed from the local thumbnail if
    /// Photos has one, otherwise reported as unavailable.
    var allowNetworkForAnalysis = false

    private static let key = "ScanSettings.v1"

    static func load() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
