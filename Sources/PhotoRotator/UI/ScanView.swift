import SwiftUI
import UniformTypeIdentifiers

struct ScanView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var choosingModel = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Photos in library", value: model.libraryCount.formatted())
                LabeledContent("Scanned so far", value: model.counts.total.formatted())
                scanControls
            } header: {
                Text("Scan")
            } footer: {
                Text("Results are saved as the scan runs. Stop at any time; the next scan resumes where it left off and only re-checks photos that changed.")
            }

            if let progress = model.progress {
                Section("This run") { ProgressSummary(progress: progress, isRunning: model.isScanning) }
            }

            Section("Results") {
                CountRow(label: "Need rotating (awaiting review)", value: model.counts.needsRotation, systemImage: "rotate.right", tint: .orange)
                CountRow(label: "Already upright", value: model.counts.upright, systemImage: "checkmark.circle", tint: .green)
                CountRow(label: "Not enough to judge", value: model.counts.inconclusive, systemImage: "questionmark.circle", tint: .secondary)
                CountRow(label: "Not available locally", value: model.counts.unavailable, systemImage: "icloud", tint: .secondary)
                CountRow(label: "Errors", value: model.counts.failed, systemImage: "exclamationmark.triangle", tint: .red)
                CountRow(label: "Rotated by this app", value: model.counts.applied, systemImage: "checkmark.seal", tint: .blue)
                HStack {
                    Button("Review \(model.reviewItems.count.formatted()) Photos") { model.screen = .review }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.reviewItems.isEmpty)
                    Spacer()
                    Button("Forget All Results…", role: .destructive) { confirmReset = true }
                        .disabled(model.isScanning)
                }
            }

            Section {
                Toggle("Faces", isOn: $model.settings.useFaces)
                Toggle("People (body pose)", isOn: $model.settings.useBodyPose)
                Toggle("Text", isOn: $model.settings.useText)
                Toggle(isOn: $model.settings.useScene) {
                    Text("Landscapes, buildings and other scenes")
                    Text(OrientationNetDetector.isAvailable
                        ? "Built-in orientation network, trained to tell which way any photo is turned."
                        : SceneDetector.builtIn != nil
                            ? "Built-in scene model: sky above ground, buildings and trees pointing up."
                            : "No scene model is included in this build.")
                }
                .disabled(!OrientationNetDetector.isAvailable && SceneDetector.builtIn == nil)
                LabeledContent("Core ML orientation model") {
                    HStack {
                        Text(model.settings.modelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Choose…") { choosingModel = true }
                        if model.settings.modelPath != nil {
                            Button("Remove") { model.settings.modelPath = nil }
                        }
                    }
                }
            } header: {
                Text("What to look for")
            } footer: {
                Text("Faces are the most reliable cue. The scene model covers photos without people or text, but some photos — close-ups, textures, shots taken straight down — have no clear up, and those are left alone as \"not enough to judge\".")
            }

            Section("Speed") {
                Picker("Analysis size", selection: $model.settings.analysisSize) {
                    Text("Small – fastest (512 px)").tag(512)
                    Text("Medium (768 px)").tag(768)
                    Text("Large – finds smaller faces and text (1024 px)").tag(1024)
                }
                Stepper("Photos in parallel: \(model.settings.concurrency)", value: $model.settings.concurrency, in: 1...16)
            }

            Section {
                Toggle("Skip screenshots", isOn: $model.settings.skipScreenshots)
                Toggle("Skip photos that already have edits", isOn: $model.settings.skipEditedPhotos)
                Toggle("Download iCloud photos that aren't on this Mac", isOn: $model.settings.allowNetworkForAnalysis)
            } header: {
                Text("Which photos")
            } footer: {
                Text("Settings apply to the next scan.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget all scan results?", isPresented: $confirmReset) {
            Button("Forget Results", role: .destructive) { Task { await model.resetResults() } }
        } message: {
            Text("The next scan will check every photo again. Rotations already applied stay in Photos.")
        }
        .fileImporter(isPresented: $choosingModel, allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { model.settings.modelPath = url.path }
        }
    }

    @ViewBuilder private var scanControls: some View {
        HStack {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…")
                Spacer()
                Button("Stop") { model.stopScan() }
            } else {
                Button(model.counts.total == 0 ? "Start Scan" : "Scan New & Remaining Photos") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }
}

private struct ProgressSummary: View {
    var progress: ScanProgress
    var isRunning: Bool

    var body: some View {
        ProgressView(value: progress.fraction) {
            Text("\(progress.visited.formatted()) of \(progress.total.formatted()) photos")
        } currentValueLabel: {
            Text(detail)
        }
        LabeledContent("Analysed", value: progress.analyzed.formatted())
        LabeledContent("Skipped (already scanned or excluded)", value: progress.skipped.formatted())
        LabeledContent("Found needing rotation", value: progress.found.formatted())
    }

    private var detail: String {
        guard isRunning else { return "Finished" }
        var parts = [String(format: "%.1f photos/s", progress.photosPerSecond)]
        if let remaining = progress.estimatedSecondsRemaining {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = remaining > 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .abbreviated
            parts.append("about \(formatter.string(from: remaining) ?? "?") left")
        }
        return parts.joined(separator: " · ")
    }
}

private struct CountRow: View {
    var label: String
    var value: Int
    var systemImage: String
    var tint: Color

    var body: some View {
        LabeledContent {
            Text(value.formatted()).monospacedDigit()
        } label: {
            Label { Text(label) } icon: { Image(systemName: systemImage).foregroundStyle(tint) }
        }
    }
}
