import Charts
import Network
import SensorstormCore
import SwiftUI

// MARK: - Port scan

@MainActor @Observable
final class PortScanModel {
    private(set) var findings: [PortScanner.Finding] = []
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var isRunning = false
    private(set) var invalidPorts = false
    private(set) var failedToResolve = false
    private var task: Task<Void, Never>?

    var progress: Double { total > 0 ? Double(checked) / Double(total) : 0 }

    func start(host: String, preset: PortCatalog.Preset, custom: String, banners: Bool) {
        stop()
        findings = []
        checked = 0
        invalidPorts = false
        failedToResolve = false

        var ports: [Int]
        if preset == .custom {
            guard let parsed = PortCatalog.parse(custom), !parsed.isEmpty else {
                invalidPorts = true
                return
            }
            ports = parsed
        } else {
            ports = PortCatalog.services(preset)
        }
        total = ports.count
        isRunning = true
        task = Task { [weak self] in
            let address = await PingModel.resolve(host)
            guard let self else { return }
            guard let address else {
                failedToResolve = true
                isRunning = false
                return
            }
            let counter = Counter()
            let found = await PortScanner.scan(host: address.description, ports: ports, concurrency: 96,
                                               timeout: 0.9, banners: banners) { _ in
                let done = counter.increment()
                if done % 16 == 0 { Task { @MainActor in self.checked = done } }
            }
            findings = found
            checked = total
            isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

struct PortScanToolView: View {
    @State private var host: String
    @State private var preset: PortCatalog.Preset = .top100
    @State private var custom = ""
    @State private var banners = true
    @State private var model = PortScanModel()

    init(host: String = "") {
        _host = State(initialValue: host)
    }

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse oder Name", text: $host)
                Picker("Ports", selection: $preset) {
                    Text("Häufige und Geräte-Ports").tag(PortCatalog.Preset.top100)
                    Text("1 bis 1024 und Geräte-Ports").tag(PortCatalog.Preset.wellKnown)
                    Text("Eigene Liste").tag(PortCatalog.Preset.custom)
                }
                if preset == .custom {
                    TextField("22, 80, 8000-8100", text: $custom)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }
                Toggle("Banner lesen", isOn: $banners)
                Button {
                    if model.isRunning {
                        model.stop()
                    } else {
                        model.start(host: host, preset: preset, custom: custom, banners: banners)
                    }
                } label: {
                    if model.isRunning {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Starten", systemImage: "play.fill")
                    }
                }
                .disabled(!model.isRunning && host.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Probiert aus, welche TCP-Ports Verbindungen annehmen. Das Banner ist die erste Zeile, mit der sich ein Dienst meldet. Scanne nur Geräte, die dir gehören oder die du prüfen darfst.")
            }

            if model.invalidPorts {
                Section { Text("Die Portliste ist ungültig.").foregroundStyle(.secondary) }
            }
            if model.failedToResolve {
                Section { Text("Der Name lässt sich nicht auflösen.").foregroundStyle(.secondary) }
            }
            if model.isRunning {
                Section {
                    ProgressView(value: model.progress)
                    Text("\(model.checked) von \(model.total) Ports geprüft")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !model.findings.isEmpty || (!model.isRunning && model.checked > 0) {
                Section {
                    if model.findings.isEmpty {
                        Text("Kein Port offen.").foregroundStyle(.secondary)
                    }
                    ForEach(model.findings, id: \.port) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: "\(finding.port)").font(.body.monospacedDigit().weight(.semibold))
                                let name = PortCatalog.name(finding.port)
                                if !name.isEmpty { Text(verbatim: name).foregroundStyle(.secondary) }
                                Spacer()
                                Text(verbatim: NetFormat.milliseconds(finding.roundTrip))
                                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if let banner = finding.banner {
                                Text(verbatim: banner).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(model.findings.count) offen")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Portscan")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }
}

// MARK: - Certificates

@MainActor @Observable
final class TLSModel {
    enum State { case idle, running, failed, done }

    private(set) var state: State = .idle
    private(set) var report: TLSReport?
    private(set) var host = ""

    func inspect(host: String, port: Int) {
        guard state != .running else { return }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = target
        state = .running
        report = nil
        Task { [weak self] in
            let report = await TLSInspector.inspect(host: target, port: port)
            guard let self else { return }
            self.report = report
            state = report == nil ? .failed : .done
        }
    }
}

struct TLSToolView: View {
    @State private var host: String
    @State private var port = 443
    @State private var model = TLSModel()

    init(host: String = "") {
        _host = State(initialValue: host)
    }

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse oder Name", text: $host)
                Stepper(value: $port, in: 1...65_535) {
                    LabeledContent("Port") { Text(verbatim: "\(port)").monospacedDigit() }
                }
                Button {
                    model.inspect(host: host, port: port)
                } label: {
                    Label("Prüfen", systemImage: "checkmark.seal")
                }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || model.state == .running)
            } footer: {
                Text("Baut eine TLS-Verbindung auf und liest, was der Server zeigt, auch bei selbst signierten oder abgelaufenen Zertifikaten. Gesendet wird nur der Handschlag.")
            }

            switch model.state {
            case .running: Section { ProgressView() }
            case .failed: Section { Text("Keine TLS-Verbindung möglich.").foregroundStyle(.secondary) }
            case .idle, .done: EmptyView()
            }

            if let report = model.report {
                Section("Verbindung") {
                    LabeledContent("Protokoll") { Text(verbatim: report.protocolVersion) }
                    if let application = report.applicationProtocol {
                        LabeledContent("ALPN") { Text(verbatim: application).monospaced() }
                    }
                    LabeledContent("Handschlag") { Text(verbatim: NetFormat.milliseconds(report.handshake)).monospacedDigit() }
                    LabeledContent("Vom System anerkannt") { YesNo(value: report.trusted) }
                    if let reason = report.trustError, !report.trusted {
                        Text(verbatim: reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(report.chain.enumerated()), id: \.offset) { index, certificate in
                    certificateSection(certificate, index: index)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Zertifikat prüfen")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func certificateSection(_ certificate: CertificateSummary, index: Int) -> some View {
        Section {
            LabeledContent("Ausgestellt für") {
                Text(verbatim: certificate.subjectCommonName ?? certificate.subjectOrganization ?? "—")
            }
            LabeledContent("Ausgestellt von") {
                Text(verbatim: certificate.issuerCommonName ?? certificate.issuerOrganization ?? "—")
            }
            LabeledContent("Gültig ab") { Text(certificate.notBefore, format: .dateTime.day().month().year()) }
            LabeledContent("Gültig bis") { Text(certificate.notAfter, format: .dateTime.day().month().year()) }
            let days = certificate.daysRemaining()
            if !certificate.isValid() {
                Label("Abgelaufen oder noch nicht gültig", systemImage: "xmark.octagon")
                    .foregroundStyle(Theme.recording)
            } else if days < 30 {
                Label("Läuft in \(days) Tagen ab", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("Noch \(days) Tage gültig", systemImage: "checkmark.circle")
            }
            if certificate.isSelfSigned {
                Label("Selbst signiert", systemImage: "person.badge.key")
            }
            if index == 0, !model.host.isEmpty, !certificate.covers(host: model.host) {
                Label("Gilt nicht für diesen Namen", systemImage: "xmark.octagon")
                    .foregroundStyle(Theme.recording)
            }
            if !certificate.alternativeNames.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alternative Namen").font(.footnote).foregroundStyle(.secondary)
                    Text(verbatim: certificate.alternativeNames.joined(separator: ", ")).font(.footnote.monospaced())
                }
            }
            LabeledContent("Seriennummer") {
                Text(verbatim: certificate.serialNumber).font(.footnote.monospaced())
            }
        } header: {
            if index == 0 {
                Text("Zertifikat des Servers")
            } else {
                Text("Zwischenzertifikat \(index)")
            }
        }
    }
}

// MARK: - HTTP

@MainActor @Observable
final class HTTPModel {
    private(set) var report: HTTPReport?
    private(set) var isRunning = false
    private(set) var invalidURL = false

    func run(address: String, method: String) {
        guard !isRunning else { return }
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else {
            invalidURL = true
            return
        }
        invalidURL = false
        isRunning = true
        report = nil
        Task { [weak self] in
            let report = await HTTPProbe.request(url, method: method)
            guard let self else { return }
            self.report = report
            isRunning = false
        }
    }
}

struct HTTPPhase: Identifiable {
    let name: String
    let seconds: Double
    var id: String { name }
}

struct HTTPToolView: View {
    @State private var address: String
    @State private var method = "GET"
    @State private var model = HTTPModel()

    init(address: String = "") {
        _address = State(initialValue: address)
    }

    var body: some View {
        List {
            Section {
                TextField("Adresse", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Picker("Methode", selection: $method) {
                    Text(verbatim: "GET").tag("GET")
                    Text(verbatim: "HEAD").tag("HEAD")
                }
                .pickerStyle(.segmented)
                Button {
                    model.run(address: address, method: method)
                } label: {
                    Label("Senden", systemImage: "paperplane")
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || model.isRunning)
            } footer: {
                Text("Eine Anfrage, in ihre Abschnitte zerlegt: Namensauflösung, Verbindung, TLS, Wartezeit bis zum ersten Byte und Übertragung.")
            }

            if model.invalidURL {
                Section { Text("Die Adresse ist ungültig.").foregroundStyle(.secondary) }
            }
            if model.isRunning { Section { ProgressView() } }

            if let report = model.report {
                if let error = report.error {
                    Section("Fehler") { Text(verbatim: error) }
                }
                Section("Antwort") {
                    if let status = report.statusCode {
                        LabeledContent("Status") { Text(verbatim: "\(status)").monospacedDigit() }
                    }
                    LabeledContent("Gesamtzeit") { Text(verbatim: NetFormat.milliseconds(report.total)).monospacedDigit() }
                    LabeledContent("Grösse") {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))
                    }
                    if let proto = report.networkProtocol {
                        LabeledContent("Protokoll") { Text(verbatim: proto.uppercased()) }
                    }
                    if let tls = report.tlsVersion { LabeledContent("TLS") { Text(verbatim: tls) } }
                    if let remote = report.remoteAddress {
                        LabeledContent("Server") { Text(verbatim: remote).monospaced() }
                    }
                    if report.redirects > 0 {
                        LabeledContent("Weiterleitungen") { Text(verbatim: "\(report.redirects)").monospacedDigit() }
                        Text(verbatim: report.finalURL).font(.footnote).foregroundStyle(.secondary)
                    }
                    if report.usedProxy { Label("Über einen Proxy", systemImage: "arrow.triangle.branch") }
                }
                phasesSection(report)
                if !report.headers.isEmpty {
                    Section("Kopfzeilen") {
                        ForEach(Array(report.headers.enumerated()), id: \.offset) { _, header in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: header.name).font(.footnote.weight(.semibold))
                                Text(verbatim: header.value).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("HTTP-Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func phasesSection(_ report: HTTPReport) -> some View {
        let dns = report.dns ?? 0
        let connect = report.connect ?? 0
        let tls = report.tls ?? 0
        let wait = report.timeToFirstByte ?? 0
        let transfer = max(report.total - dns - connect - tls - wait, 0)
        let phases = [
            HTTPPhase(name: String(localized: "Namensauflösung"), seconds: dns),
            HTTPPhase(name: String(localized: "Verbindung"), seconds: connect),
            HTTPPhase(name: String(localized: "TLS"), seconds: tls),
            HTTPPhase(name: String(localized: "Wartezeit"), seconds: wait),
            HTTPPhase(name: String(localized: "Übertragung"), seconds: transfer),
        ]
        Section("Abschnitte") {
            Chart {
                ForEach(phases) { phase in
                    BarMark(x: .value("Zeit", phase.seconds * 1_000), y: .value("Wert", phase.name))
                        .foregroundStyle(Theme.accent)
                }
            }
            .chartXAxisLabel { Text(verbatim: "ms") }
            .frame(height: 170)
            ForEach(phases) { phase in
                LabeledContent {
                    Text(verbatim: NetFormat.milliseconds(phase.seconds)).monospacedDigit()
                } label: {
                    Text(verbatim: phase.name)
                }
            }
        }
    }
}

// MARK: - MQTT

@MainActor @Observable
final class MQTTProbeModel {
    struct Message: Identifiable {
        let id = UUID()
        let topic: String
        let payload: String
    }

    enum State: Equatable {
        case idle, running, accepted(String), rejected(String), unreachable(String)
    }

    private(set) var state: State = .idle
    private(set) var connectTime: Double?
    private(set) var messages: [Message] = []
    private(set) var topicCount = 0
    private var task: Task<Void, Never>?

    func start(host: String, port: Int, tls: Bool, username: String, password: String, listens: Bool) {
        stop()
        state = .running
        connectTime = nil
        messages = []
        topicCount = 0
        task = Task { [weak self] in
            guard let outcome = await MQTTProbe.run(host: host, port: port, tls: tls,
                                                    username: username.isEmpty ? nil : username,
                                                    password: password.isEmpty ? nil : password,
                                                    listenSeconds: listens ? 6 : 0,
                                                    onMessage: { topic, payload in
                Task { @MainActor in self?.receive(topic, payload) }
            }) else { return }
            guard let self else { return }
            connectTime = outcome.connectTime
            state = outcome.state
        }
    }

    private func receive(_ topic: String, _ payload: String) {
        if !messages.contains(where: { $0.topic == topic }) { topicCount += 1 }
        messages.insert(Message(topic: topic, payload: payload), at: 0)
        if messages.count > 60 { messages.removeLast(messages.count - 60) }
    }

    func stop() {
        task?.cancel()
        task = nil
        if state == .running { state = .idle }
    }
}

/// One connection to an MQTT broker: does it answer, does it accept these credentials, and what
/// does it carry. The packet encoding is ``MQTTPacket``'s, the same code the live feed uses.
enum MQTTProbe {
    struct Outcome: Sendable {
        var connectTime: Double
        var state: MQTTProbeModel.State
    }

    static func run(host: String, port: Int, tls: Bool, username: String?, password: String?,
                    listenSeconds: Double,
                    onMessage: @escaping @Sendable (String, String) -> Void) async -> Outcome? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let parameters: NWParameters = tls ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "ch.sensorstorm.mqttprobe")
        let started = HostClock.now

        let ready: String? = await withCheckedContinuation { continuation in
            let once = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.fire { continuation.resume(returning: nil) }
                case .failed(let error), .waiting(let error):
                    once.fire { continuation.resume(returning: error.debugDescription) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) {
                once.fire { continuation.resume(returning: String(localized: "Keine Antwort innerhalb der Frist.")) }
            }
        }
        if let problem = ready {
            connection.cancel()
            return Outcome(connectTime: HostClock.now - started, state: .unreachable(problem))
        }
        let connectTime = HostClock.now - started
        defer { connection.cancel() }

        guard let hello = try? MQTTPacket.connect(clientID: "sensorstorm-\(UUID().uuidString.prefix(8))",
                                                  username: username, password: password,
                                                  keepAliveSeconds: 30) else { return nil }
        connection.send(content: hello, completion: .contentProcessed { _ in })

        // The CONNACK, then — if asked — whatever the broker publishes to a wildcard.
        let box = ReceiveBox()
        box.read(from: connection, onMessage: onMessage)

        var connack: Data?
        let deadline = HostClock.now + 5
        while HostClock.now < deadline, !Task.isCancelled {
            if let received = box.connack {
                connack = received
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let connack else {
            return Outcome(connectTime: connectTime,
                           state: .unreachable(String(localized: "Verbunden, aber der Broker antwortet nicht auf MQTT.")))
        }
        let message = MQTTPacket.connackMessage(connack)
        guard MQTTPacket.isAccepted(connack: connack) else {
            return Outcome(connectTime: connectTime, state: .rejected(message))
        }
        if listenSeconds > 0, let subscription = try? MQTTPacket.subscribe(packetID: 1, topics: ["#"]) {
            connection.send(content: subscription, completion: .contentProcessed { _ in })
            // The listening time runs from the subscription, not from the connect.
            let end = HostClock.now + listenSeconds
            while HostClock.now < end, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return Outcome(connectTime: connectTime, state: .accepted(message))
    }
}

/// Collects what arrives on an MQTT connection; the read callbacks come one at a time on the
/// connection's queue, the reader is polled from the task.
private final class ReceiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var _connack: Data?

    var connack: Data? {
        lock.lock(); defer { lock.unlock() }
        return _connack
    }

    func read(from connection: NWConnection, onMessage: @escaping @Sendable (String, String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            if let data { append(data, onMessage: onMessage) }
            if error == nil, !isComplete { read(from: connection, onMessage: onMessage) }
        }
    }

    func append(_ data: Data, onMessage: @Sendable (String, String) -> Void) {
        lock.lock()
        buffer.append(data)
        let packets = MQTTPacket.drain(&buffer)
        for packet in packets {
            if case .connack(let value) = packet { _connack = value }
        }
        lock.unlock()
        for packet in packets {
            if case .publish(let topic, let payload) = packet {
                onMessage(topic, String(decoding: payload.prefix(200), as: UTF8.self))
            }
        }
    }
}

struct MQTTToolView: View {
    @State private var host = ""
    @State private var port = 1_883
    @State private var tls = false
    @State private var username = ""
    @State private var password = ""
    @State private var listens = true
    @State private var model = MQTTProbeModel()

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse des Brokers", text: $host)
                Stepper(value: $port, in: 1...65_535) {
                    LabeledContent("Port") { Text(verbatim: "\(port)").monospacedDigit() }
                }
                Toggle("TLS", isOn: $tls)
                TextField("Benutzername", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Passwort", text: $password)
                Toggle("Sechs Sekunden mithören", isOn: $listens)
                Button {
                    model.start(host: host, port: port, tls: tls, username: username, password: password,
                                listens: listens)
                } label: {
                    Label("Testen", systemImage: "play.fill")
                }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || model.state == .running)
            } footer: {
                Text("Verbindet sich, prüft die Zugangsdaten und hört auf alle Themen („#“), um zu sehen, was der Broker führt. Es wird nichts veröffentlicht.")
            }

            switch model.state {
            case .idle: EmptyView()
            case .running: Section { ProgressView() }
            case .accepted(let text):
                Section {
                    Label { Text(verbatim: text) } icon: { Image(systemName: "checkmark.circle") }
                    if let time = model.connectTime {
                        LabeledContent("Verbindungszeit") { Text(verbatim: NetFormat.milliseconds(time)).monospacedDigit() }
                    }
                }
            case .rejected(let text):
                Section {
                    Label { Text(verbatim: text) } icon: { Image(systemName: "xmark.octagon") }
                        .foregroundStyle(Theme.recording)
                }
            case .unreachable(let text):
                Section {
                    Label { Text(verbatim: text) } icon: { Image(systemName: "wifi.exclamationmark") }
                        .foregroundStyle(Theme.recording)
                }
            }

            if !model.messages.isEmpty {
                Section {
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: message.topic).font(.footnote.weight(.semibold).monospaced())
                            Text(verbatim: message.payload).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                } header: {
                    Text("\(model.topicCount) Themen gehört")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("MQTT-Broker testen")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }
}

// MARK: - Wake-on-LAN

struct WakeOnLANView: View {
    @Environment(NetworkHub.self) private var network
    @State private var mac: String
    @State private var broadcast = ""
    @State private var port = 9
    @State private var sending = false
    @State private var result: Result?

    enum Result: Equatable {
        case sent
        case invalidMAC
        case failed(String)
    }

    init(mac: String = "") {
        _mac = State(initialValue: mac)
    }

    var body: some View {
        List {
            Section {
                TextField("Hardware-Adresse (aa:bb:cc:dd:ee:ff)", text: $mac)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                TextField("Broadcast-Adresse", text: $broadcast)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                Stepper(value: $port, in: 1...65_535) {
                    LabeledContent("Port") { Text(verbatim: "\(port)").monospacedDigit() }
                }
                Button {
                    send()
                } label: {
                    Label("Aufwecken", systemImage: "power")
                }
                .disabled(sending)
            } footer: {
                Text("Schickt das „Magic Packet“ per UDP an die Broadcast-Adresse des Netzes. iOS liest Hardware-Adressen von Geräten nicht aus; sie muss einmal eingegeben werden. Und iOS erlaubt Apps Broadcast im lokalen Netz nur mit einer besonderen Freigabe von Apple. Ohne sie kann das Senden scheitern, ohne dass die App etwas daran ändern kann.")
            }
            switch result {
            case .sent?:
                Section { Label("Gesendet", systemImage: "checkmark.circle") }
            case .invalidMAC?:
                Section { Text("Die Hardware-Adresse ist ungültig.").foregroundStyle(Theme.recording) }
            case .failed(let text)?:
                Section {
                    Text("Das System hat das Senden verweigert.").foregroundStyle(Theme.recording)
                    Text(verbatim: text).font(.footnote).foregroundStyle(.secondary)
                }
            case nil:
                EmptyView()
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Wake-on-LAN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if broadcast.isEmpty, let subnet = network.environment.subnet {
                broadcast = subnet.broadcast.description
            }
        }
    }

    private func send() {
        guard let bytes = WakeOnLAN.parseMAC(mac), let packet = WakeOnLAN.magicPacket(mac: bytes) else {
            result = .invalidMAC
            return
        }
        sending = true
        result = nil
        let target = broadcast.trimmingCharacters(in: .whitespaces).isEmpty ? "255.255.255.255" : broadcast
        let port = UInt16(clamping: self.port)
        Task {
            let error = await UDP.send(host: target, port: port, payload: packet)
            result = error.map { Result.failed($0) } ?? Result.sent
            sending = false
        }
    }
}
