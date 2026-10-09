import SwiftUI
import UniformTypeIdentifiers

struct ScanView: View {
    @Environment(AppModel.self) private var model
    // `State` is used directly instead of `@State`: with recent SDKs `@State` is a macro, and Apple's Command Line
    // Tools (without Xcode) can't expand it. This is exactly what `@State` stands for.
    private var _confirmReset = State<Bool>(wrappedValue: false)
    private var confirmReset: Bool {
        get { _confirmReset.wrappedValue }
        nonmutating set { _confirmReset.wrappedValue = newValue }
    }
    private var _choosingModel = State<Bool>(wrappedValue: false)
    private var choosingModel: Bool {
        get { _choosingModel.wrappedValue }
        nonmutating set { _choosingModel.wrappedValue = newValue }
    }
    private var _confirmUndo = State<Bool>(wrappedValue: false)
    private var confirmUndo: Bool {
        get { _confirmUndo.wrappedValue }
        nonmutating set { _confirmUndo.wrappedValue = newValue }
    }

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
                    if model.counts.applied > 0 {
                        Button("Undo All Rotations…") { confirmUndo = true }
                            .disabled(model.isUndoing || model.isApplying)
                    }
                    Button("Forget All Results…", role: .destructive) { confirmReset = true }
                        .disabled(model.isScanning)
                }
                if model.isUndoing {
                    HStack { ProgressView().controlSize(.small); Text("Returning photos to their originals…") }
                }
                if let message = model.undoMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Faces", isOn: $model.settings.useFaces)
                Toggle("People (body pose)", isOn: $model.settings.useBodyPose)
                Toggle("Text", isOn: $model.settings.useText)
                Toggle(isOn: $model.settings.useScene) {
                    Text("Landscapes, buildings and other scenes")
                    Text(sceneStatus)
                }
                .disabled(!OrientationNetDetector.isAvailable && SceneDetector.builtIn == nil)
            } header: {
                Text("What to look for")
            } footer: {
                Text("Faces are the most reliable cue. The scene model covers photos without people or text, but some photos — close-ups, textures, shots taken straight down — have no clear up, and those are left alone as \"not enough to judge\".")
            }

            Section {
                LabeledContent("Extra Core ML model") {
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
                Text("Advanced")
            } footer: {
                Text("Not needed: the orientation network above is built in. This is only for adding your own Core ML orientation classifier on top of it.")
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
                Text("Settings apply to the next scan. Photos that weren't available locally are tried again on every scan.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Undo all rotations made by Photo Rotator?", isPresented: _confirmUndo.projectedValue) {
            Button("Revert \(model.counts.applied.formatted()) Photos to Original", role: .destructive) {
                Task { await model.undoAllRotations() }
            }
        } message: {
            Text("Each photo this app rotated goes back to its original, as with Image › Revert to Original in Photos. That also removes any other edits on those photos, such as crops or filters, whether made before or after the rotation.")
        }
        .confirmationDialog("Forget all scan results?", isPresented: _confirmReset.projectedValue) {
            Button("Forget Results", role: .destructive) { Task { await model.resetResults() } }
        } message: {
            Text("The next scan will check every photo again. Rotations already applied stay in Photos.")
        }
        .fileImporter(isPresented: _choosingModel.projectedValue, allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { model.settings.modelPath = url.path }
        }
    }

    private var sceneStatus: String {
        if OrientationNetDetector.isAvailable {
            switch model.networkReady {
            case true?: return "Built-in orientation network: ready."
            case false?: return SceneDetector.builtIn != nil
                ? "The built-in orientation network couldn't be loaded, so the lighter scene model is used. Try reinstalling."
                : "The built-in orientation network couldn't be loaded. Try reinstalling."
            case nil: return "Built-in orientation network: loading…"
            }
        }
        return SceneDetector.builtIn != nil
            ? "Built-in scene model (this build doesn't include the orientation network)."
            : "No scene model is included in this build."
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
