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

                captureEngineSection

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
        }
    }

    /// The one setting that decides whether a recording can be placed in a 3D scene, so it
    /// says what it buys rather than naming a framework.
    @ViewBuilder
    private var captureEngineSection: some View {
        @Bindable var hub = hub

        Section {
            Picker("Kamerapose", selection: $hub.settings.captureEngine) {
                Text("Aus").tag(CaptureEngine.classic)
                Text("ARKit").tag(CaptureEngine.arkit)
            }
            .pickerStyle(.segmented)
            .disabled(!hub.isARKitAvailable || !hub.settings.isVideoEnabled)
        } header: {
            Text("3D")
        } footer: {
            if !hub.isARKitAvailable {
                Text("Dieses Gerät unterstützt kein ARKit-Tracking.")
            } else if !hub.settings.isVideoEnabled {
                Text("Schalte oben die Kamera ein — ohne Bild gibt es keine Kamerapose.")
            } else if hub.settings.captureEngine == .arkit {
                if hub.canAlignARKitToNorth {
                    Text("Zeichnet zu jedem Bild Position, Blickrichtung und Brennweite auf — genug, um die Bilder in Blender auf eine 3D-Karte zu legen. Das Video wird unrotiert gespeichert, damit die Brennweiten dazu passen.")
                } else {
                    Text("Zeichnet zu jedem Bild Position, Blickrichtung und Brennweite auf. Ohne Standortfreigabe fehlt die Nordausrichtung, und die Szene ist um einen unbekannten Winkel verdreht.")
                }
            } else {
                Text("Ohne Kamerapose enthält der Export nur Zeitstempel und Brennweiten — die Bilder lassen sich damit nicht im Raum platzieren.")
            }
        }
    }

    @ViewBuilder
    private func sensorSection(_ category: SensorCategory) -> some View {
        @Bindable var hub = hub
        // Engine-controlled streams follow from the camera setting above; showing them as
        // toggles would promise a choice that does not exist.
        let descriptors = SensorCatalog.descriptors(in: category)
            .filter { !SensorID.engineControlled.contains($0.id) }

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
                            // One line. Spelled out, GPS alone lists ten channel names and
                            // pushed its row to three lines, which is most of why this
                            // screen felt like a wall. The full list lives in docs/UNITS.md.
                            Text(available
                                 ? descriptor.channels.joined(separator: ", ")
                                 : String(localized: "nicht verfügbar"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
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
