import SensorstormCore
import SwiftUI
import UIKit

/// One device's services and characteristics, live. Owns the connection through the shared
/// Bluetooth source and turns its events into something a view can read.
@MainActor
@Observable
final class GATTExplorerModel {
    enum Phase: Equatable {
        case connecting
        case connected
        case failed(String)
        case disconnected(String?)
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    let deviceID: UUID
    let deviceName: String
    private(set) var phase: Phase = .connecting
    private(set) var services: [GATTServiceInfo] = []
    private(set) var rssi: Double?
    private(set) var log: [LogLine] = []

    private let source: BluetoothSource
    private var lastValues: [String: Data] = [:]
    private var isStarted = false

    init(deviceID: UUID, deviceName: String, source: BluetoothSource) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.source = source
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        source.acquireScanner()
        source.onExplorerEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        source.explorerConnect(deviceID)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        source.onExplorerEvent = nil
        source.explorerDisconnect()
        source.releaseScanner()
    }

    func reconnect() {
        phase = .connecting
        source.explorerConnect(deviceID)
    }

    func read(_ id: String) { source.explorerRead(id) }
    func setNotify(_ id: String, on: Bool) { source.explorerSetNotify(id, on: on) }
    func readRSSI() { source.explorerReadRSSI() }

    func write(_ id: String, data: Data, withResponse: Bool) {
        note("→ \(shortID(id)) \(HexCoding.string(data))")
        source.explorerWrite(id, data: data, withResponse: withResponse)
    }

    var maximumWriteLength: Int? { source.explorerMaximumWriteLength(withResponse: true) }

    func characteristic(_ id: String) -> GATTCharacteristicInfo? {
        services.lazy.flatMap(\.characteristics).first { $0.id == id }
    }

    /// The log as text, for sharing.
    var logText: String {
        let formatter = ISO8601DateFormatter()
        return log.reversed().map { "\(formatter.string(from: $0.time)) \($0.text)" }.joined(separator: "\n")
    }

    private func handle(_ event: GATTExplorerEvent) {
        switch event {
        case .connected:
            phase = .connected
            note("verbunden")
        case .failed(let message):
            phase = .failed(message)
        case .disconnected(let message):
            phase = .disconnected(message)
            note("getrennt")
        case .services(let list):
            services = list
            if phase == .connecting { phase = .connected }
            for characteristic in list.flatMap(\.characteristics) {
                guard let value = characteristic.value, lastValues[characteristic.id] != value else { continue }
                lastValues[characteristic.id] = value
                var line = "← \(shortID(characteristic.id)) \(HexCoding.string(value))"
                if let decoded = characteristic.decoded() {
                    line += " · " + decoded.fields.map { "\($0.name) \(Format.value($0.value))" }.joined(separator: ", ")
                }
                note(line)
            }
        case .rssi(let value):
            rssi = value
        case .written(let id, let error):
            if let error { note("✗ \(shortID(id)) \(error)") } else { note("✓ \(shortID(id))") }
        }
    }

    private func shortID(_ id: String) -> String {
        let characteristic = id.split(separator: "/").last.map(String.init) ?? id
        return BluetoothNames.shortForm(String(characteristic.split(separator: "#").first ?? ""))
    }

    private func note(_ text: String) {
        log.insert(LogLine(time: Date(), text: text), at: 0)
        if log.count > 200 { log.removeLast() }
    }
}

struct GATTExplorerView: View {
    let deviceID: UUID
    let deviceName: String

