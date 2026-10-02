import SensorstormCore
import SwiftUI
import UserNotifications

@main
struct SensorstormApp: App {
    @State private var hub: SensorHub
    @State private var library: RecordingLibrary
    @State private var surveys: SurveyModel
    @State private var pro = ProEntitlement()
    @State private var network: NetworkHub

    init() {
        let store = (try? RecordingStore.makeDefault())
            ?? RecordingStore(root: FileManager.default.temporaryDirectory)
        let hub = SensorHub(store: store)
        _hub = State(initialValue: hub)
        _library = State(initialValue: RecordingLibrary(store: store))

        let surveyStore = (try? SurveyStore.makeDefault())
            ?? SurveyStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("Surveys", isDirectory: true))
        let surveys = SurveyModel(store: surveyStore)
        _surveys = State(initialValue: surveys)
        let network = NetworkHub()
        _network = State(initialValue: network)

        // For the shortcuts, Siri and the Action Button: they act on the app that is running.
        AppServices.hub = hub
        AppServices.surveys = surveys
        AppServices.network = network

        // Before any view appears, so the first frame already shows the sample data
        // rather than an empty library that fills in a moment later. A no-op unless
        // `SS_FIXTURE=1` is set, which only `Tools/asc_capture_screenshots.py` does.
        ScreenshotFixture.seed(recordings: store, surveys: surveyStore)

        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(library)
                .environment(surveys)
                .environment(pro)
                .environment(network)
                .preferredColorScheme(.dark)
        }
    }
}
