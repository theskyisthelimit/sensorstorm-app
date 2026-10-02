import SensorstormCore
import SwiftUI

/// The rules, and a console of what they did during the current recording.
struct RulesView: View {
    @Environment(SensorHub.self) private var hub
    @State private var editing: Rule?

    var body: some View {
        @Bindable var hub = hub

        Form {
            Section {
                if hub.ruleLog.isEmpty {
                    Text("Noch nichts ausgelöst. Regeln laufen nur während einer Aufnahme.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hub.ruleLog) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: entry.symbol)
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.title)
                                if !entry.detail.isEmpty {
                                    Text(verbatim: entry.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Konsole")
            }

            Section {
                ForEach($hub.rules) { $rule in
                    HStack {
                        Button {
                            editing = rule
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: rule.name.isEmpty ? "—" : rule.name)
                                    .foregroundStyle(.primary)
                                Text(rule.mode == .onChange ? "Bei Änderung" : "Jedes Mal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle(isOn: $rule.isEnabled) { EmptyView() }
                            .labelsHidden()
                    }
                }
                .onDelete { hub.rules.remove(atOffsets: $0) }

                Button {
                    editing = Rule(name: String(localized: "Neue Regel"))
                } label: {
                    Label("Regel hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Regeln")
            } footer: {
                Text("„Bei Änderung“ löst aus, sobald alle Bedingungen zutreffen, und danach erst wieder, wenn sie zwischendurch nicht mehr zutrafen – frühestens nach 5 Sekunden. „Jedes Mal“ löst aus, solange sie zutreffen, höchstens einmal pro Minute. Beides gilt je Regel.")
            }
        }
        .navigationTitle("Regeln")
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { rule in
            RuleEditorView(rule: rule) { saved in
                if let index = hub.rules.firstIndex(where: { $0.id == saved.id }) {
                    hub.rules[index] = saved
                } else {
                    hub.rules.append(saved)
                }
            }
        }
    }
}

/// One rule. Edits a copy and hands it back on „Sichern", so cancelling leaves no trace.
struct RuleEditorView: View {
    @State var rule: Rule
    let onSave: (Rule) -> Void

    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Picker("Auslösen", selection: $rule.mode) {
                        Text("Bei Änderung").tag(Rule.Mode.onChange)
                        Text("Jedes Mal").tag(Rule.Mode.everyTime)
                    }
                }

                Section {
                    ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                        ConditionEditor(condition: element($rule.conditions, index, condition))
                    }
                    .onDelete { rule.conditions.remove(atOffsets: $0) }

                    Menu {
                        Button("Messwert") {
                            rule.conditions.append(.value(sensor: .location, channel: 4,
                                                          comparison: .above, threshold: 0))
                        }
                        Button("Ort") {
                            let fix = hub.live[.location]?.values
                            rule.conditions.append(.geofence(latitude: fix?.first ?? 0,
                                                             longitude: fix.map { $0[1] } ?? 0,
                                                             radius: 100, inside: true))
                        }
                        Button("Dauer der Aufnahme") { rule.conditions.append(.elapsed(seconds: 60)) }
                        Button("MQTT-Nachricht") { rule.conditions.append(.mqtt(topic: "#", contains: "")) }
                        Button("Fremdgerät") {
                            rule.conditions.append(.external(stream: hub.externalLive.first?.id ?? "",
                                                             channel: 0, comparison: .above,
                                                             threshold: 0))
                        }
                    } label: {
                        Label("Bedingung hinzufügen", systemImage: "plus")
                    }
                } header: {
                    Text("Wenn alle zutreffen")
                }

                Section {
                    ForEach(Array(rule.actions.enumerated()), id: \.offset) { index, action in
                        ActionEditor(action: element($rule.actions, index, action))
                    }
                    .onDelete { rule.actions.remove(atOffsets: $0) }

                    Menu {
                        Button("Benachrichtigung") {
                            rule.actions.append(.notify(title: rule.name, message: "", emoji: "🔔"))
                        }
                        Button("Markierung setzen") { rule.actions.append(.annotate(text: rule.name)) }
                        Button("Aufnahme beenden") { rule.actions.append(.stopRecording) }
                    } label: {
                        Label("Aktion hinzufügen", systemImage: "plus")
                    }
                } header: {
                    Text("Dann")
                }
            }
            .navigationTitle(rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        onSave(rule)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// A binding into an array that survives the row being deleted under it. SwiftUI still
/// renders a deleted row once more during the animation, and a plain `$array[index]` then
/// reads past the end.
private func element<T>(_ array: Binding<[T]>, _ index: Int, _ fallback: T) -> Binding<T> {
    Binding(get: { array.wrappedValue.indices.contains(index) ? array.wrappedValue[index] : fallback },
            set: { if array.wrappedValue.indices.contains(index) { array.wrappedValue[index] = $0 } })
}

private struct ConditionEditor: View {
    @Binding var condition: Rule.Condition
    @Environment(SensorHub.self) private var hub

    /// The streams to pick from: what is live right now, plus the one the rule already names
    /// — a rule written yesterday for a thermometer that is out of range today must still
    /// show what it is waiting for.
    private func externalOptions(including id: String) -> [ExternalStreamInfo] {
        var options = hub.externalLive.map(\.info)
        if !id.isEmpty, !options.contains(where: { $0.id == id }) {
            options.append(ExternalStreamInfo(id: id, source: .accessory, title: id, channels: []))
        }
        return options
    }

    var body: some View {
        switch condition {
        case let .value(sensor, channel, comparison, threshold):
            VStack(alignment: .leading) {
                Picker("Sensor", selection: Binding(
                    get: { sensor },
                    set: { condition = .value(sensor: $0, channel: 0, comparison: comparison, threshold: threshold) })) {
                    ForEach(SensorID.allCases.filter { !SensorID.engineControlled.contains($0) }) { id in
                        Text(id.title).tag(id)
                    }
                }
                Picker("Kanal", selection: Binding(
                    get: { channel },
                    set: { condition = .value(sensor: sensor, channel: $0, comparison: comparison, threshold: threshold) })) {
                    ForEach(Array(sensor.descriptor.channels.enumerated()), id: \.offset) { index, name in
                        Text(verbatim: unitLabel(name, sensor.descriptor.unit(forChannel: index))).tag(index)
                    }
                }
                HStack {
                    Picker("Vergleich", selection: Binding(
                        get: { comparison },
                        set: { condition = .value(sensor: sensor, channel: channel, comparison: $0, threshold: threshold) })) {
                        Text(verbatim: ">").tag(Rule.Comparison.above)
                        Text(verbatim: "<").tag(Rule.Comparison.below)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 120)
                    NumberField(value: Binding(
                        get: { threshold },
                        set: { condition = .value(sensor: sensor, channel: channel, comparison: comparison, threshold: $0) }))
                }
            }

        case let .geofence(latitude, longitude, radius, inside):
            VStack(alignment: .leading) {
                Picker("Ort", selection: Binding(
                    get: { inside },
                    set: { condition = .geofence(latitude: latitude, longitude: longitude, radius: radius, inside: $0) })) {
                    Text("Innerhalb").tag(true)
                    Text("Ausserhalb").tag(false)
                }
                .pickerStyle(.segmented)
                LabeledContent("Breite") {
                    NumberField(value: Binding(
                        get: { latitude },
                        set: { condition = .geofence(latitude: $0, longitude: longitude, radius: radius, inside: inside) }))
                }
                LabeledContent("Länge") {
                    NumberField(value: Binding(
                        get: { longitude },
                        set: { condition = .geofence(latitude: latitude, longitude: $0, radius: radius, inside: inside) }))
                }
                LabeledContent("Radius (m)") {
                    NumberField(value: Binding(
                        get: { radius },
                        set: { condition = .geofence(latitude: latitude, longitude: longitude, radius: $0, inside: inside) }))
                }
            }

        case .elapsed(let seconds):
            LabeledContent("Nach Sekunden") {
                NumberField(value: Binding(get: { seconds }, set: { condition = .elapsed(seconds: $0) }))
            }

        case let .external(stream, channel, comparison, threshold):
            let options = externalOptions(including: stream)
            let info = options.first { $0.id == stream }
            VStack(alignment: .leading) {
                Picker("Gerät", selection: Binding(
                    get: { stream },
                    set: { condition = .external(stream: $0, channel: 0, comparison: comparison, threshold: threshold) })) {
                    ForEach(options) { option in
                        Text(verbatim: option.title).tag(option.id)
                    }
                }
                Picker("Kanal", selection: Binding(
                    get: { channel },
                    set: { condition = .external(stream: stream, channel: $0, comparison: comparison, threshold: threshold) })) {
                    ForEach(Array((info?.channels ?? []).enumerated()), id: \.offset) { index, name in
                        Text(verbatim: unitLabel(name, info?.unit(forChannel: index) ?? "")).tag(index)
                    }
                }
                HStack {
                    Picker("Vergleich", selection: Binding(
                        get: { comparison },
                        set: { condition = .external(stream: stream, channel: channel, comparison: $0, threshold: threshold) })) {
                        Text(verbatim: ">").tag(Rule.Comparison.above)
                        Text(verbatim: "<").tag(Rule.Comparison.below)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 120)
                    NumberField(value: Binding(
                        get: { threshold },
                        set: { condition = .external(stream: stream, channel: channel, comparison: comparison, threshold: $0) }))
                }
            }

        case let .mqtt(topic, contains):
            VStack(alignment: .leading) {
                TextField("Thema, z. B. befehle/#", text: Binding(
                    get: { topic }, set: { condition = .mqtt(topic: $0, contains: contains) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                TextField("Enthält (leer = jede Nachricht)", text: Binding(
                    get: { contains }, set: { condition = .mqtt(topic: topic, contains: $0) }))
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private func unitLabel(_ name: String, _ unit: String) -> String {
        unit.isEmpty ? name : "\(name) (\(unit))"
    }
}

private struct ActionEditor: View {
    @Binding var action: Rule.Action

    var body: some View {
        switch action {
        case let .notify(title, message, emoji):
            VStack(alignment: .leading) {
                HStack {
                    TextField(text: Binding(get: { emoji }, set: { action = .notify(title: title, message: message, emoji: String($0.prefix(4))) })) {
                        Text(verbatim: "🔔")
                    }
                    .frame(width: 44)
                    TextField("Titel", text: Binding(
                        get: { title }, set: { action = .notify(title: $0, message: message, emoji: emoji) }))
                        .font(.headline)
                }
                TextField("Nachricht", text: Binding(
                    get: { message }, set: { action = .notify(title: title, message: $0, emoji: emoji) }),
                          axis: .vertical)
            }
        case .annotate(let text):
            HStack {
                Image(systemName: "flag")
                TextField("Markierung", text: Binding(get: { text }, set: { action = .annotate(text: $0) }))
            }
        case .stopRecording:
            Label("Aufnahme beenden", systemImage: "stop.circle")
        }
    }
}

/// A decimal number as text, without fighting the user mid-typing: the text is kept as
/// typed and the value only follows when it parses.
struct NumberField: View {
    @Binding var value: Double
    @State private var text = ""

    var body: some View {
        TextField(text: $text) { Text(verbatim: "0") }
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospacedDigit())
            .onAppear {
                text = value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)
            }
            .onChange(of: text) { _, new in
                if let parsed = Double(new.replacingOccurrences(of: ",", with: ".")) { value = parsed }
            }
    }
}
