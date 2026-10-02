import Charts
import SensorstormCore
import SwiftUI

/// The tools of a network technician, each one a screen. They all take an address or a name,
/// so the field that takes it — with the router and the usual public targets one tap away —
/// is shared.
struct NetworkToolsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { PingToolView() } label: {
                    Label("Ping", systemImage: "waveform.path.ecg")
                }
                NavigationLink { TracerouteToolView() } label: {
                    Label("Traceroute", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                NavigationLink { DNSToolView() } label: {
                    Label("DNS-Abfrage", systemImage: "text.magnifyingglass")
                }
                NavigationLink { PortScanToolView() } label: {
                    Label("Portscan", systemImage: "door.left.hand.open")
                }
                NavigationLink { TLSToolView() } label: {
                    Label("Zertifikat prüfen", systemImage: "checkmark.seal")
                }
                NavigationLink { HTTPToolView() } label: {
                    Label("HTTP-Test", systemImage: "arrow.left.arrow.right")
                }
            } header: {
                Text("Diagnose")
            }
            Section {
                NavigationLink { MQTTToolView() } label: {
                    Label("MQTT-Broker testen", systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink { WakeOnLANView() } label: {
                    Label("Wake-on-LAN", systemImage: "power")
                }
            } header: {
                Text("Weitere")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Werkzeuge")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// An address or name, with the router and a few public targets behind a menu.
struct TargetField: View {
    @Environment(NetworkHub.self) private var network
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack {
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Menu {
                if let gateway = network.environment.gateway {
                    Button {
                        text = gateway.description
                    } label: {
                        Label("Router", systemImage: "wifi.router")
                    }
                }
                Button { text = "1.1.1.1" } label: { Text(verbatim: "Cloudflare · 1.1.1.1") }
                Button { text = "8.8.8.8" } label: { Text(verbatim: "Google · 8.8.8.8") }
                Button { text = "9.9.9.9" } label: { Text(verbatim: "Quad9 · 9.9.9.9") }
                Button { text = "apple.com" } label: { Text(verbatim: "apple.com") }
            } label: {
                Label("Ziele", systemImage: "list.bullet").labelStyle(.iconOnly)
            }
        }
    }
}

// MARK: - Ping

@MainActor @Observable
final class PingModel {
    struct Sample: Identifiable, Equatable {
        let id: Int
        /// Seconds; `nil` for a probe that got no answer.
        let roundTrip: Double?
    }

    enum Failure { case cannotResolve }

    private(set) var samples: [Sample] = []
    private(set) var statistics = PingStatistics()
    private(set) var target: IPv4Addr?
    private(set) var failure: Failure?
    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    /// The newest hundred and twenty, which is what a phone-wide chart can tell apart.
    var recent: [Sample] { Array(samples.suffix(120)) }

    func start(host: String) {
        stop()
        samples = []
        statistics = PingStatistics()
        failure = nil
        target = nil
        isRunning = true
        task = Task { [weak self] in
            let address = await Self.resolve(host)
            guard let self else { return }
            guard let address else {
                failure = .cannotResolve
                isRunning = false
                return
            }
            target = address
            var number = 0
            while !Task.isCancelled {
                let started = HostClock.now
                let result = await ICMP.ping(address, timeout: 1.5)
                number += 1
                let roundTrip = result.reachedTarget ? result.roundTrip : nil
                statistics.record(roundTrip)
                samples.append(Sample(id: number, roundTrip: roundTrip))
                let wait = max(1 - (HostClock.now - started), 0.05)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// An address as typed, or the first IPv4 address the system's resolver finds for a name.
    nonisolated static func resolve(_ host: String) async -> IPv4Addr? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let address = IPv4Addr(trimmed) { return address }
        return await DNS.system(trimmed).addresses.compactMap { IPv4Addr($0) }.first
    }
}

struct PingToolView: View {
    @State private var host: String
    @State private var model = PingModel()

    init(host: String = "") {
        _host = State(initialValue: host)
    }

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse oder Name", text: $host)
                Button {
                    if model.isRunning { model.stop() } else { model.start(host: host) }
                } label: {
                    if model.isRunning {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Starten", systemImage: "play.fill")
                    }
                }
                .disabled(!model.isRunning && host.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Ein Ping je Sekunde über ICMP. Manche Geräte und Firewalls antworten nicht darauf, obwohl sie da sind; dann hilft der Portscan.")
            }

            if model.failure == .cannotResolve {
                Section { Text("Der Name lässt sich nicht auflösen.").foregroundStyle(.secondary) }
            }

            if !model.samples.isEmpty {
                Section("Verlauf") {
                    Chart {
                        ForEach(model.recent) { sample in
                            if let roundTrip = sample.roundTrip {
                                BarMark(x: .value("Zeit", sample.id), y: .value("Wert", roundTrip * 1_000))
                                    .foregroundStyle(Theme.accent)
                            } else {
                                PointMark(x: .value("Zeit", sample.id), y: .value("Wert", 0.0))
                                    .foregroundStyle(Theme.recording)
                            }
                        }
                    }
                    .chartYAxisLabel { Text(verbatim: "ms") }
                    .frame(height: 140)
                }
                Section("Statistik") {
                    if let target = model.target {
                        LabeledContent("Adresse") { Text(verbatim: target.description).monospaced() }
                    }
                    LabeledContent("Gesendet") { Text(verbatim: "\(model.statistics.sent)").monospacedDigit() }
                    LabeledContent("Empfangen") { Text(verbatim: "\(model.statistics.received)").monospacedDigit() }
                    LabeledContent("Verlust") {
                        Text(verbatim: NetFormat.percent(model.statistics.lossPercent)).monospacedDigit()
                    }
                    LabeledContent("Minimum") { Text(verbatim: NetFormat.milliseconds(model.statistics.minimum)).monospacedDigit() }
                    LabeledContent("Mittel") { Text(verbatim: NetFormat.milliseconds(model.statistics.average)).monospacedDigit() }
                    LabeledContent("Maximum") { Text(verbatim: NetFormat.milliseconds(model.statistics.maximum)).monospacedDigit() }
                    LabeledContent("Jitter") { Text(verbatim: NetFormat.milliseconds(model.statistics.jitter)).monospacedDigit() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Ping")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }
}

// MARK: - Traceroute

struct TraceHop: Identifiable, Equatable {
    let id: Int
    var responder: IPv4Addr?
    var name: String?
    var roundTrips: [Double?]
    var reachedTarget = false

    var best: Double? { roundTrips.compactMap { $0 }.min() }
}

@MainActor @Observable
final class TracerouteModel {
    private(set) var hops: [TraceHop] = []
    private(set) var isRunning = false
    private(set) var failedToResolve = false
    private(set) var target: IPv4Addr?
    private var task: Task<Void, Never>?

    static let maximumHops = 30
    static let probesPerHop = 3

    func start(host: String) {
        stop()
        hops = []
        failedToResolve = false
        isRunning = true
        task = Task { [weak self] in
            let resolved = await PingModel.resolve(host)
            guard let self else { return }
            guard let address = resolved else {
                failedToResolve = true
                isRunning = false
                return
            }
            target = address
            for ttl in 1...Self.maximumHops {
                if Task.isCancelled { break }
                var hop = TraceHop(id: ttl, responder: nil, name: nil, roundTrips: [])
                for _ in 0..<Self.probesPerHop {
                    let result = await ICMP.ping(address, ttl: ttl, timeout: 1.5)
                    hop.roundTrips.append(result.roundTrip)
                    if let responder = result.responder { hop.responder = responder }
                    if result.reachedTarget { hop.reachedTarget = true }
                    if Task.isCancelled { break }
                }
                hops.append(hop)
                if let responder = hop.responder {
                    // The name arrives when it arrives; the next hop does not wait for it.
                    Task { [weak self] in
                        let name = await DNS.systemReverse(responder)
                        guard let self, let name, let index = hops.firstIndex(where: { $0.id == ttl }) else { return }
                        hops[index].name = name
                    }
                }
                if hop.reachedTarget { break }
            }
            isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

struct TracerouteToolView: View {
    @State private var host: String
    @State private var model = TracerouteModel()

    init(host: String = "") {
        _host = State(initialValue: host)
    }

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse oder Name", text: $host)
                Button {
                    if model.isRunning { model.stop() } else { model.start(host: host) }
                } label: {
                    if model.isRunning {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Starten", systemImage: "play.fill")
                    }
                }
                .disabled(!model.isRunning && host.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Zeigt die Router auf dem Weg. Jeder Sprung bekommt drei Pakete mit steigender Lebensdauer; ein Router, der nicht antwortet, erscheint als Stern.")
            }

            if model.failedToResolve {
                Section { Text("Der Name lässt sich nicht auflösen.").foregroundStyle(.secondary) }
            }

            if !model.hops.isEmpty {
                Section("Weg") {
                    ForEach(model.hops) { hop in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "\(hop.id)").monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                if let responder = hop.responder {
                                    Text(verbatim: hop.name ?? responder.description)
                                    if hop.name != nil {
                                        Text(verbatim: responder.description).font(.footnote).monospaced()
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(verbatim: "*")
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: NetFormat.milliseconds(hop.best)).monospacedDigit()
                                if hop.reachedTarget {
                                    Image(systemName: "flag.checkered").foregroundStyle(Theme.accent)
                                        .accessibilityLabel("Ziel erreicht")
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Traceroute")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }
}

// MARK: - DNS

enum DNSServerChoice: Hashable, Identifiable {
    case system, cloudflare, google, quad9, router, custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .cloudflare: "Cloudflare"
        case .google: "Google"
        case .quad9: "Quad9"
        case .router: "Router"
        case .custom: "Eigener Server"
        }
    }

    /// `nil` for the system resolver, which is not asked over the wire by this app.
    func address(router: IPv4Addr?, custom: String) -> String? {
        switch self {
        case .system: nil
        case .cloudflare: "1.1.1.1"
        case .google: "8.8.8.8"
        case .quad9: "9.9.9.9"
        case .router: router?.description
        case .custom: custom.trimmingCharacters(in: .whitespaces).isEmpty ? nil : custom
        }
    }
}

struct DNSOutcome: Identifiable {
    let id = UUID()
    var choice: DNSServerChoice
    var server: String
    var rcode: String?
    var roundTrip: Double?
    var records: [DNSRecord]
    var answered: Bool
}

@MainActor @Observable
final class DNSModel {
    private(set) var outcomes: [DNSOutcome] = []
    private(set) var isRunning = false

    func query(name: String, type: DNSRecordType, choices: [DNSServerChoice], router: IPv4Addr?, custom: String) {
        guard !isRunning else { return }
        isRunning = true
        outcomes = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            let results = await withTaskGroup(of: DNSOutcome?.self) { group -> [DNSOutcome] in
                for choice in choices {
                    group.addTask {
                        if choice == .system {
                            let system = await DNS.system(trimmed)
                            let records = system.addresses.map {
                                DNSRecord(name: trimmed, type: $0.contains(":") ? 28 : 1, ttl: 0, value: $0)
                            }
                            return DNSOutcome(choice: choice, server: String(localized: "System"), rcode: nil,
                                              roundTrip: system.seconds, records: records, answered: !records.isEmpty)
                        }
                        guard let server = choice.address(router: router, custom: custom) else { return nil }
                        let lookup = await DNS.query(trimmed, type: type, server: server)
                        return DNSOutcome(choice: choice, server: server, rcode: lookup.response?.rcodeLabel,
                                          roundTrip: lookup.roundTrip, records: lookup.response?.answers ?? [],
                                          answered: lookup.response != nil)
                    }
                }
                var collected: [DNSOutcome] = []
                for await outcome in group { if let outcome { collected.append(outcome) } }
                return collected
            }
            guard let self else { return }
            outcomes = results.sorted { ($0.roundTrip ?? .infinity) < ($1.roundTrip ?? .infinity) }
            isRunning = false
        }
    }
}

struct DNSToolView: View {
    @Environment(NetworkHub.self) private var network
    @State private var name = ""
    @State private var type: DNSRecordType = .a
    @State private var choice: DNSServerChoice = .cloudflare
    @State private var customServer = ""
    @State private var model = DNSModel()

    private let types: [DNSRecordType] = [.a, .aaaa, .cname, .mx, .txt, .ns, .soa, .ptr, .srv, .any]

    init(name: String = "") {
        _name = State(initialValue: name)
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Picker("Typ", selection: $type) {
                    ForEach(types, id: \.self) { type in Text(verbatim: type.label).tag(type) }
                }
                Picker("Server", selection: $choice) {
                    ForEach([DNSServerChoice.system, .cloudflare, .google, .quad9, .router, .custom]) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if choice == .custom {
                    TextField("Adresse des Servers", text: $customServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                }
                Button {
                    run([choice])
                } label: {
                    Label("Abfragen", systemImage: "magnifyingglass")
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isRunning)
                Button {
                    run([.system, .cloudflare, .google, .quad9, .router])
                } label: {
                    Label("Bei allen Servern vergleichen", systemImage: "rectangle.3.group")
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isRunning)
            } footer: {
                Text("Fragt den Server direkt über UDP Port 53. Der Vergleich zeigt, ob das Netz einen Namen anders auflöst als die öffentlichen Server — ein Hinweis auf Filter, Umleitungen und fehlerhafte Router.")
            }

            if model.isRunning {
                Section { ProgressView() }
            }
            ForEach(model.outcomes) { outcome in
                Section {
                    LabeledContent("Antwortzeit") { Text(verbatim: NetFormat.milliseconds(outcome.roundTrip)).monospacedDigit() }
                    if let rcode = outcome.rcode {
                        LabeledContent("Status") { Text(verbatim: rcode).monospaced() }
                    }
                    if !outcome.answered {
                        Text("Keine Antwort.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(outcome.records.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: record.value).font(.callout.monospaced())
                            Text(verbatim: "\(record.name) · \(record.typeLabel) · TTL \(record.ttl)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(verbatim: outcome.server)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("DNS-Abfrage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ choices: [DNSServerChoice]) {
        model.query(name: name, type: type, choices: choices, router: network.environment.gateway,
                    custom: customServer)
    }
}
