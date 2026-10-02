import SensorstormCore
import SwiftUI

/// The phone as a Bluetooth sensor, and a second phone recorded alongside this one.
struct PeerPhoneView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        @Bindable var hub = hub

        Form {
            Section {
                Toggle("Als Bluetooth-Sensor anbieten", isOn: $hub.settings.offersBluetoothService)
                if hub.settings.offersBluetoothService {
                    Toggle("Fernsteuerung erlauben", isOn: $hub.settings.allowsBluetoothControl)
                    LabeledContent("Verbundene Geräte") {
                        Text(verbatim: "\(hub.bluetoothServiceSubscribers)").monospacedDigit()
                    }
                }
            } header: {
                Text("Dieses iPhone")
            } footer: {
                Text("Andere Geräte — ein ESP32, ein Raspberry Pi, ein Mac, ein zweites iPhone — abonnieren die Messwerte per Bluetooth, ohne WLAN und ohne Server. Jeder Sensor ist ein eigenes Merkmal; eine Meldung enthält die Zeit auf der Uhr dieses Telefons und die Kanäle. Mit der Fernsteuerung kann jedes Gerät in Reichweite die Aufnahme starten, anhalten und markieren — nur einschalten, wenn das gewollt ist. Die App muss dafür offen sein.")
            }

            Section {
                statusRow

                if let connection = hub.peerConnection {
                    LabeledContent("Gerät") { Text(verbatim: connection.name) }
                    LabeledContent("Uhrversatz") {
                        Text(verbatim: Self.offset(connection.clock)).monospacedDigit()
                    }
                    LabeledContent("Genauigkeit") {
                        Text(verbatim: "±" + Self.milliseconds(connection.clock.uncertainty)).monospacedDigit()
                    }
                    Toggle("Gemeinsam starten und stoppen", isOn: $hub.settings.startsPeersTogether)
                    Button("Trennen", role: .destructive) { hub.peerLink.disconnect() }
                } else {
                    Button {
                        hub.peerLink.startScan()
                    } label: {
                        Label("Zweites iPhone suchen", systemImage: "magnifyingglass")
                    }
                    ForEach(hub.peers) { peer in
                        Button {
                            hub.peerLink.connect(peer.id)
                        } label: {
                            LabeledContent {
                                Text(verbatim: "\(peer.rssi) dBm").monospacedDigit()
                            } label: {
                                Label { Text(verbatim: peer.name) } icon: { Image(systemName: "iphone.gen3") }
                            }
                        }
                    }
                }
            } header: {
                Text("Zweites iPhone")
            } footer: {
                Text("Auf dem anderen Telefon muss Sensorstorm offen sein und „Als Bluetooth-Sensor anbieten“ laufen. Beide Uhren werden mit sechzehn Anfragen verglichen; der Versatz und seine Unsicherheit stehen in der Aufnahme, und die Ströme des anderen Telefons liegen auf der Zeit dieses Telefons. Mit „Gemeinsam starten“ braucht das andere Telefon die Fernsteuerung.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Bluetooth-Dienst")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { hub.peerLink.stopScan() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch hub.peerStatus {
        case .idle:
            EmptyView()
        case .scanning:
            Label("Suche …", systemImage: "dot.radiowaves.left.and.right")
        case .connecting(let name):
            Label("Verbinde mit \(name) …", systemImage: "link")
        case .syncing(let name):
            Label("Vergleiche die Uhr von \(name) …", systemImage: "clock.arrow.2.circlepath")
        case .connected(let name):
            Label("Verbunden mit \(name)", systemImage: "checkmark.circle")
        case .failed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(Theme.recording)
        }
    }

    static func offset(_ clock: PeerClockEstimate) -> String {
        let seconds = clock.offset
        if abs(seconds) >= 1 { return String(format: "%+.3f s", seconds) }
        return String(format: "%+.1f ms", seconds * 1_000)
    }

    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1_000)
    }
}
