import Charts
import SensorstormCore
import SwiftUI

/// The catalog's entries as chips under the label field: one tap names the case, sets the
/// usual severity and remembers which entry it was.
struct CatalogEntryChips: View {
    let catalog: FindingCatalog
    @Binding var draft: FindingDraft

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(catalog.entries) { entry in
                    let selected = draft.attributes[FindingCatalog.entryAttribute] == entry.key
                    Button {
                        draft.label = entry.label.resolve(CatalogStore.language)
                        draft.attributes[FindingCatalog.entryAttribute] = entry.key
                        if let severity = entry.defaultSeverity { draft.severity = severity }
                    } label: {
                        Text(verbatim: entry.label.resolve(CatalogStore.language))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Theme.accent : Theme.cardBorder, in: .capsule)
                            .foregroundStyle(selected ? Color.black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The catalog's questions for a case: which entry it is, and the answers.
struct FindingCatalogCard: View {
    @Environment(SurveyModel.self) private var model
    let surveyID: UUID
    let finding: GroundFinding

    var body: some View {
        if let survey = model.survey(surveyID), let catalog = model.catalogs.catalog(survey.catalogID) {
            let language = CatalogStore.language
            let entryKey = finding.attributes[FindingCatalog.entryAttribute]
            VStack(alignment: .leading, spacing: 12) {
                Label { Text(verbatim: catalog.name.resolve(language)) } icon: { Image(systemName: "list.bullet.rectangle") }
                    .font(.subheadline.weight(.semibold))

                Picker("Art", selection: Binding(
                    get: { entryKey ?? "" },
                    set: { select($0, in: catalog) })) {
                    Text("Nicht gewählt").tag("")
                    ForEach(catalog.entries) { entry in
                        Text(verbatim: entry.label.resolve(language)).tag(entry.key)
                    }
                }

                if let entryKey, let entry = catalog.entry(entryKey) {
                    ForEach(entry.attributes) { attribute in
                        field(for: attribute, language: language)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card()
        }
    }

    @ViewBuilder
    private func field(for attribute: AttributeDefinition, language: String) -> some View {
        let value = finding.attributes[attribute.key] ?? ""
        switch attribute.kind {
        case .choice:
            Picker(selection: Binding(get: { value }, set: { set(attribute.key, $0) })) {
                Text("—").tag("")
                ForEach(attribute.choices) { choice in
                    Text(verbatim: choice.title.resolve(language)).tag(choice.key)
                }
            } label: {
                Text(verbatim: attribute.title.resolve(language))
            }
        case .flag:
            Toggle(isOn: Binding(get: { value == "1" }, set: { set(attribute.key, $0 ? "1" : "0") })) {
                Text(verbatim: attribute.title.resolve(language))
            }
        case .number:
            HStack {
                Text(verbatim: attribute.title.resolve(language))
                Spacer()
                TextField("—", text: Binding(get: { value }, set: { set(attribute.key, $0) }))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                if let unit = attribute.unit {
                    Text(verbatim: unit).foregroundStyle(.secondary)
                }
            }
        case .text:
            HStack {
                Text(verbatim: attribute.title.resolve(language))
                Spacer()
                TextField("—", text: Binding(get: { value }, set: { set(attribute.key, $0) }))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func set(_ key: String, _ value: String) {
        var current = finding
        if value.isEmpty { current.attributes[key] = nil } else { current.attributes[key] = value }
        model.update(current, in: surveyID)
    }

    private func select(_ entryKey: String, in catalog: FindingCatalog) {
        var current = finding
        guard current.attributes[FindingCatalog.entryAttribute] != entryKey else { return }
        // A new entry has other questions; the old answers would be answers to a different one.
        current.attributes = [:]
        if entryKey.isEmpty { model.update(current, in: surveyID); return }
        current.attributes[FindingCatalog.entryAttribute] = entryKey
        if let entry = catalog.entry(entryKey) {
            current.label = entry.label.resolve(CatalogStore.language)
            if let severity = entry.defaultSeverity, finding.attributes[FindingCatalog.entryAttribute] == nil {
                current.severity = severity
            }
        }
        model.update(current, in: surveyID)
    }
}

// MARK: - Measurements

struct MeasurementsCard: View {
    @Environment(SurveyModel.self) private var model
    let surveyID: UUID
    let finding: GroundFinding

    @State private var adding: CaseMeasurement.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Messwerte", systemImage: "ruler")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Menu {
                    ForEach([CaseMeasurement.Kind.slope, .depth, .width, .length, .count], id: \.self) { kind in
                        Button { adding = kind } label: { Text(Self.title(kind)) }
                    }
                } label: {
                    Label("Hinzufügen", systemImage: "plus.circle")
                        .font(.footnote)
                }
            }

            if finding.measurements.isEmpty {
                Text("Neigung, Tiefe, Breite, Länge oder Stückzahl. Aus Fläche und Tiefe rechnet die App das Volumen aus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(finding.measurements) { item in
                HStack {
                    Text(Self.title(item.kind)).font(.callout)
                    Spacer()
                    Text(verbatim: Self.value(item)).font(.callout.monospacedDigit())
                    Button(role: .destructive) {
                        var current = finding
                        current.measurements.removeAll { $0.id == item.id }
                        model.update(current, in: surveyID)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Entfernen")
                }
            }
            if let volume = finding.volumeCubicMetres {
                Divider().overlay(Theme.cardBorder)
                HStack {
                    Text("Volumen").font(.callout)
                    Spacer()
                    Text(verbatim: String(format: "%.3f m³", volume)).font(.callout.monospacedDigit())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
        .sheet(item: $adding) { kind in
            if kind == .slope {
                InclinationSheet { value in add(.slope, value) }
            } else {
                NumberEntrySheet(kind: kind) { value in add(kind, value) }
            }
        }
    }

    private func add(_ kind: CaseMeasurement.Kind, _ value: Double) {
        var current = finding
        current.measurements.append(CaseMeasurement(kind: kind, value: value))
        model.update(current, in: surveyID)
    }

    static func title(_ kind: CaseMeasurement.Kind) -> LocalizedStringKey {
        switch kind {
        case .slope: "Neigung"
        case .depth: "Tiefe"
        case .length: "Länge"
        case .width: "Breite"
        case .count: "Stückzahl"
        case .other: "Sonstiges"
        }
    }

    static func value(_ item: CaseMeasurement) -> String {
        switch item.kind {
        case .slope:
            return String(format: "%.1f° (%.1f %%)", item.value, CaseMeasurement.percent(fromDegrees: item.value))
        case .count:
            return String(format: "%.0f", item.value)
        default:
            return String(format: "%.1f %@", item.value, item.unit)
        }
    }
}

/// Reads the slope from the phone's own attitude: lay it on the surface, wait for the number
/// to settle, take it.
struct InclinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var meter = InclinationMeter()
    let onTake: (Double) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let tilt = meter.tilt {
                    Text(verbatim: String(format: "%.1f°", tilt))
                        .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(verbatim: String(format: "%.1f %%", CaseMeasurement.percent(fromDegrees: tilt)))
                        .font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                } else if meter.isAvailable {
                    ProgressView()
                } else {
                    Text("Dieses Gerät hat keinen Bewegungssensor.").foregroundStyle(.secondary)
                }
                Text("Das Telefon flach auf die Fläche legen, mit der Rückseite nach unten. 0° ist waagrecht, 45° sind 100 %. Die Anzeige ist auf etwa ein halbes Grad genau, wenn das Telefon ruht.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    if let tilt = meter.tilt { onTake(tilt) }
                    dismiss()
                } label: {
                    Label("Übernehmen", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(meter.tilt == nil)
            }
            .padding(24)
            .navigationTitle("Neigung messen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }
}

struct NumberEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: CaseMeasurement.Kind
    let onTake: (Double) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Wert", text: $text)
                            .keyboardType(.decimalPad)
                        Text(verbatim: kind.defaultUnit).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(MeasurementsCard.title(kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let value = Double(text.replacingOccurrences(of: ",", with: ".")) { onTake(value) }
                        dismiss()
                    }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}

// MARK: - History

/// How one case stood on every walk of the same street.
struct FindingHistoryCard: View {
    @Environment(SurveyModel.self) private var model
    let finding: GroundFinding

    var body: some View {
        let entries = model.history(of: finding)
        if entries.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                Label("Verlauf", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(entries) { entry in
                        LineMark(x: .value("Zeit", entry.date), y: .value("Wert", Double(entry.severity)))
                            .foregroundStyle(Theme.accent)
                        PointMark(x: .value("Zeit", entry.date), y: .value("Wert", Double(entry.severity)))
                            .foregroundStyle(entry.status.isOutstanding ? Theme.accent : Color.gray)
                    }
                }
                .chartYScale(domain: 0.0...10.0)
                .frame(height: 110)
                ForEach(entries) { entry in
                    HStack {
                        Text(verbatim: entry.surveyName).font(.caption).lineLimit(1)
                        Spacer()
                        Text(entry.date, format: .dateTime.day().month().year())
                            .font(.caption2).foregroundStyle(.secondary)
                        SeverityBadge(severity: entry.severity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card()
        }
    }
}
