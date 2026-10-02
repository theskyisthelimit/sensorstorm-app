import AudioToolbox
import Charts
import SensorstormCore
import SwiftUI
import UIKit

/// What the scanner screen reads from the Bluetooth source: the device table twice a second,
/// filtered and sorted the way the person asked.
@MainActor
@Observable
final class BluetoothScannerModel {
    enum Sort: String, CaseIterable, Identifiable {
        case signal, name, lastSeen, company
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .signal: "Signalstärke"
            case .name: "Name"
            case .lastSeen: "Zuletzt gesehen"
            case .company: "Hersteller"
            }
        }
    }

    private(set) var devices: [ScannedDevice] = []
    private(set) var availability: BluetoothAvailability = .unknown
    var search = ""
    var sort: Sort = .signal
    var onlyConnectable = false
    var onlyWithData = false
    var onlyFavourites = false

    private let source: BluetoothSource
    private var task: Task<Void, Never>?

    init(source: BluetoothSource) {
        self.source = source
    }

    var isSupported: Bool { source.isSupported }

    func start() {
        guard task == nil else { return }
        source.acquireScanner()
        refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        source.releaseScanner()
        BluetoothSightingStore.shared.save()
    }

    func clear() {
        source.clearScannedDevices()
        refresh()
    }

    func refresh() {
        devices = source.scannedDevices()
        availability = source.availability
        BluetoothSightingStore.shared.merge(devices)
    }

    func device(_ id: UUID) -> ScannedDevice? {
        devices.first { $0.id == id }
    }

    /// Devices with something to read out of the broadcast: a decoded value or a beacon frame.
    private func hasData(_ device: ScannedDevice) -> Bool {
        device.reading != nil || device.beacon != nil || !device.serviceData.isEmpty
    }

    func visible(settings: RecordingSettings) -> [ScannedDevice] {
        let needle = LabelSuggestions.normalise(search)
        var result = devices.filter { device in
            if onlyConnectable, device.isConnectable != true { return false }
            if onlyWithData, !hasData(device) { return false }
            if onlyFavourites, !settings.isFavourite(device.id) { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [settings.alias(for: device.id), device.name, device.company?.name,
                            device.id.uuidString] + device.serviceNames.map { Optional($0) }
            return haystack.contains { $0.map { LabelSuggestions.normalise($0).contains(needle) } ?? false }
        }
        switch sort {
        case .signal: result.sort { $0.rssi > $1.rssi }
        case .name:
            result.sort {
                let (a, b) = (settings.alias(for: $0.id) ?? $0.name ?? "~", settings.alias(for: $1.id) ?? $1.name ?? "~")
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        case .lastSeen: result.sort { $0.lastSeen > $1.lastSeen }
        case .company: result.sort { ($0.company?.name ?? "~") < ($1.company?.name ?? "~") }
        }
        // Pinned devices first, whatever the order.
        return result.filter { settings.isFavourite($0.id) } + result.filter { !settings.isFavourite($0.id) }
    }
}

struct BluetoothScannerView: View {
    @Environment(SensorHub.self) private var hub
    @State private var model: BluetoothScannerModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Bluetooth-Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = BluetoothScannerModel(source: hub.bluetoothSource) }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }

    @ViewBuilder
    private func content(_ model: BluetoothScannerModel) -> some View {
        @Bindable var model = model
        let shown = model.visible(settings: hub.settings)

        List {
            if let notice = unavailableNotice(model) {
                Section { notice }
            }
            Section {
                ForEach(shown) { device in
                    NavigationLink {
                        BluetoothDeviceView(deviceID: device.id, model: model)
                    } label: {
                        BluetoothDeviceRow(device: device, alias: hub.settings.alias(for: device.id),
                                           isFavourite: hub.settings.isFavourite(device.id))
                    }
                }
            } header: {
                Text("\(shown.count) von \(model.devices.count) Geräten")
            } footer: {
                if model.devices.isEmpty {
                    Text("Noch nichts gehört. Telefone, Uhren und Kopfhörer wechseln ihre Adresse alle paar Minuten; mehrere Einträge können deshalb dasselbe Gerät sein.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $model.search, prompt: Text("Name, Hersteller, Dienst"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BluetoothLogView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityLabel(Text("Verlauf der Funde"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sortieren", selection: $model.sort) {
                        ForEach(BluetoothScannerModel.Sort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    Section("Filter") {
                        Toggle("Nur verbindbare", isOn: $model.onlyConnectable)
                        Toggle("Nur mit Daten", isOn: $model.onlyWithData)
                        Toggle("Nur Favoriten", isOn: $model.onlyFavourites)
                    }
                    Button(role: .destructive) {
                        model.clear()
                    } label: {
                        Label("Liste leeren", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private func unavailableNotice(_ model: BluetoothScannerModel) -> AnyView? {
        switch model.availability {
        case .poweredOn, .unknown:
            return model.isSupported ? nil : AnyView(
                Text("Auf diesem Gerät gibt es kein Bluetooth. Im Simulator lässt sich der Scanner nicht prüfen.")
                    .font(.callout))
        case .poweredOff:
            return AnyView(Text("Bluetooth ist ausgeschaltet. Im Kontrollzentrum einschalten.").font(.callout))
        case .unauthorized:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Text("Sensorstorm darf Bluetooth nicht benutzen.").font(.callout)
                Button("Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            })
        case .unsupported:
            return AnyView(Text("Dieses Gerät unterstützt Bluetooth Low Energy nicht.").font(.callout))
        case .resetting:
            return AnyView(Text("Bluetooth startet neu …").font(.callout))
        }
    }
}

/// How strong a signal is, as a colour. The thresholds are rules of thumb: indoors −60 dBm is
/// the same room, −75 the next one, below that the device is at the edge of being heard.
enum SignalQuality {
    static func color(_ rssi: Double) -> Color {
        switch rssi {
        case (-60)...: Color(red: 0.40, green: 0.85, blue: 0.51)
        case (-75)...: Color(red: 0.96, green: 0.74, blue: 0.32)
        default: Color(red: 0.95, green: 0.36, blue: 0.36)
        }
    }

    /// 0…4 bars.
    static func bars(_ rssi: Double) -> Int {
        switch rssi {
        case (-55)...: 4
        case (-67)...: 3
        case (-78)...: 2
        case (-90)...: 1
        default: 0
        }
    }

    /// „≈ 2–5 m" — the span, because a single number would claim more than a radio signal
    /// can say.
    static func rangeText(_ range: (near: Double, far: Double)) -> String {
        guard range.near.isFinite, range.far.isFinite else { return "—" }
        if range.far < 1 { return "< 1 m" }
        if range.near > 50 { return "> 50 m" }
        func round(_ value: Double) -> String {
            value < 10 ? String(format: "%.0f", value.rounded()) : String(format: "%.0f", (value / 5).rounded() * 5)
        }
        let (near, far) = (round(max(range.near, 0.5)), round(range.far))
        return near == far ? "≈ \(near) m" : "≈ \(near)–\(far) m"
    }
}

struct SignalBars: View {
    let rssi: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < SignalQuality.bars(rssi) ? SignalQuality.color(rssi) : Theme.cardBorder)
                    .frame(width: 4, height: CGFloat(5 + index * 3))
            }
        }
        .accessibilityHidden(true)
    }
}

struct BluetoothDeviceRow: View {
    let device: ScannedDevice
    let alias: String?
    let isFavourite: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isFavourite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(verbatim: alias ?? device.name ?? String(device.id.uuidString.prefix(8)))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if device.isConnectable == true {
                        Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let line = subtitle {
                    Text(verbatim: line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let beacon = device.beacon {
                    Text(verbatim: "\(beacon.kind) · \(beacon.summary)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                if let reading = device.reading {
                    Text(verbatim: reading.fields.prefix(3).map {
                        "\($0.name) \(Format.value($0.value, unit: BLEUnits.unit(for: $0.name, decoder: reading.decoder)))"
                    }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(Int(device.rssi)) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SignalQuality.color(device.rssi))
                    SignalBars(rssi: device.rssi)
                }
                Text(verbatim: SignalQuality.rangeText(device.distance))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let interval = device.meanInterval, interval > 0 {
                    Text(Format.rate(1 / interval))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let company = device.company {
            parts.append(company.name ?? String(format: "0x%04X", company.id))
        }
        parts.append(contentsOf: device.serviceNames.prefix(2))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - One device

struct BluetoothDeviceView: View {
    let deviceID: UUID
    let model: BluetoothScannerModel

    @Environment(SensorHub.self) private var hub
    @State private var isRenaming = false
    @State private var draftAlias = ""
    @State private var isSearching = false
    @State private var copiedNote: String?

    private var device: ScannedDevice? { model.device(deviceID) }

    var body: some View {
        @Bindable var hub = hub
        Group {
            if let device {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        signalCard(device)
                        if isSearching { SearchCard(deviceID: deviceID, model: model) }
                        identityCard(device)
                        if let reading = device.reading { readingCard(reading) }
                        advertisementCard(device)
                        actionsCard(device)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            } else {
                ContentUnavailableView("Gerät nicht mehr in Reichweite", systemImage: "wave.3.right.circle")
            }
        }
        .navigationTitle(hub.settings.alias(for: deviceID) ?? device?.name ?? "Gerät")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hub.settings.setFavourite(!hub.settings.isFavourite(deviceID), for: deviceID)
                } label: {
                    Image(systemName: hub.settings.isFavourite(deviceID) ? "star.fill" : "star")
                }
                .accessibilityLabel(Text("Favorit"))
            }
        }
        .alert("Umbenennen", isPresented: $isRenaming) {
            TextField("Name", text: $draftAlias)
            Button("Sichern") { hub.settings.setAlias(draftAlias, for: deviceID) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Name gilt nur auf diesem Telefon und für diese Adresse.")
        }
    }

    // MARK: Cards

    private func signalCard(_ device: ScannedDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(Int(device.rssi)) dBm")
                    .font(.system(.title, design: .rounded).monospacedDigit())
                    .foregroundStyle(SignalQuality.color(device.rssi))
                SignalBars(rssi: device.rssi)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: SignalQuality.rangeText(device.distance))
                        .font(.subheadline)
                    Group {
                        // Two branches rather than a ternary: a ternary of literals is a
                        // `String`, and `Text(String)` does not translate.
                        if device.referencePower.isAssumed {
                            Text("geschätzt, Bezugspegel angenommen")
                        } else {
                            Text("geschätzt, Bezugspegel vom Gerät")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            let newest = device.history.last?.time ?? 0
            if device.history.count >= 2 {
                Chart(device.history, id: \.time) { point in
                    LineMark(x: .value("Zeit", point.time - newest),
                             y: .value("Signal", point.rssi))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: -100.0 ... -30.0)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Theme.cardBorder)
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) { Text(Format.seconds(seconds)) }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: [-90.0, -70.0, -50.0]) }
                .frame(height: 140)
            }
            Text("Funk läuft nicht geradlinig durch einen Raum: Körper und Wände verschieben das Signal um zehn Dezibel, und das ist ein Faktor drei in der Entfernung. Deshalb steht hier eine Spanne.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func identityCard(_ device: ScannedDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Name", device.name ?? "—")
                row("Kennung", device.id.uuidString)
                if let company = device.company {
                    row("Hersteller", [company.name, String(format: "0x%04X", company.id)]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                if let power = device.txPower { row("Sendeleistung", "\(Int(power)) dBm") }
                if let connectable = device.isConnectable {
                    row("Verbindbar", connectable ? String(localized: "ja") : String(localized: "nein"))
                }
                row("Pakete", "\(device.count)")
                if let interval = device.meanInterval, interval > 0 {
                    row("Intervall", String(format: "%.0f ms · %@", interval * 1000, Format.rate(1 / interval)))
                }
                row("Beobachtet seit", Format.duration(device.lastSeen - device.firstSeen))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func readingCard(_ reading: BLEReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: reading.decoder)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(reading.fields, id: \.name) { field in
                    GridRow {
                        Text(verbatim: field.name).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: Format.value(field.value, unit: BLEUnits.unit(for: field.name, decoder: reading.decoder)))
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func advertisementCard(_ device: ScannedDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advertisement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let beacon = device.beacon {
                Text(verbatim: "\(beacon.kind) · \(beacon.summary)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            if !device.serviceUUIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(device.serviceUUIDs.enumerated()), id: \.offset) { _, uuid in
                        HStack {
                            Text(verbatim: BluetoothNames.service(uuid) ?? "—").font(.caption)
                            Spacer()
                            Text(verbatim: BluetoothNames.shortForm(uuid))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if let data = device.manufacturerData {
                hexBlock(title: "Herstellerdaten", data: data)
            }
            ForEach(device.serviceData.sorted { $0.key < $1.key }, id: \.key) { uuid, data in
                hexBlock(title: "Dienstdaten \(BluetoothNames.shortForm(uuid))", data: data)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func hexBlock(title: LocalizedStringKey, data: Data) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(verbatim: HexCoding.string(data))
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(verbatim: HexCoding.ascii(data))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private func actionsCard(_ device: ScannedDevice) -> some View {
        VStack(spacing: 0) {
            if device.isConnectable != false {
                NavigationLink {
                    GATTExplorerView(deviceID: deviceID,
                                     deviceName: hub.settings.alias(for: deviceID) ?? device.name ?? "—")
                } label: {
                    actionLabel("Dienste und Merkmale", systemImage: "list.bullet.indent")
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.cardBorder)
            }
            Button {
                isSearching.toggle()
            } label: {
                actionLabel(isSearching ? "Suche beenden" : "Gerät suchen", systemImage: "scope")
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.cardBorder)
            Button {
                draftAlias = hub.settings.alias(for: deviceID) ?? device.name ?? ""
                isRenaming = true
            } label: {
                actionLabel("Umbenennen", systemImage: "pencil")
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.cardBorder)
            Button {
                UIPasteboard.general.string = DecoderTemplate.make(for: device)
                copiedNote = String(localized: "Decoder-Vorlage kopiert")
            } label: {
                actionLabel("Decoder-Vorlage kopieren", systemImage: "curlybraces")
            }
            .buttonStyle(.plain)
            if let copiedNote {
                Text(verbatim: copiedNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 2)
        .card()
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Finding a device by ear

/// Beeps and taps faster the stronger the signal, so a device can be found by walking
/// towards it. The signal moves with the person's own body, which is exactly what makes it
/// work: turning round is the answer to „which way".
struct SearchCard: View {
    let deviceID: UUID
    let model: BluetoothScannerModel

    @State private var task: Task<Void, Never>?
    @State private var playsSound = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suche", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("Ton", isOn: $playsSound)
                    .labelsHidden()
                    .accessibilityLabel(Text("Ton"))
                Image(systemName: playsSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(.secondary)
            }
            Text("Je näher das Gerät, desto schneller das Klopfen. Mit dem Telefon langsam drehen und gehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .card()
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task?.cancel()
        task = Task { @MainActor in
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            while !Task.isCancelled {
                let rssi = model.device(deviceID)?.rssi ?? -100
                // −100 dBm: one tap every 1.5 s. −35 dBm and stronger: twelve a second.
                let fraction = min(max((rssi + 100) / 65, 0), 1)
                let interval = 1.5 - fraction * (1.5 - 0.08)
                haptic.impactOccurred(intensity: 0.4 + 0.6 * fraction)
                if playsSound { AudioServicesPlaySystemSound(1104) }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}
