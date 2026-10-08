import SwiftUI

@main
struct PhotoRotatorApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Photo Rotator") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
