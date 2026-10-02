import SensorstormCore
import SwiftUI
import UniformTypeIdentifiers

/// Bluetooth sensors: what is being decoded right now, which devices to connect to, and the
/// user's own decoder files.
struct BluetoothSensorsView: View {
    @Environment(SensorHub.self) private var hub
    @State private var files = DecoderLibrary.files()
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        @Bindable var hub = hub

        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { hub.settings.isEnabled(.bluetooth) && hub.settings.decodesBluetoothSensors },
                    set: { isOn in
                        hub.settings.decodesBluetoothSensors = isOn
                        if isOn { hub.settings.setEnabled(true, for: .bluetooth) }
                    })) {
                    Label("Bluetooth-Sensoren auslesen", systemImage: "sensor")
                }
            } footer: {
                Text("Erkennt RuuviTag, BTHome (Shelly, ESPHome), Xiaomi-Thermometer mit ATC- oder pvvx-Firmware und alles, wofür eine eigene Decoder-Datei da ist. Die Werte landen während einer Aufnahme in bluetooth_sensors.csv. Läuft, solange der Aufnahme-Bildschirm offen ist.")
            }

            if hub.settings.decodesBluetoothSensors {
                liveSection
                pairingSection
            }

            decoderSection
        }
        .navigationTitle("Bluetooth-Sensoren")
        .scrollContentBackground(.hidden)
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.javaScript, .plainText],
                      allowsMultipleSelection: true) { result in
            importError = nil
            for url in (try? result.get()) ?? [] {
                do {
                    try DecoderLibrary.add(url)
                } catch {
                    importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            files = DecoderLibrary.files()
            hub.reloadBluetoothDecoders()
        }
    }

    private var liveSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let readings = hub.bluetoothReadings
                if readings.isEmpty {
                    Text("Noch kein Sensor erkannt. Öffne den Aufnahme-Bildschirm, damit gesucht wird.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(readings) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: "\(device.name ?? device.id.uuidString.prefix(8).description) · \(device.reading.decoder)")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(device.reading.fields, id: \.name) { field in
                                    LabeledContent {
                                        Text(field.value, format: .number.precision(.fractionLength(0...3)))
                                            .monospacedDigit()
                                    } label: {
                                        Text(verbatim: field.name)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Live")
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        @Bindable var hub = hub
        Section {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let paired = hub.settings.pairedBluetoothDevices ?? []
                let devices = hub.connectableBluetoothDevices
                let known = Set(devices.map(\.id))
                VStack(alignment: .leading, spacing: 8) {
                    if devices.isEmpty && paired.isEmpty {
                        Text("Kein Gurt, Leistungsmesser oder Laufsensor in Reichweite.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        pairingRow(id: device.id, name: device.name, isPaired: paired.contains(device.id))
                    }
                    // Paired but silent right now — still listed, so it can be removed.
                    ForEach(paired.subtracting(known).sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        pairingRow(id: id, name: nil, isPaired: true)
                    }
                }
            }
        } header: {
            Text("Verbinden")
        } footer: {
            Text("Herzfrequenzgurte, Leistungsmesser, Trittfrequenz- und Laufsensoren senden ihre Werte erst nach einer Verbindung. Ein gekoppeltes Gerät wird bei jedem Start wieder verbunden.")
        }
    }

    private func pairingRow(id: UUID, name: String?, isPaired: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isPaired },
            set: { isOn in
                var paired = hub.settings.pairedBluetoothDevices ?? []
                if isOn { paired.insert(id) } else { paired.remove(id) }
                hub.settings.pairedBluetoothDevices = paired.isEmpty ? nil : paired
            })) {
            Text(verbatim: name ?? id.uuidString.prefix(8).description)
        }
    }

    private var decoderSection: some View {
        Section {
            ForEach(files, id: \.self) { file in
                Label(file.lastPathComponent, systemImage: "curlybraces")
            }
            .onDelete { offsets in
                for index in offsets { DecoderLibrary.remove(files[index]) }
                files = DecoderLibrary.files()
                hub.reloadBluetoothDecoders()
            }
            Button {
                isImporting = true
            } label: {
                Label("Decoder-Datei hinzufügen", systemImage: "plus")
            }
            Button {
                UIPasteboard.general.string = DecoderLibrary.example
            } label: {
                Label("Beispiel kopieren", systemImage: "doc.on.doc")
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.recording)
            }
        } header: {
            Text("Eigene Decoder")
        } footer: {
            Text("Eine JavaScript-Datei mit beliebig vielen decoder({ … })-Aufrufen. Jeder nennt manufacturerId, serviceUuid oder namePrefix und eine Funktion decode(bytes), die { name: Zahl } zurückgibt. Das Beispiel zeigt beides.")
        }
    }
}
