import SwiftUI

struct RootView: View {
    @Environment(SensorHub.self) private var hub
    @State private var selection: Screen = .record

    /// Not called `Tab` — that name belongs to SwiftUI's tab builder below.
    enum Screen: Hashable {
        case record
        case library
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
            Tab("Einstellungen", systemImage: "slider.horizontal.3", value: Screen.settings) {
                SettingsView()
            }
        }
        .tint(Theme.accent)
        // Leaving the record screen mid-recording must not stop the sensors.
        .onChange(of: selection) { _, newValue in
            guard hub.phase == .idle else { return }
            if newValue != .record { hub.stopMonitoring() }
        }
    }
}
