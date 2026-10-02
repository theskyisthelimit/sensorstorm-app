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
    /// Who runs the router: asked of the DNS, and only when the person left that on.
    var owner: ASNInfo?
    var roundTrips: [Double?]
    var reachedTarget = false

    var best: Double? { roundTrips.compactMap { $0 }.min() }
    var worst: Double? { roundTrips.compactMap { $0 }.max() }
    var average: Double? {
        let answered = roundTrips.compactMap { $0 }
        return answered.isEmpty ? nil : answered.reduce(0, +) / Double(answered.count)
    }
    /// Percent of the probes this hop did not answer.
    var lossPercent: Double {
        roundTrips.isEmpty ? 0 : Double(roundTrips.filter { $0 == nil }.count) / Double(roundTrips.count) * 100
    }
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

    /// The route as text, for pasting into a ticket.
    var report: String {
        var lines = ["traceroute to \(target?.description ?? "?")"]
        for hop in hops {
            var line = String(format: "%2d  ", hop.id)
            if let responder = hop.responder {
                line += hop.name.map { "\($0) (\(responder))" } ?? responder.description
                line += "  " + NetFormat.milliseconds(hop.best)
                if let owner = hop.owner {
                    line += "  " + [owner.label, owner.countryCode].compactMap { $0 }.joined(separator: " ")
                }
            } else {
                line += "*"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func start(host: String, looksUpOwners: Bool) {
        stop()
        hops = []
        failedToResolve = false
        isRunning = true
        task = Task { [weak self] in
            let resolver = looksUpOwners ? (SystemDNS.servers().first { IPv4Addr($0) != nil } ?? "1.1.1.1") : nil
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
                    if let resolver {
                        Task { [weak self] in
                            let owner = await ASNCache.shared.lookup(responder, server: resolver)
                            guard let self, let owner, let index = hops.firstIndex(where: { $0.id == ttl }) else { return }
                            hops[index].owner = owner
                        }
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
    @AppStorage("network.traceLooksUpOwners") private var looksUpOwners = true

    init(host: String = "") {
        _host = State(initialValue: host)
    }

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse oder Name", text: $host)
                Button {
                    if model.isRunning { model.stop() } else { model.start(host: host, looksUpOwners: looksUpOwners) }
                } label: {
                    if model.isRunning {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Starten", systemImage: "play.fill")
                    }
                }
                .disabled(!model.isRunning && host.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle("Netzbetreiber und Land nachschlagen", isOn: $looksUpOwners)
            } footer: {
                Text("Zeigt die Router auf dem Weg. Jeder Sprung bekommt drei Pakete mit steigender Lebensdauer; ein Router, der nicht antwortet, erscheint als Stern. Für Netzbetreiber und Land geht die Adresse jedes öffentlichen Routers als Namensabfrage an den DNS-Server des Netzes, der sie an Team Cymru weiterreicht.")
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
                                    if let owner = hop.owner {
                                        Text(verbatim: [owner.flag, owner.label].compactMap { $0 }.joined(separator: " "))
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(verbatim: "*")
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: NetFormat.milliseconds(hop.best)).monospacedDigit()
                                if hop.lossPercent > 0 && hop.responder != nil {
                                    Text(verbatim: NetFormat.percent(hop.lossPercent))
                                        .font(.caption).foregroundStyle(.orange)
                                }
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
        .toolbar {
            if !model.hops.isEmpty && !model.isRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.report) {
                        Label("Als Text teilen", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
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
    /// The record type asked for, as the label (`MX`); `nil` for the system resolver, which is
    /// asked for addresses and nothing else.
    var typeLabel: String?
    var rcode: String?
    var roundTrip: Double?
    var records: [DNSRecord]
    var answered: Bool
    var flags: [String] = []
    var queryID: UInt16?
}

@MainActor @Observable
final class DNSModel {
    private(set) var outcomes: [DNSOutcome] = []
    private(set) var isRunning = false

    func query(name: String, types: [DNSRecordType], choices: [DNSServerChoice], router: IPv4Addr?, custom: String) {
        guard !isRunning else { return }
        isRunning = true
        outcomes = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            let results = await withTaskGroup(of: DNSOutcome?.self) { group -> [DNSOutcome] in
                for choice in choices {
                    if choice == .system {
                        group.addTask {
                            let system = await DNS.system(trimmed)
                            let records = system.addresses.map {
                                DNSRecord(name: trimmed, type: $0.contains(":") ? 28 : 1, ttl: 0, value: $0)
                            }
                            return DNSOutcome(choice: choice, server: String(localized: "System"), typeLabel: nil,
                                              rcode: nil, roundTrip: system.seconds, records: records,
                                              answered: !records.isEmpty)
                        }
                        continue
                    }
                    guard let server = choice.address(router: router, custom: custom) else { continue }
                    for type in types {
                        group.addTask {
                            let lookup = await DNS.query(trimmed, type: type, server: server)
                            // The answer section can hold a CNAME chain before the records asked for;
                            // an SOA in the authority section is how a server says „nothing here".
                            let response = lookup.response
                            let records = (response?.answers ?? []) + (response?.answers.isEmpty == true
                                ? (response?.authorities ?? []) : [])
                            return DNSOutcome(choice: choice, server: server, typeLabel: type.label,
                                              rcode: response?.rcodeLabel, roundTrip: lookup.roundTrip,
                                              records: records, answered: response != nil,
                                              flags: response?.flagNames ?? [], queryID: response?.id)
                        }
                    }
                }
                var collected: [DNSOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            guard let self else { return }
            // A comparison of servers is ranked by speed; the list of all types keeps the order
            // the types were asked in, which is the order a person looks them up.
            if types.count > 1 {
                let order = types.map(\.label)
                outcomes = results.sorted {
                    (order.firstIndex(of: $0.typeLabel ?? "") ?? 0) < (order.firstIndex(of: $1.typeLabel ?? "") ?? 0)
                }
            } else {
                outcomes = results.sorted { ($0.roundTrip ?? .infinity) < ($1.roundTrip ?? .infinity) }
            }
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
    @State private var asksAllTypes = false

    private let types: [DNSRecordType] = [.a, .aaaa, .cname, .mx, .txt, .ns, .soa, .caa, .ptr, .srv, .any]
    /// What „all types" asks, in the order a person reads a domain: where it points, who takes
    /// its mail, who runs it, who may issue certificates for it, and its free text.
    private let commonTypes: [DNSRecordType] = [.a, .aaaa, .cname, .mx, .ns, .soa, .caa, .txt]

    init(name: String = "") {
        _name = State(initialValue: name)
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Toggle("Alle gängigen Typen", isOn: $asksAllTypes)
                if !asksAllTypes {
                    Picker("Typ", selection: $type) {
                        ForEach(types, id: \.self) { type in Text(verbatim: type.label).tag(type) }
                    }
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
                Text("Fragt den Server direkt über UDP Port 53. Der Vergleich zeigt, ob das Netz einen Namen anders auflöst als die öffentlichen Server. Das ist ein Hinweis auf Filter, Umleitungen und fehlerhafte Router.")
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
                    if !outcome.flags.isEmpty {
                        LabeledContent("Flags") { Text(verbatim: outcome.flags.joined(separator: " ")).monospaced() }
                    }
                    if let id = outcome.queryID {
                        LabeledContent("ID") { Text(verbatim: String(format: "0x%04X", id)).monospaced() }
                    }
                    if !outcome.answered {
                        Text("Keine Antwort.").foregroundStyle(.secondary)
                    } else if outcome.records.isEmpty {
                        Text("Keine Einträge dieses Typs.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(outcome.records.enumerated()), id: \.offset) { _, record in
                        DNSRecordRow(record: record)
                    }
                } header: {
                    Text(verbatim: [outcome.typeLabel, outcome.server].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("DNS-Abfrage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run(_ choices: [DNSServerChoice]) {
        model.query(name: name, types: asksAllTypes && choices.count == 1 ? commonTypes : [type],
                    choices: choices, router: network.environment.gateway, custom: customServer)
    }
}

/// One answer record: the data large, and below it the name, the type and how long it may be
/// cached. An SOA is spread out, because seven fields on one line cannot be read.
struct DNSRecordRow: View {
    let record: DNSRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let soa = record.soa {
                field("Primärer Server", soa.primary)
                field("Zuständig", soa.mailbox)
                field("Seriennummer", String(soa.serial))
                field("Aktualisierung", Self.duration(soa.refresh))
                field("Wiederholung", Self.duration(soa.retry))
                field("Ablauf", Self.duration(soa.expire))
                field("Minimale Lebensdauer", Self.duration(soa.minimum))
            } else {
                Text(verbatim: record.value).font(.callout.monospaced()).textSelection(.enabled)
            }
            Text(verbatim: "\(record.name) · \(record.typeLabel) · TTL \(Self.duration(record.ttl))")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) { Text(verbatim: value).font(.callout.monospaced()).textSelection(.enabled) }
    }

    /// `3600` → `1 h`, `300` → `5 min`, `45` → `45 s`, with the raw seconds kept for anything
    /// that is not a round number.
    static func duration(_ seconds: UInt32) -> String {
        if seconds >= 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400) d" }
        if seconds >= 3_600, seconds % 3_600 == 0 { return "\(seconds / 3_600) h" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}
