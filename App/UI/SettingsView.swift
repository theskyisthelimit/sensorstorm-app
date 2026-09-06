import SensorstormCore
import SwiftUI

struct SettingsView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(ProEntitlement.self) private var pro
    @State private var isExportingArchive = false

    var body: some View {
        @Bindable var hub = hub

        NavigationStack {
            Form {
                Section {
                    Picker("Abtastrate", selection: pro.gated($hub.settings.motionRateHz,
                                                              feature: { (rate: Double) -> ProFeature? in
                        rate > ProAccess.freeMaximumRateHz ? .highRate : nil
                    })) {
                        ForEach(RecordingSettings.availableRates, id: \.self) { rate in
                            // The gated rate keeps its place in the list. Removing it would
                            // remove the only place anyone learns that 400 Hz exists.
                            if pro.access.allowsRate(rate) {
                                Text(Format.rate(rate)).tag(rate)
                            } else {
                                Label(Format.rate(rate), systemImage: "lock.fill").tag(rate)
                            }
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
                        Picker("Qualität", selection: pro.gated($hub.settings.videoQuality,
                                                                feature: { (quality: VideoQuality) -> ProFeature? in
                            quality == .uhd4k ? .video4K : nil
                        })) {
                            Text("720p").tag(VideoQuality.hd720)
                            Text("1080p").tag(VideoQuality.hd1080)
                            if pro.access.allows(.video4K) {
                                Text("4K").tag(VideoQuality.uhd4k)
                            } else {
                                Label("4K", systemImage: "lock.fill").tag(VideoQuality.uhd4k)
                            }
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
                    ProButton(.archiveExport, "Alles exportieren", "shippingbox") {
                        isExportingArchive = true
                    }
                } header: {
                    Text("Daten")
                } footer: {
                    Text("Begehungen und Aufnahmen als ein Zip mit \(ArchiveExporter.manifestFileName): eine Datei, die das ganze Archiv maschinenlesbar beschreibt.")
                }

                proSection

                Section {
                    LabeledContent("Version", value: Self.appVersion)
                } footer: {
                    Text("Alle Streams teilen eine gemeinsame Uhr. Ein Export enthält pro Sensor eine CSV-Datei, das Video und die Metadaten.")
                }
            }
            .navigationTitle("Einstellungen")
            .scrollContentBackground(.hidden)
            .sheet(isPresented: $isExportingArchive) {
                ArchiveExportView()
            }
        }
    }

    /// Purchase state, and the restore button App Store Review guideline 3.1.1 requires for
    /// a non-consumable. It has to be reachable without hitting a lock first — someone
    /// restoring on a new phone should not have to go hunting for a paywall to escape.
    @ViewBuilder
    private var proSection: some View {
        Section {
            if pro.isPro {
                LabeledContent("Sensorstorm Pro") {
                    Label("Freigeschaltet", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                }
            } else {
                Button {
                    pro.showPaywall()
                } label: {
                    LabeledContent {
                        Text(pro.displayPrice ?? "")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Sensorstorm Pro", systemImage: "sparkles")
                    }
                }
                Button("Käufe wiederherstellen") {
                    Task { await pro.restore() }
                }
                .disabled(pro.isWorking)
            }
        } footer: {
            if pro.isPro {
                Text("Danke. Der Kauf hängt an deinem Apple-Account und gilt auf jedem Gerät, an dem du damit angemeldet bist.")
            } else {
                Text("Einmalig, kein Abo: 400 Hz, 4K, Kamerapose für 3D, Rohdaten, Blender, Sensor Logger, Gyroflow, mehrere Begehungen, GeoJSON/GPX/KML und der Gesamtexport. Der CSV-Export bleibt auch ohne Pro offen.")
            }
        }
    }

    /// The one setting that decides whether a recording can be placed in a 3D scene, so it
    /// says what it buys rather than naming a framework.
    @ViewBuilder
    private var captureEngineSection: some View {
        @Bindable var hub = hub

        Section {
            Picker("Kamerapose", selection: pro.gated($hub.settings.captureEngine,
                                                      feature: { (engine: CaptureEngine) -> ProFeature? in
                engine.proFeature
            })) {
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
            } else if !pro.access.allows(.arkitPose) {
                Text("Die Kamerapose gehört zu Pro: zu jedem Bild Position, Blickrichtung und Brennweite — die Voraussetzung für den Export als 3D-Szene nach Blender. Tippe auf ARKit, um sie freizuschalten.")
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
