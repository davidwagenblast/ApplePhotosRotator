import SwiftUI

@main
struct PhotoRotatorApp: App {
    // `State` is used directly instead of `@State`: with recent SDKs `@State` is a macro, and Apple's Command Line
    // Tools (without Xcode) can't expand it. This is exactly what `@State` stands for.
    private var _model = State<AppModel>(wrappedValue: AppModel())
    private var model: AppModel {
        get { _model.wrappedValue }
        nonmutating set { _model.wrappedValue = newValue }
    }

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
