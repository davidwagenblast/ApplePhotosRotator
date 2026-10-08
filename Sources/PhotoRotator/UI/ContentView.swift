import AppKit
import Photos
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isAuthorized {
                switch model.screen {
                case .scan: ScanView()
                case .review: ReviewView()
                }
            } else {
                AccessView()
            }
        }
        .toolbar {
            if model.isAuthorized {
                ToolbarItem(placement: .principal) {
                    Picker("Screen", selection: $model.screen) {
                        Text("Scan").tag(AppModel.Screen.scan)
                        Text("Review (\(model.reviewItems.count))").tag(AppModel.Screen.review)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }
        }
        .task {
            if model.isAuthorized { await model.onAuthorized() }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct AccessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photo Rotator needs access to your Photos library")
                .font(.title2.weight(.semibold))
            Text("It looks for sideways and upside-down photos and, only for the ones you approve, saves a rotated version using Photos' own editing system. Your originals are never changed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            switch model.authorization {
            case .notDetermined:
                Button("Allow Access…") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            default:
                Text("Access was denied. Turn it on in System Settings › Privacy & Security › Photos, then reopen the app.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
