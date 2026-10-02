import SensorstormCore
import SwiftUI
import UIKit

/// Read, write, copy, erase and lock NFC tags, and keep what was written in a library.
struct NFCToolView: View {
    @State private var model = NFCModel()
    @State private var confirmsErase = false
    @State private var confirmsLock = false

    var body: some View {
        List {
            if !model.isAvailable {
                Section {
                    Label("Dieses Gerät hat kein NFC.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            actions
            outcome
            if let info = model.info {
                tagSection(info)
                if let message = info.message {
                    recordsSection(message)
                    rawSection(message)
                }
                if let memory = info.memory { memorySection(memory) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("NFC")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Tag löschen?", isPresented: $confirmsErase, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { model.erase() }
        } message: {
            Text("Der Inhalt des Tags wird durch einen leeren Eintrag ersetzt. Das lässt sich nicht rückgängig machen.")
        }
        .confirmationDialog("Dauerhaft schreibschützen?", isPresented: $confirmsLock, titleVisibility: .visible) {
            Button("Für immer schreibschützen", role: .destructive) { model.lock() }
        } message: {
            Text("Danach kann niemand diesen Tag mehr beschreiben oder löschen, auch nicht mit diesem Gerät. Es gibt keinen Weg zurück.")
        }
    }

    // MARK: Actions

    private var actions: some View {
        Section {
            Button {
                model.read()
            } label: {
                Label("Tag lesen", systemImage: "wave.3.right.circle")
            }
            NavigationLink {
                NFCWriteView(model: model)
            } label: {
                Label("Schreiben", systemImage: "square.and.pencil")
            }
            if let source = model.cloneSource {
                Button {
                    model.finishClone()
                } label: {
                    Label("Auf den Ziel-Tag schreiben", systemImage: "doc.on.doc.fill")
                }
                Text("Gelesen: \(source.records.count) Einträge, \(source.byteCount) Byte.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Kopieren abbrechen", role: .cancel) { model.cancelClone() }
            } else {
                Button {
                    model.startClone()
                } label: {
                    Label("Tag kopieren", systemImage: "doc.on.doc")
                }
            }
            Button(role: .destructive) {
                confirmsErase = true
            } label: {
                Label("Tag löschen", systemImage: "trash")
            }
            Button(role: .destructive) {
                confirmsLock = true
            } label: {
                Label("Schreibschutz setzen", systemImage: "lock")
            }
            NavigationLink {
                NFCLibraryView(model: model)
            } label: {
                Label("Bibliothek", systemImage: "books.vertical")
                    .badge(model.library.items.count)
            }
        } footer: {
            Text("iOS liest und beschreibt Tags im NDEF-Format. Karten mit eigener Verschlüsselung, etwa Zutritts- oder Bezahlkarten, gibt iOS nicht heraus; von ihnen erscheinen Art und Seriennummer. Die Seriennummer lässt sich weder ändern noch kopieren, kopiert wird der Inhalt.")
        }
        .disabled(!model.isAvailable || model.isBusy)
    }

    @ViewBuilder
    private var outcome: some View {
        if let failure = model.failure {
            Section {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        if let notice = model.notice {
            Section {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    // MARK: Result

    @ViewBuilder
    private func tagSection(_ info: NFCTagInfo) -> some View {
        Section("Tag") {
            LabeledContent("Art") { Text(info.technology.title).multilineTextAlignment(.trailing) }
            if let chip = info.chipModel {
                LabeledContent("Chip") { Text(verbatim: chip).multilineTextAlignment(.trailing) }
            }
            if let manufacturer = info.manufacturer {
                LabeledContent("Hersteller") { Text(verbatim: manufacturer) }
            }
            LabeledContent("Seriennummer") {
                Text(verbatim: info.serialHex).font(.footnote.monospaced()).textSelection(.enabled)
            }
            if info.usesRandomID {
                Label("Zufällige Kennung, sie ändert sich bei jedem Kontakt.", systemImage: "dice")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let code = info.systemCode {
                LabeledContent("Systemcode") { Text(verbatim: HexCoding.string(code, separator: "")).font(.footnote.monospaced()) }
            }
            if let bytes = info.historicalBytes, !bytes.isEmpty {
                LabeledContent("Historische Bytes") { Text(verbatim: HexCoding.string(bytes)).font(.footnote.monospaced()) }
            }
            if let data = info.applicationData, !data.isEmpty {
                LabeledContent("Anwendungsdaten") { Text(verbatim: HexCoding.string(data)).font(.footnote.monospaced()) }
            }
            if let status = info.ndefStatus {
                LabeledContent("NDEF") { Text(status.title) }
            }
            if let capacity = info.ndefCapacity, capacity > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    let used = info.usedBytes ?? 0
                    ProgressView(value: min(Double(used), Double(capacity)), total: Double(capacity))
                    Text("\(used) von \(capacity) Byte belegt")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func recordsSection(_ message: NDEFMessage) -> some View {
        Section {
            if message.isBlank {
                Text("Der Tag ist leer.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(message.records.enumerated()), id: \.offset) { _, record in
                    NFCRecordRow(record: record)
                }
            }
        } header: {
            Text("Inhalt")
        } footer: {
            if !message.isBlank, let serial = model.info?.serialHex {
                Button {
                    model.library.add(name: NFCRecordSummary.name(message), message: message, serial: serial)
                } label: {
                    Label("In der Bibliothek sichern", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func rawSection(_ message: NDEFMessage) -> some View {
        if !message.isBlank {
            Section("Rohdaten") {
                Text(verbatim: HexCoding.dump(message.serialized()))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func memorySection(_ memory: Data) -> some View {
        Section {
            Text(verbatim: HexCoding.dump(memory))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("Speicher")
        } footer: {
            Text("Der ganze Speicher des Chips, vier Byte je Seite. Seite 3 enthält die Größe, ab Seite 4 steht der Inhalt. Geschützte Bereiche fehlen.")
        }
    }
}

/// The name a saved message gets when nobody names it: what its first meaningful record says.
enum NFCRecordSummary {
    static func name(_ message: NDEFMessage) -> String {
        for record in message.records {
            let text = NDEFContent(record).summary
            if !text.isEmpty { return String(text.prefix(40)) }
        }
        return String(localized: "Ohne Namen")
    }
}

/// One record: what it is, what it says, and — where the phone can — a way to open it.
struct NFCRecordRow: View {
    let record: NDEFRecord

    var body: some View {
        let content = NDEFContent(record)
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(content.title).font(.footnote).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: content.symbol).foregroundStyle(Theme.accent)
            }
            detail(content)
            Text(verbatim: technical).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = content.summary
            } label: {
                Label("Kopieren", systemImage: "doc.on.doc")
            }
            .disabled(content.summary.isEmpty)
        }
    }

    @ViewBuilder
    private func detail(_ content: NDEFContent) -> some View {
        switch content {
        case .wifi(let credential):
            Text(verbatim: credential.ssid).font(.body.weight(.semibold))
            HStack {
                Text(credential.security.title)
                if !credential.password.isEmpty {
                    Text(verbatim: credential.password).monospaced().textSelection(.enabled)
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
        case .contact(let card):
            Text(verbatim: card.displayName).font(.body.weight(.semibold))
            ForEach([card.organization, card.title, card.phone, card.email, card.website, card.address]
                .filter { !$0.isEmpty }, id: \.self) { line in
                Text(verbatim: line).font(.footnote).foregroundStyle(.secondary)
            }
        case .bluetooth(let address, let name, let lowEnergy):
            if let name { Text(verbatim: name).font(.body.weight(.semibold)) }
            if let address { Text(verbatim: address).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            Text(verbatim: lowEnergy ? "Bluetooth Low Energy" : "Bluetooth Classic")
                .font(.footnote).foregroundStyle(.secondary)
        case .mime(let type, let count), .external(let type, let count):
            Text(verbatim: type).font(.body.monospaced())
            Text("\(count) Byte").font(.footnote).foregroundStyle(.secondary)
        case .unknown(let count):
            Text("\(count) Byte").font(.footnote).foregroundStyle(.secondary)
        case .empty:
            EmptyView()
        default:
            Text(verbatim: content.summary).textSelection(.enabled)
            if let url = content.openURL {
                Link(destination: url) {
                    Label("Öffnen", systemImage: "arrow.up.forward.app").font(.footnote)
                }
            }
        }
    }

    /// `TNF 1 · U · 12 Byte`, for the person who needs to see what is really on the tag.
    private var technical: String {
        let type = record.type.isEmpty ? "" : " · " + record.typeString
        return "TNF \(record.format.rawValue)\(type) · \(record.payload.count) B"
    }
}
