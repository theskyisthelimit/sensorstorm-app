import SensorstormCore
import SwiftUI

/// Every device the sweep found in the local network, with what it answered to.
struct NetworkScanView: View {
    @Environment(NetworkHub.self) private var network
    @State private var search = ""
    @State private var showsOptions = false

    var body: some View {
        let scanner = network.scanner
        let subnet = network.environment.subnet?.description ?? ""
        let hosts = filtered(scanner.hosts, subnet: subnet)

        List {
            statusSection(scanner)
            if scanner.localNetworkDenied {
                Section { LocalNetworkNotice() }
            }
            if let latest = scanner.latest, scanner.state == .finished,
               let previous = network.inventory.previous(to: latest) {
                changesSection(InventoryDiff.between(previous, latest), since: previous.date)
            }
            Section {
                ForEach(hosts) { host in
                    NavigationLink {
                        HostDetailView(host: host, subnet: subnet, gateway: network.environment.gateway?.description)
                    } label: {
                        HostRow(host: host,
                                annotation: network.inventory.annotation(address: host.address, subnet: subnet),
                                isSelf: host.address == network.environment.lanInterface?.ipv4?.description,
                                isGateway: host.address == network.environment.gateway?.description)
                    }
                }
            } header: {
                if scanner.hosts.isEmpty {
                    Text("Geräte")
                } else {
                    Text("\(hosts.count) von \(scanner.hosts.count) Geräten")
                }
            } footer: {
                if scanner.hosts.isEmpty, scanner.state != .running {
                    Text("Noch nicht gesucht. Der Scan fragt jede Adresse des Netzes mit Ping und kurzen Verbindungsversuchen und liest die Namen, die Geräte im Netz von sich bekannt geben.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: Text("Adresse, Name, Dienst"))
        .navigationTitle("Geräte im Netz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let latest = scanner.latest {
                    ShareLink(item: latest.csv()) {
                        Label("Als Tabelle teilen", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showsOptions = true
                } label: {
                    Label("Optionen", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showsOptions) {
            ScanOptionsView()
        }
        .task { network.environment.start() }
        .onDisappear { scanner.cancel() }
    }

    // MARK: Parts

    @ViewBuilder
    private func statusSection(_ scanner: NetworkScanner) -> some View {
        let environment = network.environment
        Section {
            if scanner.state == .unavailable || (environment.subnet == nil && scanner.state == .idle) {
                Text("Kein lokales Netz gefunden. Verbinde das Telefon mit einem WLAN oder einem Ethernet-Adapter.")
                    .foregroundStyle(.secondary)
            } else {
                if let subnet = environment.subnet {
                    LabeledContent("Netz") { Text(verbatim: subnet.description).monospaced() }
                }
                if let gateway = environment.gateway {
                    LabeledContent("Router") { Text(verbatim: gateway.description).monospaced() }
                }
                if scanner.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: scanner.progress)
                        switch scanner.phase {
                        case .discovering: Text("Suche Geräte …").font(.footnote).foregroundStyle(.secondary)
                        case .enriching: Text("Lese Namen und Ports …").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    if scanner.isRunning {
                        scanner.cancel()
                    } else {
                        scanner.start(environment: environment, inventory: network.inventory)
                    }
                } label: {
                    if scanner.isRunning {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Netz absuchen", systemImage: "play.fill")
                    }
                }
            }
        } footer: {
            if scanner.isWindowed {
                Text("Das Netz hat mehr als 1024 Adressen. Gesucht wird im Bereich um das Telefon.")
            }
        }
    }

    @ViewBuilder
    private func changesSection(_ diff: InventoryDiff, since date: Date) -> some View {
        if !diff.isEmpty {
            Section {
                ForEach(diff.added) { host in
                    Label { Text(verbatim: "\(host.displayName) · \(host.address)") } icon: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                    }
                }
                ForEach(diff.removed) { host in
                    Label { Text(verbatim: "\(host.displayName) · \(host.address)") } icon: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.recording)
                    }
                }
                ForEach(diff.changed, id: \.address) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(change.name) · \(change.address)")
                        if !change.openedPorts.isEmpty {
                            Label("Neu offen: \(NetFormat.ports(change.openedPorts))", systemImage: "lock.open")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        if !change.closedPorts.isEmpty {
                            Label("Jetzt zu: \(NetFormat.ports(change.closedPorts))", systemImage: "lock")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Seit \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private func filtered(_ hosts: [HostRecord], subnet: String) -> [HostRecord] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return hosts }
        return hosts.filter { host in
            let alias = network.inventory.annotation(address: host.address, subnet: subnet).alias ?? ""
            let haystack = ([host.address, alias] + host.hostNames + host.services).joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }
}

struct HostRow: View {
    let host: HostRecord
    let annotation: HostAnnotation
    let isSelf: Bool
    let isGateway: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGateway ? DeviceGuess.router.symbol : host.guess.symbol)
                .frame(minWidth: 28)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: (annotation.alias?.isEmpty == false ? annotation.alias : nil) ?? host.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: host.address).monospaced()
                    if isSelf { Text("Dieses iPhone") }
                    else if isGateway { Text("Router") }
                    else if host.guess != .unknown { Text(host.guess.title) }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: NetFormat.milliseconds(host.roundTrip)).font(.footnote.monospacedDigit())
                if !host.openPorts.isEmpty {
                    Label { Text(verbatim: "\(host.openPorts.count)") } icon: { Image(systemName: "door.left.hand.open") }
                        .font(.footnote.monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct ScanOptionsView: View {
    @Environment(NetworkHub.self) private var network
    @Environment(\.dismiss) private var dismiss
    @State private var customPorts = ""

    var body: some View {
        @Bindable var scanner = network.scanner
        NavigationStack {
            Form {
                Section {
                    Toggle("Ping", isOn: $scanner.options.pingSweep)
                    Toggle("Verbindungsversuche bei Geräten ohne Ping", isOn: $scanner.options.tcpFallback)
                    Toggle("Bonjour-Namen und -Dienste", isOn: $scanner.options.bonjour)
                    Toggle("Namen vom Router (DNS)", isOn: $scanner.options.reverseDNS)
                    Toggle("Windows-Namen (NetBIOS)", isOn: $scanner.options.netbios)
                } header: {
                    Text("Wie gesucht wird")
                } footer: {
                    Text("Ein Gerät, das keinen Ping beantwortet, verrät sich meist durch eine abgelehnte oder angenommene Verbindung. Hardware-Adressen liest iOS nicht aus, deshalb gibt es keine Herstellerangabe.")
                }
                Section {
                    Toggle("Ports der gefundenen Geräte prüfen", isOn: $scanner.options.scansPorts)
                    if scanner.options.scansPorts {
                        Picker("Ports", selection: $scanner.options.portPreset) {
                            Text("Häufige und Geräte-Ports").tag(PortCatalog.Preset.top100)
                            Text("1–1024 und Geräte-Ports").tag(PortCatalog.Preset.wellKnown)
                            Text("Eigene Liste").tag(PortCatalog.Preset.custom)
                        }
                        if scanner.options.portPreset == .custom {
                            TextField("22, 80, 8000-8100", text: $customPorts)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.numbersAndPunctuation)
                                .onChange(of: customPorts) { _, value in
                                    scanner.options.customPorts = PortCatalog.parse(value) ?? []
                                }
                        }
                    }
                } header: {
                    Text("Ports")
                } footer: {
                    Text("Mehr Ports heisst längere Suche. Die Liste mit 1–1024 braucht je Gerät einige Sekunden.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Optionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
