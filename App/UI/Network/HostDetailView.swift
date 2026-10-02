import SensorstormCore
import SwiftUI
import UIKit

/// One device: what the scan learned, the tools pointed at it, and the notes the person keeps.
struct HostDetailView: View {
    @Environment(NetworkHub.self) private var network
    let host: HostRecord
    let subnet: String
    let gateway: String?

    @State private var annotation = HostAnnotation()
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: host.guess.symbol).font(.title2).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(verbatim: (annotation.alias?.isEmpty == false ? annotation.alias : nil) ?? host.displayName)
                            .font(.headline)
                        Text(host.guess.title).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Adresse") {
                    Text(verbatim: host.address).monospaced().textSelection(.enabled)
                }
                if host.address == gateway {
                    Label("Router des Netzes", systemImage: "wifi.router")
                }
                if let roundTrip = host.roundTrip {
                    LabeledContent("Antwortzeit") { Text(verbatim: NetFormat.milliseconds(roundTrip)).monospacedDigit() }
                }
                ForEach(host.hostNames, id: \.self) { name in
                    LabeledContent("Name") { Text(verbatim: name).textSelection(.enabled) }
                }
                if !host.sources.isEmpty {
                    LabeledContent("Gefunden durch") { Text(verbatim: host.sources.joined(separator: ", ")) }
                }
            } footer: {
                Text("Die Art des Geräts ist eine Vermutung aus Namen, Diensten und offenen Ports.")
            }

            if !host.services.isEmpty {
                Section("Dienste im Netz") {
                    ForEach(host.services, id: \.self) { service in
                        Text(verbatim: service).font(.callout.monospaced())
                    }
                }
            }

            if !host.openPorts.isEmpty {
                Section("Offene Ports") {
                    ForEach(host.openPorts, id: \.self) { port in
                        HStack {
                            Text(verbatim: "\(port)").font(.body.monospacedDigit().weight(.semibold))
                            let name = PortCatalog.name(port)
                            if !name.isEmpty { Text(verbatim: name).foregroundStyle(.secondary) }
                            Spacer()
                            if let url = webURL(port) {
                                Link(destination: url) {
                                    Label("Im Browser öffnen", systemImage: "safari").labelStyle(.iconOnly)
                                }
                            }
                        }
                    }
                }
            }

            Section("Werkzeuge") {
                NavigationLink { PingToolView(host: host.address) } label: {
                    Label("Ping", systemImage: "waveform.path.ecg")
                }
                NavigationLink { TracerouteToolView(host: host.address) } label: {
                    Label("Traceroute", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                NavigationLink { PortScanToolView(host: host.address) } label: {
                    Label("Alle Ports prüfen", systemImage: "door.left.hand.open")
                }
                if !host.openPorts.isDisjoint(with: [443, 8_443, 993, 995, 465, 636]) {
                    NavigationLink { TLSToolView(host: host.address) } label: {
                        Label("Zertifikat prüfen", systemImage: "checkmark.seal")
                    }
                }
                if !host.openPorts.isDisjoint(with: [80, 443, 8_080, 8_443, 3_000, 8_123]) {
                    NavigationLink { HTTPToolView(address: host.address) } label: {
                        Label("HTTP-Test", systemImage: "arrow.left.arrow.right")
                    }
                }
                NavigationLink { WakeOnLANView(mac: annotation.mac ?? "") } label: {
                    Label("Wake-on-LAN", systemImage: "power")
                }
            }

            Section {
                TextField("Eigener Name", text: Binding(
                    get: { annotation.alias ?? "" }, set: { annotation.alias = $0 }))
                TextField("Hardware-Adresse", text: Binding(
                    get: { annotation.mac ?? "" }, set: { annotation.mac = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                TextField("Notiz", text: Binding(
                    get: { annotation.note ?? "" }, set: { annotation.note = $0 }), axis: .vertical)
            } header: {
                Text("Meine Angaben")
            } footer: {
                Text("Bleiben auf diesem Telefon und gelten für dieses Netz. iOS verrät die Hardware-Adresse nicht; wer sie kennt, kann sie hier für Wake-on-LAN eintragen.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(verbatim: host.address))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            annotation = network.inventory.annotation(address: host.address, subnet: subnet)
            loaded = true
        }
        .onDisappear {
            guard loaded else { return }
            network.inventory.setAnnotation(annotation, address: host.address, subnet: subnet)
        }
    }

    private func webURL(_ port: Int) -> URL? {
        switch port {
        case 80, 8_080, 3_000, 8_123, 8_000, 8_888: URL(string: "http://\(host.address):\(port)")
        case 443, 8_443: URL(string: "https://\(host.address):\(port)")
        default: nil
        }
    }
}

private extension Array where Element == Int {
    func isDisjoint(with other: [Int]) -> Bool {
        Set(self).isDisjoint(with: other)
    }
}