    @Environment(SensorHub.self) private var hub
    @State private var model: GATTExplorerModel?
    @State private var writeTarget: GATTCharacteristicInfo?
    @State private var templateTarget: GATTCharacteristicInfo?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(deviceName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = GATTExplorerModel(deviceID: deviceID, deviceName: deviceName,
                                          source: hub.bluetoothSource)
            }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder
    private func content(_ model: GATTExplorerModel) -> some View {
        List {
            Section { statusRow(model) }

            ForEach(model.services) { service in
                Section {
                    ForEach(service.characteristics) { characteristic in
                        GATTCharacteristicRow(
                            info: characteristic, deviceID: deviceID, deviceName: deviceName,
                            model: model,
                            onWrite: { writeTarget = characteristic },
                            onTemplate: { templateTarget = characteristic })
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: service.name ?? BluetoothNames.shortForm(service.uuid))
                        if service.name != nil {
                            Text(verbatim: BluetoothNames.shortForm(service.uuid))
                                .font(.caption2.monospaced())
                                .textCase(nil)
                        }
                    }
                }
            }

            if !model.log.isEmpty {
                Section {
                    ForEach(model.log.prefix(60)) { line in
                        Text(verbatim: "\(line.time.formatted(date: .omitted, time: .standard))  \(line.text)")
                            .font(.caption2.monospaced())
                            .lineLimit(2)
                    }
                    ShareLink(item: model.logText) {
                        Label("Protokoll teilen", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Protokoll")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $writeTarget) { target in
            GATTWriteSheet(info: target, maximumLength: model.maximumWriteLength) { data, withResponse in
                model.write(target.id, data: data, withResponse: withResponse)
            }
        }
        .sheet(item: $templateTarget) { target in
            GATTTemplateSheet(info: target) { template in
                var chosen = subscription(for: target, pollSeconds: nil)
                chosen.template = template
                record(chosen)
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ model: GATTExplorerModel) -> some View {
        switch model.phase {
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                Text("Verbinde …")
            }
        case .connected:
            HStack {
                Label("Verbunden", systemImage: "link")
                    .foregroundStyle(.green)
                Spacer()
                if let rssi = model.rssi {
                    Text(verbatim: "\(Int(rssi)) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SignalQuality.color(rssi))
                }
                Button {
                    model.readRSSI()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Signal neu messen"))
            }
            if model.services.isEmpty {
                Text("Suche Dienste …").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            failureRow(model, message: message)
        case .disconnected(let message):
            failureRow(model, message: message ?? String(localized: "getrennt"))
        }
    }

    private func failureRow(_ model: GATTExplorerModel, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nicht verbunden", systemImage: "link.badge.plus")
                .foregroundStyle(.orange)
            Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
            Button("Erneut verbinden") { model.reconnect() }
        }
    }

    // MARK: Recording a characteristic

    func subscription(for info: GATTCharacteristicInfo, pollSeconds: Double?) -> GATTSubscription {
        GATTSubscription(device: deviceID, deviceName: deviceName, service: info.serviceUUID,
                         characteristic: info.uuid,
                         characteristicName: info.userDescription ?? info.name ?? BluetoothNames.shortForm(info.uuid),
                         pollSeconds: pollSeconds, presentation: info.presentation)
    }

    /// Choosing a characteristic to record also switches on the two things recording it needs:
    /// the Bluetooth stream, and reading what devices send — the same consent the sensor
    /// screen asks for, given here by the act of choosing.
    private func record(_ subscription: GATTSubscription) {
        hub.settings.setRecording(true, subscription)
        hub.settings.setEnabled(true, for: .bluetooth)
        hub.settings.decodesBluetoothSensors = true
    }
}

struct GATTCharacteristicRow: View {
    let info: GATTCharacteristicInfo
    let deviceID: UUID
    let deviceName: String
    let model: GATTExplorerModel
    let onWrite: () -> Void
    let onTemplate: () -> Void

    @Environment(SensorHub.self) private var hub
    @State private var format: GATTValueFormat?

    private var subscription: GATTSubscription {
        GATTSubscription(device: deviceID, deviceName: deviceName, service: info.serviceUUID,
                         characteristic: info.uuid,
                         characteristicName: info.userDescription ?? info.name ?? BluetoothNames.shortForm(info.uuid),
                         pollSeconds: nil, presentation: info.presentation)
    }

    private var chosen: GATTSubscription? {
        (hub.settings.gattSubscriptions ?? []).first { $0.id == subscription.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: info.userDescription ?? info.name ?? BluetoothNames.shortForm(info.uuid))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if chosen != nil {
                    Image(systemName: "record.circle").foregroundStyle(Theme.recording)
                        .accessibilityLabel(Text("Wird aufgezeichnet"))
                }
            }
            HStack(spacing: 8) {
                Text(verbatim: BluetoothNames.shortForm(info.uuid))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                GATTPropertyBadges(properties: info.properties)
            }

            if let value = info.value {
                valueBlock(value)
            }
            actions
        }
        .padding(.vertical, 4)
    }

    private func valueBlock(_ value: Data) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if value.count > 16 {
                // A long value as a dump: offsets on the left, the printable reading on the right.
                Text(verbatim: HexCoding.dump(value))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(verbatim: HexCoding.string(value))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(verbatim: HexCoding.ascii(value))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            formatLine(value)
            if let decoded = info.decoded() {
                Text(verbatim: decoded.fields.map {
                    "\($0.name) \(Format.value($0.value, unit: unit(of: $0.name, decoder: decoded.decoder)))"
                }.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// The value in the format the person picked, beside the default reading.
    @ViewBuilder
    private func formatLine(_ value: Data) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Menu {
                Picker("Als", selection: $format) {
                    Text("Standard").tag(GATTValueFormat?.none)
                    ForEach(GATTValueFormat.allCases) { format in
                        Text(format.title).tag(Optional(format))
                    }
                }
            } label: {
                Label("Format", systemImage: "textformat.123").font(.caption2)
            }
            if let format {
                if let text = format.render(value) {
                    Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                } else {
                    Text("So nicht lesbar").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func unit(of field: String, decoder: String) -> String {
        if field == "value", let presentation = info.presentation { return presentation.unitSymbol }
        return BLEUnits.unit(for: field, decoder: decoder)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            if info.canRead {
                Button {
                    model.read(info.id)
                } label: {
                    Label("Lesen", systemImage: "arrow.down.circle")
                }
            }
            if info.canNotify {
                Button {
                    model.setNotify(info.id, on: !info.isNotifying)
                } label: {
                    // Two labels rather than a ternary of literals, which is a `String`.
                    if info.isNotifying {
                        Label("Stopp", systemImage: "bell.slash")
                    } else {
                        Label("Abonnieren", systemImage: "bell")
                    }
                }
            }
            if info.canWrite {
                Button(action: onWrite) {
                    Label("Schreiben", systemImage: "square.and.pencil")
                }
            }
            if info.canRead || info.canNotify {
                recordMenu
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private var recordMenu: some View {
        Menu {
            if chosen != nil {
                Button(role: .destructive) {
                    hub.settings.setRecording(false, subscription)
                } label: {
                    Label("Nicht mehr aufzeichnen", systemImage: "stop.circle")
                }
                Divider()
            }
            if info.canNotify {
                Button { choose(poll: nil) } label: { Label("Bei Benachrichtigung", systemImage: "bell") }
            }
            if info.canRead {
                ForEach([1.0, 5.0, 10.0, 60.0], id: \.self) { seconds in
                    Button { choose(poll: seconds) } label: {
                        Label("Alle \(Int(seconds)) s lesen", systemImage: "clock")
                    }
                }
            }
            Divider()
            Button(action: onTemplate) {
                Label("Als Zahlen lesen …", systemImage: "number")
            }
        } label: {
            Label("Aufzeichnen", systemImage: "record.circle")
        }
    }

    private func choose(poll: Double?) {
        var next = subscription
        next.pollSeconds = poll
        // Keep a template the user already made for this characteristic.
        next.template = chosen?.template
        hub.settings.setRecording(true, next)
        hub.settings.setEnabled(true, for: .bluetooth)
        hub.settings.decodesBluetoothSensors = true
    }
}

// MARK: - Property badges

extension GATTCharacteristicInfo.Property {
    /// What the mark stands for, for VoiceOver and the legend.
    var title: LocalizedStringKey {
        switch self {
        case .broadcast: "Senden (Broadcast)"
        case .read: "Lesen"
        case .writeWithoutResponse: "Schreiben ohne Antwort"
        case .write: "Schreiben"
        case .notify: "Benachrichtigung"
        case .indicate: "Bestätigte Benachrichtigung"
        case .authenticatedSignedWrites: "Signiertes Schreiben"
        case .extendedProperties: "Erweiterte Eigenschaften"
        case .notifyEncryptionRequired: "Benachrichtigung nur verschlüsselt"
        case .indicateEncryptionRequired: "Bestätigte Benachrichtigung nur verschlüsselt"
        }
    }

    var tint: Color {
        switch self {
        case .read: .green
        case .write, .writeWithoutResponse, .authenticatedSignedWrites: .orange
        case .notify, .indicate: .blue
        case .notifyEncryptionRequired, .indicateEncryptionRequired: .purple
        case .broadcast, .extendedProperties: .gray
        }
    }
}

extension GATTValueFormat {
    var title: LocalizedStringKey {
        switch self {
        case .hex: "Hex"
        case .text: "Text"
        case .decimal: "Dezimal"
        case .unsigned: "Ganzzahl"
        case .signed: "Ganzzahl mit Vorzeichen"
        case .float: "Fliesskomma"
        case .binary: "Binär"
        }
    }
}

/// The marks of a characteristic — R, W, WWR, N, I, ASW, NENC, IENC — as small tinted tags.
struct GATTPropertyBadges: View {
    let properties: [GATTCharacteristicInfo.Property]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(properties, id: \.self) { property in
                Text(verbatim: property.badge)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 15)
                    .background(property.tint, in: Capsule())
                    .accessibilityLabel(Text(property.title))
            }
        }
    }
}

// MARK: - Writing

struct GATTWriteSheet: View {
    let info: GATTCharacteristicInfo
    let maximumLength: Int?
    let onWrite: (Data, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case hex, text, number
        var id: String { rawValue }
    }

    private enum Width: Int, CaseIterable, Identifiable {
        case one = 1, two = 2, four = 4
        var id: Int { rawValue }
    }

    @State private var mode: Mode = .hex
    @State private var input = ""
    @State private var width: Width = .one
    @State private var bigEndian = false
    @State private var withResponse = true
    @State private var isConfirming = false

    private var data: Data? {
        switch mode {
        case .hex: return HexCoding.data(input)
        case .text: return input.isEmpty ? nil : Data(input.utf8)
        case .number:
            guard let value = UInt64(input.trimmingCharacters(in: .whitespaces)) else { return nil }
            // A number that does not fit the chosen width would be cut silently.
            guard width.rawValue >= 8 || value < (UInt64(1) << (8 * UInt64(width.rawValue))) else { return nil }
            return HexCoding.bytes(of: value, width: width.rawValue, bigEndian: bigEndian)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Eingabe", selection: $mode) {
                        Text(verbatim: "Hex").tag(Mode.hex)
                        Text("Text").tag(Mode.text)
                        Text("Zahl").tag(Mode.number)
                    }
                    .pickerStyle(.segmented)
                    TextField(text: $input) { Text(verbatim: mode == .hex ? "0A FF 12" : "") }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if mode == .number {
                        Picker("Breite", selection: $width) {
                            Text(verbatim: "8 bit").tag(Width.one)
                            Text(verbatim: "16 bit").tag(Width.two)
                            Text(verbatim: "32 bit").tag(Width.four)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Big Endian", isOn: $bigEndian)
                    }
                } footer: {
                    if let data {
                        Text(verbatim: "\(data.count) B · \(HexCoding.string(data))")
                            .font(.caption.monospaced())
                    } else if !input.isEmpty {
                        Text("Das lässt sich nicht als Wert lesen.")
                    }
                }
                Section {
                    if info.properties.contains(.write) && info.properties.contains(.writeWithoutResponse) {
                        Toggle("Mit Bestätigung des Geräts", isOn: $withResponse)
                    }
                    if let maximumLength {
                        LabeledContent("Höchstens") { Text(verbatim: "\(maximumLength) B") }
                    }
                } footer: {
                    Text("Ein falscher Wert kann ein Gerät verstellen. Geschrieben wird erst nach einer Rückfrage.")
                }
            }
            .navigationTitle(info.userDescription ?? info.name ?? BluetoothNames.shortForm(info.uuid))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schreiben") { isConfirming = true }
                        .disabled(data == nil || data?.isEmpty == true
                                  || (maximumLength.map { (data?.count ?? 0) > $0 } ?? false))
                }
            }
            .confirmationDialog("Wert wirklich schreiben?", isPresented: $isConfirming,
                                titleVisibility: .visible) {
                Button("Schreiben", role: .destructive) {
                    if let data {
                        onWrite(data, info.properties.contains(.write) ? withResponse : false)
                        dismiss()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Das Gerät führt aus, was es empfängt.")
            }
            .onAppear {
                withResponse = info.properties.contains(.write)
            }
        }
    }
}

// MARK: - A recipe for a characteristic nobody decodes

/// Where each number sits in the value, how wide it is and what to multiply by — enough for
/// the many sensors that send a few fixed-width fields, with no code.
struct GATTTemplateSheet: View {
    let info: GATTCharacteristicInfo
    let onSave: (GATTTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        var field: GATTTemplate.Field
    }

    @State private var name: String
    @State private var entries: [Entry]

    init(info: GATTCharacteristicInfo, onSave: @escaping (GATTTemplate) -> Void) {
        self.info = info
        self.onSave = onSave
        _name = State(initialValue: info.userDescription ?? info.name ?? BluetoothNames.shortForm(info.uuid))
        _entries = State(initialValue: [Entry(field: GATTTemplate.Field(name: "value", offset: 0, type: .uint8))])
    }

    private var template: GATTTemplate {
        GATTTemplate(characteristic: info.uuid, name: name, fields: entries.map(\.field))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let value = info.value {
                    Section {
                        Text(verbatim: HexCoding.string(value)).font(.callout.monospaced())
                        if let reading = template.decode(value) {
                            ForEach(reading.fields, id: \.name) { field in
                                LabeledContent {
                                    Text(verbatim: Format.value(field.value))
                                        .font(.callout.monospacedDigit())
                                } label: {
                                    Text(verbatim: field.name)
                                }
                            }
                        } else {
                            Text("Mit diesen Angaben ergibt sich noch kein Wert.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Aktueller Wert")
                    }
                } else {
                    Section {
                        Text("Erst lesen oder abonnieren, damit ein Wert da ist, an dem sich die Felder prüfen lassen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach($entries) { $entry in
                    Section {
                        TextField("Name", text: $entry.field.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("Typ", selection: $entry.field.type) {
                            ForEach(GATTTemplate.RawType.allCases, id: \.self) { type in
                                Text(verbatim: type.rawValue).tag(type)
                            }
                        }
                        Stepper(value: $entry.field.offset, in: 0...240) {
                            LabeledContent("Byte ab") { Text(verbatim: "\(entry.field.offset)") }
                        }
                        Toggle("Big Endian", isOn: $entry.field.bigEndian)
                        LabeledContent("Faktor") { NumberField(value: $entry.field.factor) }
                        LabeledContent("Versatz") { NumberField(value: $entry.field.addend) }
                        TextField("Einheit", text: $entry.field.unit)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { entries.remove(atOffsets: $0) }

                Section {
                    Button {
                        entries.append(Entry(field: GATTTemplate.Field(
                            name: "value\(entries.count + 1)", offset: 0, type: .uint8)))
                    } label: {
                        Label("Feld hinzufügen", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Als Zahlen lesen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        onSave(template)
                        dismiss()
                    }
                    .disabled(entries.isEmpty || entries.contains { $0.field.name.isEmpty })
                }
            }
        }
    }
}
