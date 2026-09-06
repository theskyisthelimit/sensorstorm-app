import SensorstormCore
import SwiftUI

@main
struct SensorstormApp: App {
    @State private var hub: SensorHub
    @State private var library: RecordingLibrary
    @State private var surveys: SurveyModel
    @State private var pro = ProEntitlement()

    init() {
        let store = (try? RecordingStore.makeDefault())
            ?? RecordingStore(root: FileManager.default.temporaryDirectory)
        _hub = State(initialValue: SensorHub(store: store))
        _library = State(initialValue: RecordingLibrary(store: store))

        let surveyStore = (try? SurveyStore.makeDefault())
            ?? SurveyStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("Surveys", isDirectory: true))
        _surveys = State(initialValue: SurveyModel(store: surveyStore))

        // Before any view appears, so the first frame already shows the sample data
        // rather than an empty library that fills in a moment later. A no-op unless
        // `SS_FIXTURE=1` is set, which only `Tools/asc_capture_screenshots.py` does.
        ScreenshotFixture.seed(recordings: store, surveys: surveyStore)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(library)
                .environment(surveys)
                .environment(pro)
                .preferredColorScheme(.dark)
        }
    }
}
