import SensorstormCore
import SwiftUI

/// Builds a message from entries and writes it to a tag.
struct NFCWriteView: View {
    let model: NFCModel
    @State private var records: [NDEFRecord]
    @State private var editing: NFCDraft?
    @State private var savesAs = false
    @State private var name = ""

    init(model: NFCModel, message: NDEFMessage? = nil) {
        self.model = model
        _records = State(initialValue: message?.records.filter { $0.format != .empty } ?? [])
    }

    private var message: NDEFMessage { NDEFMessage(records: records) }

    var body: some View {
        List {
            Section {
                if records.isEmpty {
                    Text("Noch kein Eintrag. Ein Tag kann mehrere tragen, zum Beispiel eine Adresse und einen Text.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                    NFCRecordRow(record: record)
                }
                .onDelete { records.remove(atOffsets: $0) }
                .onMove { records.move(fromOffsets: $0, toOffset: $1) }
                Menu {
                    ForEach(NFCDraft.Kind.allCases) { kind in
                        Button {
                            editing = NFCDraft(kind: kind)
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Eintrag hinzufügen", systemImage: "plus.circle")
                }
            } header: {
                Text("Inhalt")
            } footer: {
                if !records.isEmpty {
                    Text("\(message.byteCount) Byte. Ein NTAG213 fasst 144, ein NTAG215 504 und ein NTAG216 888 Byte.")
                }
            }

            Section {
                Button {
                    model.write(message)
                } label: {
                    if model.job == .writing {
                        ProgressView()
                    } else {
                        Label("Auf Tag schreiben", systemImage: "wave.3.right.circle.fill")
                    }
                }
                .disabled(records.isEmpty || model.isBusy || !model.isAvailable)
                Button {
                    name = NFCRecordSummary.name(message)
                    savesAs = true
                } label: {
                    Label("In der Bibliothek sichern", systemImage: "tray.and.arrow.down")
                }
                .disabled(records.isEmpty)
            } footer: {
                Text("Das Schreiben ersetzt, was auf dem Tag steht. Danach liest die App den Tag zurück und prüft den Inhalt.")
            }

            if let failure = model.failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if let notice = model.notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Schreiben")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { draft in
            NFCDraftEditor(draft: draft) { finished in
                if let record = finished.record() { records.append(record) }
            }
        }
        .alert("Name", isPresented: $savesAs) {
            TextField("Name", text: $name)
            Button("Sichern") { model.library.add(name: name.isEmpty ? NFCRecordSummary.name(message) : name, message: message) }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}

/// The form for one entry.
struct NFCDraftEditor: View {
    @State var draft: NFCDraft
    let onSave: (NFCDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Art", selection: $draft.kind) {
                        ForEach(NFCDraft.Kind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                }
                fields
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Eintrag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(!draft.isComplete)
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .url:
            Section {
                TextField("https://example.com", text: $draft.url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } footer: {
                Text("Ohne Schema wird https:// ergänzt. Jeder Tag öffnet die Adresse beim Antippen mit dem Handy.")
            }
        case .text:
            Section {
                TextField("Text", text: $draft.text, axis: .vertical)
                TextField("Sprache", text: $draft.language)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("Die Sprache als Kürzel, zum Beispiel de oder en-GB.")
            }
        case .phone:
            Section {
                TextField("Telefonnummer", text: $draft.phone).keyboardType(.phonePad)
            }
        case .mail:
            Section {
                TextField("Adresse", text: $draft.mailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                TextField("Betreff", text: $draft.mailSubject)
                TextField("Nachricht", text: $draft.mailBody, axis: .vertical)
            }
        case .sms:
            Section {
                TextField("Telefonnummer", text: $draft.phone).keyboardType(.phonePad)
                TextField("Nachricht", text: $draft.smsBody, axis: .vertical)
            }
        case .location:
            Section {
                TextField("Breite, zum Beispiel 47.3769", text: $draft.latitude).keyboardType(.numbersAndPunctuation)
                TextField("Länge, zum Beispiel 8.5417", text: $draft.longitude).keyboardType(.numbersAndPunctuation)
            }
        case .wifi:
            Section {
                TextField("Netzwerkname (SSID)", text: $draft.wifiSSID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Verschlüsselung", selection: $draft.wifiSecurity) {
                    ForEach(WiFiCredential.Security.allCases, id: \.self) { security in
                        Text(security.title).tag(security)
                    }
                }
                if draft.wifiSecurity != .open {
                    TextField("Passwort", text: $draft.wifiPassword)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text("Android verbindet sich beim Antippen mit dem Netz. iPhones lesen den Eintrag, treten dem Netz aber nicht von selbst bei.")
            }
        case .contact:
            Section {
                TextField("Vorname", text: $draft.contact.firstName)
                TextField("Nachname", text: $draft.contact.lastName)
                TextField("Firma", text: $draft.contact.organization)
                TextField("Funktion", text: $draft.contact.title)
            }
            Section {
                TextField("Telefon", text: $draft.contact.phone).keyboardType(.phonePad)
                TextField("E-Mail", text: $draft.contact.email)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                TextField("Webseite", text: $draft.contact.website)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Adresse", text: $draft.contact.address, axis: .vertical)
            }
        case .bluetooth:
            Section {
                TextField("Adresse, zum Beispiel AA:BB:CC:11:22:33", text: $draft.bluetoothAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Gerätename", text: $draft.bluetoothName)
                Toggle("Bluetooth Low Energy", isOn: $draft.bluetoothLowEnergy)
            } footer: {
                Text("Ein Telefon oder Lautsprecher, der den Eintrag liest, findet das Gerät über diese Adresse und koppelt sich.")
            }
        case .custom:
            Section {
                TextField("Typ, zum Beispiel application/x-demo", text: $draft.mimeType)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Daten als Hex", isOn: $draft.customIsHex)
                TextField(draft.customIsHex ? "Bytes, zum Beispiel 0A FF" : "Inhalt",
                          text: $draft.customPayload, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
    }
}

/// The messages that were saved, to look at, change and write again.
struct NFCLibraryView: View {
    let model: NFCModel
    @State private var renaming: SavedTag?
    @State private var newName = ""

    var body: some View {
        List {
            if model.library.items.isEmpty {
                Section {
                    Text("Noch nichts gesichert. Gelesene Tags und selbst gebaute Nachrichten lassen sich hier ablegen und später auf neue Tags schreiben.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.library.items) { item in
                NavigationLink {
                    NFCWriteView(model: model, message: item.parsed)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.name).font(.body.weight(.semibold))
                        Text(verbatim: item.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { model.library.delete(item) } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                    Button {
                        newName = item.name
                        renaming = item
                    } label: {
                        Label("Umbenennen", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    if let message = item.parsed {
                        Button {
                            model.write(message)
                        } label: {
                            Label("Auf Tag schreiben", systemImage: "wave.3.right.circle")
                        }
                        .disabled(model.isBusy || !model.isAvailable)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Bibliothek")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Sichern") {
                if let renaming { model.library.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
    }
}
