import SensorstormCore
import SwiftUI

@main
struct SensorstormApp: App {
    @State private var hub: SensorHub
    @State private var library: RecordingLibrary
    @State private var surveys: SurveyModel

    init() {
        let store = (try? RecordingStore.makeDefault())
            ?? RecordingStore(root: FileManager.default.temporaryDirectory)
        _hub = State(initialValue: SensorHub(store: store))
        _library = State(initialValue: RecordingLibrary(store: store))

        let surveyStore = (try? SurveyStore.makeDefault())
            ?? SurveyStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("Surveys", isDirectory: true))
        _surveys = State(initialValue: SurveyModel(store: surveyStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(library)
                .environment(surveys)
                .preferredColorScheme(.dark)
        }
    }
}
