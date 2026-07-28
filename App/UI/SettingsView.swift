import SensorstormCore
import SwiftUI

struct SettingsView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        @Bindable var hub = hub

        NavigationStack {
            Form {
                Section {
                    Picker("Abtastrate", selection: $hub.settings.motionRateHz) {
                        ForEach(RecordingSettings.availableRates, id: \.self) { rate in
                            Text(Format.rate(rate)).tag(rate)
                        }
                    }
                    Toggle("Bildschirm aktiv lassen", isOn: $hub.settings.keepsScreenAwake)
                } header: {
                    Text("Aufnahme")
                } footer: {
                    Text("Gilt für alle Bewegungssensoren. GPS, Barometer und Schrittzähler liefern in ihrem eigenen Takt.")
                }

                Section {
                    Picker("Kamera", selection: $hub.settings.videoMode) {
                        Text("Aus").tag(VideoMode.off)
                        Text("Rückkamera").tag(VideoMode.back)
                        Text("Frontkamera").tag(VideoMode.front)
                    }
                    .disabled(!hub.isCameraAvailable)

                    if hub.settings.isVideoEnabled {
                        Picker("Qualität", selection: $hub.settings.videoQuality) {
                            Text("720p").tag(VideoQuality.hd720)
                            Text("1080p").tag(VideoQuality.hd1080)
                            Text("4K").tag(VideoQuality.uhd4k)
                        }
                    }
                    Toggle("Ton aufnehmen", isOn: $hub.settings.recordsAudio)
                } header: {
                    Text("Video & Audio")
                } footer: {
                    if hub.isCameraAvailable {
                        Text("Die Bildstabilisierung bleibt aus, damit das Bild exakt zu den Bewegungsdaten passt.")
                    } else {
                        Text("Auf diesem Gerät ist keine Kamera verfügbar.")
                    }
                }

                ForEach(SensorCategory.allCases, id: \.self) { category in
                    sensorSection(category)
                }

                Section {
                    LabeledContent("Version", value: Self.appVersion)
                } footer: {
                    Text("Alle Streams teilen eine gemeinsame Uhr. Ein Export enthält pro Sensor eine CSV-Datei, das Video und die Metadaten.")
                }
            }
            .navigationTitle("Einstellungen")
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func sensorSection(_ category: SensorCategory) -> some View {
        @Bindable var hub = hub
        let descriptors = SensorCatalog.descriptors(in: category)

        if !descriptors.isEmpty {
            Section(category.title) {
                ForEach(descriptors) { descriptor in
                    let available = hub.isAvailable(descriptor.id)
                    Toggle(isOn: Binding(
                        get: { hub.settings.isEnabled(descriptor.id) },
                        set: { hub.settings.setEnabled($0, for: descriptor.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.id.title)
                            Text(available
                                 ? descriptor.channels.joined(separator: ", ")
                                 : String(localized: "nicht verfügbar"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(!available)
                }
            }
        }
    }

    static var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
