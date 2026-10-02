import SensorstormCore
import SwiftUI

/// The sightings the scanner keeps between sessions, when the person turns that on. Stored as
/// one JSON file in Application Support and never sent anywhere.
@MainActor @Observable
final class BluetoothSightingStore {
    static let shared = BluetoothSightingStore()

    private(set) var log = SightingLog()
    private let url: URL
    private var lastSave = Date.distantPast
    private static let defaultsKey = "bluetooth.keepsSightings"

    var isRecording: Bool {
        didSet { UserDefaults.standard.set(isRecording, forKey: Self.defaultsKey) }
    }

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Bluetooth", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Bluetooth", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("sightings.json")
        isRecording = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(SightingLog.self, from: data) {
            log = decoded
        }
    }

    /// Folds the scanner's table in, and writes the file at most every ten seconds: the table
    /// arrives twice a second and the file is some hundred kilobytes.
    func merge(_ devices: [ScannedDevice]) {
        guard isRecording, !devices.isEmpty else { return }
        log.merge(devices)
        if Date().timeIntervalSince(lastSave) > 10 { save() }
    }

    func save() {
        lastSave = Date()
        if let data = try? JSONEncoder().encode(log) { try? data.write(to: url, options: .atomic) }
    }

    func remove(_ id: UUID) {
        log.remove(id)
        save()
    }

    func removeAll() {
        log.removeAll()
        save()
    }
}

/// Every device the scanner has heard since logging was switched on, with when and how loud.
struct BluetoothLogView: View {
    @State private var store = BluetoothSightingStore.shared
    @State private var search = ""
    @State private var onlyNamed = false
    @State private var minimumSignal = -100.0
    @State private var confirmsDelete = false

    private var visible: [Sighting] {
        let needle = LabelSuggestions.normalise(search)
        return store.log.entries
            .filter { entry in
                if onlyNamed, entry.name == nil { return false }
                if entry.rssiMax < minimumSignal { return false }
                guard !needle.isEmpty else { return true }
                return ([entry.name, entry.company, entry.id.uuidString] + entry.services.map { Optional($0) })
                    .contains { $0.map { LabelSuggestions.normalise($0).contains(needle) } ?? false }
            }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        List {
            Section {
                Toggle("Funde mitschreiben", isOn: $store.isRecording)
            } footer: {
                Text("Solange der Scanner offen ist, merkt sich die App jedes gehörte Gerät mit der Zeit des ersten und des letzten Pakets und mit der Signalstärke. Die Liste bleibt auf diesem Telefon.")
            }

            Section {
                Toggle("Nur mit Namen", isOn: $onlyNamed)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Mindestens")
                        Spacer()
                        Text(verbatim: "\(Int(minimumSignal)) dBm").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $minimumSignal, in: -100...(-40), step: 5)
                }
            } header: {
                Text("Filter")
            }

            Section {
                if visible.isEmpty {
                    Text(store.log.entries.isEmpty ? "Noch keine Funde." : "Kein Fund passt zum Filter.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { entry in
                    SightingRow(entry: entry)
                        .swipeActions {
                            Button(role: .destructive) { store.remove(entry.id) } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("\(visible.count) von \(store.log.entries.count) Geräten")
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: Text("Name, Hersteller, Dienst"))
        .navigationTitle("Verlauf der Funde")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: store.log.csv()) {
                    Label("Als Tabelle teilen", systemImage: "square.and.arrow.up")
                }
                .disabled(store.log.entries.isEmpty)
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label("Alles löschen", systemImage: "trash")
                }
                .disabled(store.log.entries.isEmpty)
            }
        }
        .confirmationDialog("Alle Funde löschen?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { store.removeAll() }
        }
        .onDisappear { store.save() }
    }
}

struct SightingRow: View {
    let entry: Sighting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: entry.name ?? String(entry.id.uuidString.prefix(8)))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if entry.isConnectable == true {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "\(Int(entry.rssiMin)) bis \(Int(entry.rssiMax)) dBm")
                    .font(.caption.monospacedDigit()).foregroundStyle(SignalQuality.color(entry.rssiMax))
            }
            let detail = ([entry.company] + entry.services.prefix(2).map { Optional($0) }).compactMap { $0 }
            if !detail.isEmpty {
                Text(verbatim: detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Text("Erstmals \(entry.firstSeen.formatted(date: .omitted, time: .standard))")
                Text("Zuletzt \(entry.lastSeen.formatted(date: .omitted, time: .standard))")
                Spacer()
                Text(verbatim: "\(entry.packets) ×").monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
