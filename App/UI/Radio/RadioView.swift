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
            }
            .navigationTitle("Funk")
            .scrollContentBackground(.hidden)
        }
    }
}
