import SensorstormCore
import SwiftUI

/// What the phone knows about its own connection: the path, every interface with its address,
/// the Wi-Fi it is on, the radio it uses, the router, and — only on request — the address the
/// internet sees.
struct NetworkOverviewView: View {
    @Environment(NetworkHub.self) private var network

    var body: some View {
        let environment = network.environment
        List {
            pathSection(environment)
            ForEach(environment.interfaces) { interface in
                interfaceSection(interface)
            }
            wifiSection(environment)
            if !environment.radioTechnologies.isEmpty {
                Section {
                    ForEach(Array(environment.radioTechnologies.enumerated()), id: \.offset) { _, name in
                        Label { Text(verbatim: name) } icon: { Image(systemName: "antenna.radiowaves.left.and.right") }
                    }
                } header: {
                    Text("Mobilfunk")
                } footer: {
                    Text("Die Funktechnik, mit der das Telefon gerade verbunden ist. Netzbetreiber, Zellen-ID und Signalstärke gibt iOS an Apps nicht heraus.")
                }
            }
            routerSection(environment)
            publicSection(environment)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Netzwerk")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            environment.start()
            await environment.refreshWiFi()
        }
        .refreshable {
            environment.refreshInterfaces()
            await environment.refreshWiFi()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func pathSection(_ environment: NetworkEnvironment) -> some View {
        Section("Verbindung") {
            if let path = environment.path {
                LabeledContent("Status") {
                    if path.isSatisfied {
                        Text("Verbunden")
                    } else {
                        Text("Kein Netz")
                    }
                }
                if path.isExpensive {
                    Label("Teuer: Mobilfunk oder Hotspot", systemImage: "dollarsign.circle")
                }
                if path.isConstrained {
                    Label("Datensparmodus ist an", systemImage: "tortoise")
                }
                LabeledContent("IPv4") { YesNo(value: path.supportsIPv4) }
                LabeledContent("IPv6") { YesNo(value: path.supportsIPv6) }
                LabeledContent("Namensauflösung") { YesNo(value: path.supportsDNS) }
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func interfaceSection(_ interface: NetworkInterface) -> some View {
        Section {
            LabeledContent("Name") { Text(verbatim: interface.name).monospaced() }
            if let address = interface.ipv4 {
                LabeledContent("IPv4") { Text(verbatim: address.description).monospaced() }
            }
            if let subnet = interface.subnet {
                LabeledContent("Netz") { Text(verbatim: subnet.description).monospaced() }
                LabeledContent("Geräte im Netz") { Text(verbatim: "\(subnet.hostCount)") }
            }
            ForEach(interface.ipv6, id: \.self) { address in
                LabeledContent("IPv6") {
                    Text(verbatim: address).monospaced().font(.footnote).multilineTextAlignment(.trailing)
                }
            }
            if !interface.isUp {
                Text("Nicht aktiv").foregroundStyle(.secondary)
            }
        } header: {
            Label(interface.kind.title, systemImage: interface.kind.symbol)
        }
    }

    @ViewBuilder
    private func wifiSection(_ environment: NetworkEnvironment) -> some View {
        Section {
            if let wifi = environment.wifi {
                LabeledContent("Name") { Text(verbatim: wifi.ssid) }
                LabeledContent("BSSID") { Text(verbatim: wifi.bssid).monospaced() }
                LabeledContent("Signal") {
                    HStack(spacing: 8) {
                        ProgressView(value: wifi.signalStrength).frame(width: 80)
                        Text(verbatim: String(format: "%.0f %%", wifi.signalStrength * 100)).monospacedDigit()
                    }
                }
                LabeledContent("Verschlüsselt") { YesNo(value: wifi.isSecure) }
            } else if environment.wifiChecked {
                Text("Kein WLAN-Name verfügbar.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } header: {
            Text("WLAN")
        } footer: {
            Text("iOS gibt den WLAN-Namen nur heraus, wenn die App mit WLAN verbunden ist, die Standortfreigabe hat und die Berechtigung „Zugriff auf WLAN-Informationen“ trägt. Die Signalstärke kommt als Wert von 0 bis 100 %, nicht in dBm, und Kanal, Bandbreite oder andere Netze in der Nähe liefert iOS an keine App.")
        }
    }

    @ViewBuilder
    private func routerSection(_ environment: NetworkEnvironment) -> some View {
        if let gateway = environment.gateway {
            Section {
                LabeledContent("Router") { Text(verbatim: gateway.description).monospaced() }
                if environment.gatewayIsGuessed {
                    Text("Geschätzt: iOS hat die Adresse nicht genannt, es ist die erste im Netz.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Router")
            }
        }
    }

    @ViewBuilder
    private func publicSection(_ environment: NetworkEnvironment) -> some View {
        Section {
            if let info = environment.publicAddress {
                LabeledContent("Adresse") { Text(verbatim: info.address).monospaced() }
                if let country = info.country {
                    LabeledContent("Land") { Text(verbatim: country) }
                }
                if let datacenter = info.datacenter {
                    LabeledContent("Rechenzentrum") { Text(verbatim: datacenter) }
                }
                if info.usesWarp {
                    Label("Läuft über Cloudflare WARP", systemImage: "lock.shield")
                }
            }
            Button {
                Task { await environment.queryPublicAddress() }
            } label: {
                if environment.isQueryingPublicAddress {
                    ProgressView()
                } else {
                    Label("Öffentliche Adresse abfragen", systemImage: "globe")
                }
            }
            .disabled(environment.isQueryingPublicAddress)
            if environment.publicAddressFailed {
                Text("Die Abfrage hat nicht geklappt.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Internet")
        } footer: {
            Text("Eine Anfrage an 1.1.1.1 (Cloudflare) zeigt, unter welcher Adresse das Telefon im Internet auftritt. Sie wird nur gesendet, wenn du auf den Knopf tippst.")
        }
    }
}
