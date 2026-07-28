import SensorstormCore
import SwiftUI

@main
struct SensorstormApp: App {
    @State private var hub: SensorHub
    @State private var library: RecordingLibrary

    init() {
        let store = (try? RecordingStore.makeDefault())
            ?? RecordingStore(root: FileManager.default.temporaryDirectory)
        _hub = State(initialValue: SensorHub(store: store))
        _library = State(initialValue: RecordingLibrary(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(library)
                .preferredColorScheme(.dark)
        }
    }
}
