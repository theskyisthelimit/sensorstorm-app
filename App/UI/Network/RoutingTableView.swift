import SensorstormCore
import SwiftUI

/// The phone's IPv4 routing table: which interface and which router traffic for each network
/// leaves by. Read from the kernel, so it shows what the phone does, not what a router says.
struct RoutingTableView: View {
    @State private var routes: [RouteEntry] = []
    @State private var names: [String: String] = [:]
    @State private var showsAll = false
    @State private var loaded = false

    private var visible: [RouteEntry] {
        routes.filter { showsAll || !$0.isCloned }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return (lhs.destination?.value ?? 0, lhs.prefix ?? 32) < (rhs.destination?.value ?? 0, rhs.prefix ?? 32)
            }
    }

    var body: some View {
        List {
            Section {
                Toggle("Auch automatisch angelegte Einträge", isOn: $showsAll)
            } footer: {
                Text("Das Telefon legt für jedes Gerät, mit dem es spricht, einen Eintrag an (Kürzel W). Sie verdecken die paar Einträge, die jemand eingerichtet hat.")
            }

            Section {
                if visible.isEmpty {
                    Text(loaded ? "iOS gibt die Routingtabelle in dieser Version nicht heraus." : "Lese …")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(visible.enumerated()), id: \.offset) { _, route in
                    row(route)
                }
            } header: {
                Text("\(visible.count) Einträge")
            }

            Section("Kürzel") {
                ForEach(RouteEntry.legend, id: \.letter) { entry in
                    HStack(spacing: 12) {
                        Text(verbatim: entry.letter).font(.body.monospaced().weight(.semibold)).frame(width: 20)
                        Text(verbatim: entry.meaning).foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Routingtabelle")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ route: RouteEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: title(route)).font(.body.monospaced().weight(.semibold))
                Spacer()
                Text(verbatim: route.flagLetters).font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
            switch route.gateway {
            case .address(let address):
                Text(verbatim: names[address.description].map { "\(address) (\($0))" } ?? address.description)
                    .font(.footnote.monospaced()).foregroundStyle(.secondary)
            case .link(let interface, let mac):
                Text(verbatim: mac.map { "link#\(interface) \($0.formatted(uppercase: true))" } ?? "link#\(interface)")
                    .font(.footnote.monospaced()).foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
            Text(verbatim: RouteCache.interfaceName(route.interfaceIndex)).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func title(_ route: RouteEntry) -> String {
        if route.isDefault { return "default" }
        let address = route.destination?.description ?? "0.0.0.0"
        return route.prefix.map { "\(address)/\($0)" } ?? address
    }

    private func load() async {
        routes = RouteCache.read()
        loaded = true
        let gateways = Set(routes.compactMap { route -> IPv4Addr? in
            if case .address(let address) = route.gateway { return address }
            return nil
        })
        let found = await concurrentMap(Array(gateways), limit: 6) { address in
            (address.description, await DNS.systemReverse(address))
        }
        for (address, name) in found { if let name { names[address] = name } }
    }
}
