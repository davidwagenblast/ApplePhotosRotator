import Photos
import RotatorCore
import SwiftUI

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmApply = false
    @State private var previewItem: ReviewItem?

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            ReviewToolbar(confirmApply: $confirmApply)
            Divider()
            if model.isLoadingReview && model.reviewItems.isEmpty {
                ProgressView("Loading proposals…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleItems.isEmpty {
                ContentUnavailableView(
                    model.reviewItems.isEmpty ? "Nothing to review" : "No photos match the filter",
                    systemImage: "checkmark.circle",
                    description: Text(model.reviewItems.isEmpty
                        ? "Run a scan to find photos that need rotating."
                        : "Lower the minimum confidence or clear the rotation filter.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.visibleItems) { item in
                            ReviewCell(item: item, onPreview: { previewItem = item })
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $previewItem) { item in
            PreviewSheet(item: item)
        }
        .sheet(isPresented: Binding(get: { model.applyProgress != nil }, set: { _ in })) {
            ApplySheet()
        }
        .confirmationDialog(
            "Rotate \(model.selectedVisibleItems.count.formatted()) photos?",
            isPresented: $confirmApply
        ) {
            Button("Rotate \(model.selectedVisibleItems.count.formatted()) Photos") { model.applySelected() }
        } message: {
            Text("Each photo gets a rotated edited version in Photos. Originals, dates, locations, albums and other metadata are kept, and Image › Revert to Original in Photos undoes the rotation.")
        }
    }
}

private struct ReviewToolbar: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmApply: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.visibleItems.count.formatted()) photos to review")
                    .font(.headline)
                Text("\(model.selection.count.formatted()) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 30)
            Button("Select All") { model.selectAll() }
            Button("Select None") { model.selectNone() }
                .disabled(model.selection.isEmpty)
            Divider().frame(height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Minimum confidence: \(Int(model.minimumConfidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $model.minimumConfidence, in: 0.2...0.95, step: 0.05)
                    .frame(width: 160)
            }
            Picker("Rotation", selection: $model.rotationFilter) {
                Text("All rotations").tag(nil as Rotation?)
                ForEach(Rotation.corrections, id: \.self) { rotation in
                    Text(rotation.label).tag(Rotation?.some(rotation))
                }
            }
            .frame(width: 250)
            Spacer()
            Button(model.diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") {
                Task { await model.copyDiagnostics() }
            }
            .help("Copy a text report about the proposals shown (no photos or names) to paste into a bug report.")
            Button("Hide Selected") { Task { await model.dismissSelected() } }
                .help("Mark the selected photos as correct so they stop appearing here.")
                .disabled(model.selection.isEmpty)
            Button("Apply to \(model.selection.count.formatted()) Selected") { confirmApply = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || model.isApplying)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct ReviewCell: View {
    @Environment(AppModel.self) private var model
    var item: ReviewItem
    var onPreview: () -> Void

    var body: some View {
        let selected = model.selection.contains(item.id)
        let rotation = model.rotation(for: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(spacing: 2) {
                    AssetThumbnail(asset: item.asset, rotation: .none, side: 90)
                    Text("Now").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    AssetThumbnail(asset: item.asset, rotation: rotation, side: 130)
                    Text("Proposed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onPreview)
            .onTapGesture { model.toggle(item) }

            HStack {
                Toggle(isOn: Binding(get: { selected }, set: { _ in model.toggle(item) })) {
                    Text("Apply").font(.callout.weight(.medium))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Menu(rotation.shortLabel) {
                    ForEach(Rotation.corrections, id: \.self) { option in
                        Button {
                            model.setOverride(option, for: item)
                        } label: {
                            if option == rotation { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change the proposed rotation")
            }
            HStack(spacing: 6) {
                ConfidenceBadge(confidence: item.confidence)
                Text(item.evidence)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.evidence)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
        )
    }
}

private struct ConfidenceBadge: View {
    var confidence: Double

    var body: some View {
        Text("\(Int((confidence * 100).rounded()))%")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .help("How strongly the detectors agree on this rotation")
    }

    private var color: Color {
        confidence >= 0.8 ? .green : confidence >= 0.5 ? .orange : .red
    }
}

/// A square thumbnail of the photo as Photos currently shows it, optionally previewing a rotation.
/// Because the frame is square, the rotated image always still fits.
struct AssetThumbnail: View {
    var asset: PHAsset
    var rotation: Rotation
    var side: CGFloat
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(Double(rotation.degrees)))
                    .animation(.easeInOut(duration: 0.2), value: rotation)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: asset.localIdentifier) {
            image = await ThumbnailProvider.shared.thumbnail(for: asset, pixelSize: max(side * displayScale, 160))
        }
    }
}

private struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var item: ReviewItem

    var body: some View {
        let rotation = model.rotation(for: item)
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                VStack {
                    AssetThumbnail(asset: item.asset, rotation: .none, side: 380)
                    Text("Now").foregroundStyle(.secondary)
                }
                VStack {
                    AssetThumbnail(asset: item.asset, rotation: rotation, side: 380)
                    Text("Proposed: \(rotation.label)").foregroundStyle(.secondary)
                }
            }
            if let date = item.asset.creationDate {
                Text(date.formatted(date: .long, time: .shortened)).font(.callout)
            }
            Text(item.evidence).font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Apply this rotation", isOn: Binding(
                    get: { model.selection.contains(item.id) },
                    set: { _ in model.toggle(item) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

private struct ApplySheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isApplying {
                Text("Rotating photos…").font(.headline)
                if let progress = model.applyProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("\(progress.done.formatted()) of \(progress.total.formatted())")
                    }
                }
                Text("Full-size images are downloaded from iCloud when needed, so this can take a while.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Stop After Current Batch") { model.cancelApply() }
                }
            } else {
                Label("Rotated \(model.lastAppliedCount.formatted()) photos", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if !model.applyFailures.isEmpty {
                    Text("\(model.applyFailures.count.formatted()) could not be rotated and are still in the review list:")
                    List(model.applyFailures) { failure in
                        VStack(alignment: .leading) {
                            Text(failure.message)
                            Text(failure.localIdentifier).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 160)
                }
                HStack {
                    Spacer()
                    Button("Done") { model.finishApply() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(model.isApplying)
    }
}
