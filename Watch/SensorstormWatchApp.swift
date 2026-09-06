import SwiftUI

@main
struct SensorstormWatchApp: App {
    @State private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(recorder)
        }
    }
}
