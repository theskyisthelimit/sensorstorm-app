import SwiftUI

struct RootView: View {
    @Environment(SensorHub.self) private var hub
    @State private var selection: Screen = .record

    /// Not called `Tab` — that name belongs to SwiftUI's tab builder below.
    enum Screen: Hashable {
        case record
        case library
        case survey
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Aufnehmen", systemImage: "dot.radiowaves.left.and.right", value: Screen.record) {
                RecordView()
            }
            Tab("Aufnahmen", systemImage: "square.stack.3d.down.right", value: Screen.library) {
                LibraryView()
            }
            Tab("Fälle", systemImage: "mappin.and.ellipse", value: Screen.survey) {
                SurveyListView()
            }
            Tab("Einstellungen", systemImage: "slider.horizontal.3", value: Screen.settings) {
                SettingsView()
            }
        }
        .tint(Theme.accent)
        // The one place the black lives. Putting it on each screen's scroll view instead —
        // as `.background(Color.black.ignoresSafeArea())` — made those views ignore the safe
        // area too, so their content ran under the status bar and under the floating tab bar,
        // where the last rows became permanently unreachable.
        .background(Theme.background.ignoresSafeArea())
        // Leaving the record screen mid-recording must not stop the sensors.
        .onChange(of: selection) { _, newValue in
            guard hub.phase == .idle else { return }
            if newValue != .record { hub.stopMonitoring() }
        }
    }
}
