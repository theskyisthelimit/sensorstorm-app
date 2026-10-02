import SensorstormCore
import SwiftUI

/// Everything that talks over the air: the Bluetooth scanner and its sensors, and the network
/// tools. A tab of its own — these are tools to open, look at and close, not settings.
struct RadioView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BluetoothScannerView()
                    } label: {
                        Label("Bluetooth-Scanner", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        BluetoothSensorsView()
                    } label: {
                        Label("Bluetooth-Sensoren", systemImage: "sensor")
                    }
                } header: {
                    Text("Bluetooth")
                } footer: {
                    Text("Alle Geräte in Reichweite mit Signal, Paketen und Diensten. Ein Tipp öffnet das Gerät, und wo es sich verbinden lässt, zeigt der Explorer, was es kann.")
                }

                Section {
                    NavigationLink {
                        NetworkOverviewView()
                    } label: {
                        Label("Verbindung", systemImage: "network")
                    }
                    NavigationLink {
                        NetworkScanView()
                    } label: {
                        Label("Geräte im Netz", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    NavigationLink {
                        NetworkToolsView()
                    } label: {
                        Label("Werkzeuge", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        SpeedTestView()
                    } label: {
                        Label("Geschwindigkeit", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    NavigationLink {
                        Iperf3View()
                    } label: {
                        Label("iperf3", systemImage: "arrow.up.arrow.down.circle")
                    }
                    NavigationLink {
                        NetworkInventoryView()
                    } label: {
                        Label("Gespeicherte Scans", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("Netzwerk")
                } footer: {
                    Text("Das Netz, in dem das Telefon ist: Schnittstellen, Geräte, Ping, Traceroute, DNS, Ports, Zertifikate und Durchsatz. Was iOS nicht herausgibt — Hardware-Adressen, WLAN-Kanäle, Nachbarnetze — fehlt hier und wird nicht vorgetäuscht.")
                }
            }
            .navigationTitle("Funk")
            .scrollContentBackground(.hidden)
        }
    }
}
