import SensorstormCore
import SwiftUI

struct SettingsView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(ProEntitlement.self) private var pro
    @State private var isExportingArchive = false
    @State private var streamTest: LiveStreamer.Status?
    @State private var isTestingStream = false

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

                SensorArmingSections()

                streamingSection

                Section {
                    ProButton(.archiveExport, "Alles exportieren", "shippingbox") {
                        isExportingArchive = true
                    }
                } header: {
                    Text("Daten")
                } footer: {
                    Text("Routen und Aufnahmen als ein Zip mit \(ArchiveExporter.manifestFileName): eine Datei, die das ganze Archiv maschinenlesbar beschreibt.")
                }

                proSection

                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sensorstorm")
                            .font(.headline)
                        Text("Dein iPhone als Messgerät.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
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
            .onAppear {
                if ScreenshotFixture.screen == .export { isExportingArchive = true }
            }
        }
    }

    /// Where to push samples while recording, how often, and whether the endpoint answers.
    ///
    /// The test button matters more than it looks: the alternative is walking a street for
    /// twenty minutes and finding out afterwards that the URL had a typo in it.
    @ViewBuilder
    private var streamingSection: some View {
        @Bindable var hub = hub

        Section {
            Toggle(isOn: pro.gated(
                Binding(get: { hub.settings.isStreamingEnabled ?? false },
                        set: { hub.settings.isStreamingEnabled = $0 }),
                feature: { (isOn: Bool) -> ProFeature? in isOn ? .liveStreaming : nil })) {
                Label("Live an einen Server senden",
                      systemImage: pro.access.allows(.liveStreaming)
                          ? "antenna.radiowaves.left.and.right" : "lock.fill")
            }

            if hub.settings.isStreamingEnabled == true {
                TextField("https://192.168.1.20:8080/sensoren",
                          text: Binding(get: { hub.settings.streamingURL ?? "" },
                                        set: { hub.settings.streamingURL = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.callout.monospaced())

                Picker("Takt", selection: Binding(
                    get: { hub.settings.streamingBatch },
                    set: { hub.settings.streamingBatchSeconds = $0 })) {
                    ForEach([0.1, 0.2, 0.5, 1.0, 2.0], id: \.self) { period in
                        // Units, not prose — nothing here to translate.
                        Text(verbatim: period < 1 ? "\(Int(period * 1000)) ms" : "\(Int(period)) s")
                            .tag(period)
                    }
                }

                Button {
                    testStream()
                } label: {
                    HStack {
                        Label("Verbindung testen", systemImage: "paperplane")
                        if isTestingStream {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(hub.settings.streamingEndpoint == nil || isTestingStream)

                if let streamTest {
                    streamStatusRow(streamTest)
                }
            }

            Toggle(isOn: pro.gated(
                Binding(get: { hub.settings.isMQTTEnabled ?? false },
                        set: { hub.settings.isMQTTEnabled = $0 }),
                feature: { (isOn: Bool) -> ProFeature? in isOn ? .liveStreaming : nil })) {
                Label("Zusätzlich an einen MQTT-Broker",
                      systemImage: pro.access.allows(.liveStreaming)
                          ? "dot.radiowaves.up.forward" : "lock.fill")
            }

            if hub.settings.isMQTTEnabled == true {
                TextField("broker.example.com",
                          text: Binding(get: { hub.settings.mqttHost ?? "" },
                                        set: { hub.settings.mqttHost = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.callout.monospaced())

                Toggle("TLS", isOn: Binding(get: { hub.settings.mqttUsesTLS ?? true },
                                            set: { hub.settings.mqttUsesTLS = $0 }))

                let portPlaceholder: String = (hub.settings.mqttUsesTLS ?? true) ? "8883" : "1883"
                LabeledContent("Port") {
                    TextField(portPlaceholder,
                              text: Binding(
                                get: { hub.settings.mqttPort.map(String.init) ?? "" },
                                set: { hub.settings.mqttPort = Int($0) }))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.callout.monospacedDigit())
                }

                TextField(Self.defaultTopic,
                          text: Binding(get: { hub.settings.mqttTopic ?? "" },
                                        set: { hub.settings.mqttTopic = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())

                TextField("Benutzername",
                          text: Binding(get: { hub.settings.mqttUsername ?? "" },
                                        set: { hub.settings.mqttUsername = $0 }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Passwort",
                            text: Binding(get: { hub.settings.mqttPassword ?? "" },
                                          set: { hub.settings.mqttPassword = $0 }))
            }

            Toggle(isOn: Binding(get: { hub.settings.measuresNetworkTime },
                                 set: { hub.settings.measuresNetworkTime = $0 })) {
                Label("Zeit gegen einen Zeitserver messen", systemImage: "clock.badge.checkmark")
            }

            if hub.settings.isEnabled(.bluetooth) {
                Toggle(isOn: Binding(get: { hub.settings.logsBluetoothAdvertisements },
                                     set: { hub.settings.logsBluetoothAdvertisements = $0 })) {
                    Label("Bluetooth-Rohdaten mitschreiben", systemImage: "dot.radiowaves.forward")
                }
            }
        } header: {
            Text("Live-Übertragung")
        } footer: {
            if hub.settings.isStreamingEnabled == true {
                Text("Während einer Aufnahme geht jede Messung als JSON an diese Adresse, im selben Format, das Sensor Logger sendet. Ein bestehender Endpunkt funktioniert also unverändert. Die Aufnahme auf dem Gerät läuft davon unabhängig weiter: bricht die Verbindung ab, fehlt nichts in der Datei.")
            } else {
                Text("Für ein eigenes Dashboard, Node-RED oder Home Assistant. Ohne eingetragene Adresse baut die App keine Verbindung auf.")
            }
        }

        if hub.settings.logsBluetoothAdvertisements, hub.settings.isEnabled(.bluetooth) {
            Section {
                EmptyView()
            } footer: {
                Text("Schreibt zu jeder Aufnahme zusätzlich jedes empfangene Bluetooth-Paket mit: Kennung, Signalstärke, Name und die rohen Herstellerdaten als Hex. Damit lassen sich RuuviTag- oder BTHome-Sensoren nachträglich dekodieren, denn Temperatur, Feuchte und Druck stehen genau dort drin. Die Kennung ist keine Geräteadresse: iOS gibt die nie heraus, und zwei Aufnahmen sind sich darüber nicht einig.")
            }
        }

        if hub.settings.measuresNetworkTime {
            Section {
                EmptyView()
            } footer: {
                Text("Einmal pro Aufnahme wird gemessen, wie weit die Uhr des Geräts von der Netzzeit abweicht. Der Wert wird **nur notiert**, nie angewendet: die Aufnahme bleibt auf der Uhr des Geräts, und genau das lässt Videobild und Messwert ohne Kalibrierung aufeinanderliegen. Notiert lassen sich zwei Geräte hinterher auf eine Zeitachse bringen.")
            }
        }
    }

    @ViewBuilder
    private func streamStatusRow(_ status: LiveStreamer.Status) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .sending:
            Label("Wird gesendet …", systemImage: "arrow.up.circle")
                .foregroundStyle(.secondary)
        case .delivered(let code, let samples):
            Label("\(samples) Messwerte gesendet, Antwort \(code)", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.accent)
        case .failed(let message):
            // Already a sentence from URLSession or the server; not a key to look up.
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.recording)
        }
    }

    private func testStream() {
        guard let url = hub.settings.streamingEndpoint else { return }
        isTestingStream = true
        streamTest = .sending
        Task {
            streamTest = await hub.streamer.test(url: url)
            isTestingStream = false
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
                Text("Einmalig, kein Abo: 400 Hz, 4K, Kamerapose für 3D, Rohdaten, Blender, Sensor Logger, Gyroflow, mehrere Routen, GeoJSON/GPX/KML und der Gesamtexport. Der CSV-Export bleibt auch ohne Pro offen.")
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
                Text("Schalte oben die Kamera ein. Ohne Bild gibt es keine Kamerapose.")
            } else if !pro.access.allows(.arkitPose) {
                Text("Die Kamerapose gehört zu Pro. Sie zeichnet zu jedem Bild Position, Blickrichtung und Brennweite auf, und ohne sie gibt es keinen Export als 3D-Szene nach Blender. Tippe auf ARKit, um sie freizuschalten.")
            } else if hub.settings.captureEngine == .arkit {
                if hub.canAlignARKitToNorth {
                    Text("Zeichnet zu jedem Bild Position, Blickrichtung und Brennweite auf. Das genügt, um die Bilder in Blender auf eine 3D-Karte zu legen. Das Video wird unrotiert gespeichert, damit die Brennweiten dazu passen.")
                } else {
                    Text("Zeichnet zu jedem Bild Position, Blickrichtung und Brennweite auf. Ohne Standortfreigabe fehlt die Nordausrichtung, und die Szene ist um einen unbekannten Winkel verdreht.")
                }
            } else {
                Text("Ohne Kamerapose enthält der Export nur Zeitstempel und Brennweiten. Die Bilder lassen sich damit nicht im Raum platzieren.")
            }
        }
    }

    /// The broker topic Sensor Logger's own documentation uses, so an existing
    /// subscription works without being retyped. A value, not prose — not translated.
    static let defaultTopic = "sensorstorm"

    static var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
