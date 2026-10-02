import Charts
import SensorstormCore
import SwiftUI

/// The evaluations of one recording: how clean it is, the track coloured by any stream, the
/// state of a road, an elevator ride, a train ride, the vibration against the limits — and the
/// data as a training set.
struct RecordingAnalysisView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(SurveyModel.self) private var surveys
    @State private var model: RecordingAnalysisModel
    @State private var shareItem: ShareItem?
    @State private var basemap: Basemap = .apple
    @State private var datasetRate = 50.0
    @State private var datasetWindow = 2.0
    @State private var datasetOverlap = 0.5
    @State private var isRenderingReport = false

    enum Basemap: String, CaseIterable, Identifiable {
        case apple, swisstopo
        var id: String { rawValue }
    }

    init(recording: RecordingMetadata, store: RecordingStore) {
        _model = State(initialValue: RecordingAnalysisModel(metadata: recording, store: store))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                qualityCard
                if model.hasLocation { mapCard }
                if model.hasLocation { roadCard }
                if model.metadata.stream(.barometer) != nil { elevatorCard }
                comfortCard
                vibrationCard
                datasetCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Auswertung")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .task {
            if model.hasLocation { await model.runColoring() }
        }
    }

    // MARK: - Quality

    private var qualityCard: some View {
        card(icon: "checkmark.shield", title: "Qualität der Aufnahme") {
            if let quality = model.quality {
                HStack {
                    VerdictChip(verdict: quality.verdict)
                    Spacer()
                    Text("\(Int((quality.goodShare * 100).rounded())) % der Ströme einwandfrei")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let gps = quality.gps {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Position").font(.footnote.weight(.semibold))
                            Spacer()
                            VerdictChip(verdict: gps.verdict, compact: true)
                        }
                        Text(verbatim: String(format: "%d Fixe · Median ±%.1f m · 90 %% besser als ±%.1f m · längster Ausfall %.0f s",
                                              gps.fixCount, gps.medianAccuracy, gps.worstDecile, gps.longestOutage))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(quality.streams.filter { $0.verdict != .good || !$0.notes.isEmpty }) { stream in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: stream.title).font(.footnote.weight(.semibold))
                            Spacer()
                            VerdictChip(verdict: stream.verdict, compact: true)
                        }
                        ForEach(Array(stream.notes.enumerated()), id: \.offset) { _, note in
                            Text(verbatim: Self.sentence(note)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if quality.streams.allSatisfy({ $0.verdict == .good }) {
                    Text("Alle Ströme sind lückenlos, in der verlangten Rate und ohne fehlende Werte.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    renderReport(quality)
                } label: {
                    Label("Bericht als PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.bordered)
                .disabled(isRenderingReport)
            }
            runButton("quality", title: "Prüfen") { await model.runQuality() }
        }
    }

    static func sentence(_ note: QualityNote) -> String {
        switch note {
        case .rateBelowRequested(let measured, let requested):
            return String(localized: "Nur \(String(format: "%.0f", measured)) Hz statt der gewünschten \(String(format: "%.0f", requested)) Hz.")
        case .gaps(let count, let longest):
            return String(localized: "\(count) Lücken, die längste \(String(format: "%.1f", longest)) s.")
        case .missingValues(let share):
            return String(localized: "\(String(format: "%.0f", share * 100)) % der Werte fehlen.")
        case .timeWentBackwards(let count):
            return String(localized: "Die Zeit lief \(count)-mal rückwärts oder stand still.")
        case .frozen(let share):
            return String(localized: "\(String(format: "%.0f", share * 100)) % der Werte sind unverändert — der Sensor hing vermutlich.")
        case .tooShort:
            return String(localized: "Zu wenige Werte für eine Beurteilung.")
        }
    }

    // MARK: - Map

    private var mapCard: some View {
        card(icon: "map", title: "Karte") {
            if model.metrics.isEmpty {
                Text("Keine Ströme zum Einfärben.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Einfärben nach", selection: Binding(get: { model.selectedMetricID },
                                                           set: { model.selectedMetricID = $0; Task { await model.runColoring() } })) {
                    ForEach(model.metrics) { metric in
                        Text(verbatim: metric.title).tag(metric.id)
                    }
                }
                Picker("Karte", selection: $basemap) {
                    Text("Karte").tag(Basemap.apple)
                    Text(verbatim: "swisstopo").tag(Basemap.swisstopo)
                }
                .pickerStyle(.segmented)

                if let coloring = model.coloring, !coloring.isEmpty {
                    OverlayMapView(
                        basemap: basemap == .swisstopo ? .swisstopo(layer: SwisstopoTileOverlay.mapLayer) : .apple,
                        lines: coloring.segments.map {
                            .init(coordinates: [$0.start.clCoordinate, $0.end.clCoordinate],
                                  color: TrackColoring.color(fraction: $0.fraction), width: 5)
                        })
                    .id(basemap)
                    .frame(height: 300)
                    .clipShape(.rect(cornerRadius: 12))
                    legend(coloring, unit: model.selectedMetric?.unit ?? "")
                } else if model.isRunning("coloring") {
                    ProgressView()
                } else {
                    Text("Die Aufnahme hat keine brauchbaren Positionen.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legend(_ coloring: TrackColoring, unit: String) -> some View {
        VStack(spacing: 3) {
            LinearGradient(colors: (0...10).map { Color(TrackColoring.color(fraction: Double($0) / 10)) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 8).clipShape(.capsule)
            HStack {
                Text(verbatim: "\(Format.value(coloring.low)) \(unit)")
                Spacer()
                Text(verbatim: "\(Format.value(coloring.high)) \(unit)")
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Road

    private var roadCard: some View {
        card(icon: "road.lanes", title: "Strassenzustand") {
            if let road = model.road {
                if road.segments.isEmpty {
                    Text("Zu wenig Fahrt zum Beurteilen: es braucht Beschleunigung mit mindestens 20 Hz und eine Geschwindigkeit zwischen 11 und 160 km/h.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    figures([
                        (String(localized: "Beurteilt"), ReportFormat.length(road.distance)),
                        (String(localized: "Abschnitte"), "\(road.segments.count)"),
                        (String(localized: "Schläge"), "\(road.shocks.count)"),
                    ])
                    if let worst = road.worstSegments.max(by: { $0.rms < $1.rms }) {
                        Text("Rauester Abschnitt: \(String(format: "%.2f", worst.rms)) m/s² bei \(String(format: "%.0f", worst.speed * 3.6)) km/h")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(road.shocks.prefix(10).enumerated()), id: \.offset) { _, shock in
                        HStack {
                            Image(systemName: "bolt.fill").foregroundStyle(.orange).accessibilityHidden(true)
                            Text(verbatim: String(format: "%.2f g bei %.0f km/h", shock.peak, shock.speed * 3.6))
                                .font(.caption.monospacedDigit())
                            Spacer()
                            if shock.position != nil, !surveys.surveys.isEmpty {
                                Menu {
                                    ForEach(surveys.surveys) { survey in
                                        Button { addShock(shock, to: survey.id) } label: { Text(verbatim: survey.name) }
                                    }
                                } label: {
                                    Label("Als Beobachtung", systemImage: "mappin.and.ellipse").font(.caption)
                                }
                            }
                        }
                    }
                    Text("Ein Richtwert aus der Vertikalbeschleunigung des Telefons, kein Messwert nach Norm: er hängt vom Fahrzeug und von der Halterung ab. Aussagekräftig ist der Vergleich der Abschnitte einer Fahrt.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            runButton("road", title: "Auswerten") { await model.runRoad() }
        }
    }

    private func addShock(_ shock: RoadRoughness.Shock, to surveyID: UUID) {
        guard let position = shock.position else { return }
        var draft = FindingDraft()
        draft.label = String(localized: "Schlag")
        draft.severity = min(max(Int((shock.peak * 8).rounded()), 3), 9)
        draft.location = FindingLocation(latitude: position.latitude, longitude: position.longitude, horizontalAccuracy: 8)
        draft.positionSource = .gps
        draft.hostTime = shock.time
        draft.recordingID = model.metadata.id
        draft.note = String(localized: "Aus der Aufnahme erkannt: \(String(format: "%.2f", shock.peak)) g.")
        surveys.addFinding(draft, to: surveyID)
    }

    // MARK: - Elevator

    private var elevatorCard: some View {
        card(icon: "arrow.up.arrow.down.square", title: "Aufzugfahrten") {
            if let rides = model.rides {
                if rides.isEmpty {
                    Text("Keine Fahrt gefunden. Das Telefon muss im Aufzug auf dem Boden liegen; gesucht wird eine Höhenänderung ab 1,5 m.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(rides.enumerated()), id: \.offset) { index, ride in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: ride.isUp ? "arrow.up" : "arrow.down").accessibilityHidden(true)
                            Text("Fahrt \(index + 1)").font(.footnote.weight(.semibold))
                            Spacer()
                            Text(verbatim: String(format: "%+.1f m · %.0f s", ride.heightChange, ride.duration))
                                .font(.caption.monospacedDigit())
                        }
                        figures([
                            (String(localized: "Tempo"), String(format: "%.2f m/s", ride.peakSpeed)),
                            (String(localized: "Anfahren"), String(format: "%.2f m/s²", ride.peakAcceleration)),
                            (String(localized: "Bremsen"), String(format: "%.2f m/s²", ride.peakDeceleration)),
                            (String(localized: "Ruck"), String(format: "%.2f m/s³", ride.peakJerk)),
                        ])
                        if let vibration = ride.cruiseVibration {
                            Text("Vibration während der Fahrt (A95, Spitze–Spitze): \(String(format: "%.0f", vibration)) mg")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !rides.isEmpty {
                    Text("Beschleunigung, Ruck und Vibration wie in ISO 18738, aber mit dem Beschleunigungssensor eines Telefons gemessen: ein Anhaltspunkt, kein Prüfprotokoll.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            runButton("elevator", title: "Auswerten") { await model.runElevator() }
        }
    }

    // MARK: - Comfort

    private var comfortCard: some View {
        card(icon: "tram", title: "Fahrkomfort") {
            if let result = model.comfort {
                HStack {
                    Text(verbatim: String(format: "%.2f", result.comfortIndex))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(Self.comfortTitle(result.comfortClass)).font(.callout)
                    Spacer()
                }
                figures([
                    (String(localized: "Senkrecht"), String(format: "%.2f m/s²", result.vertical)),
                    (String(localized: "Quer"), String(format: "%.2f m/s²", result.lateral)),
                    (String(localized: "Längs"), String(format: "%.2f m/s²", result.longitudinal)),
                ])
                if !result.jolts.isEmpty {
                    Text("\(result.jolts.count) Stösse über 1 m/s²").font(.caption).foregroundStyle(.secondary)
                }
                Text("Nach dem Muster von EN 12299, mit einem einfachen Filter statt der Normgewichtung — wirkt strenger als die Norm. Zum Vergleich von Strecken und Fahrten gedacht. Das Telefon muss im Fahrzeug fest liegen, nicht in der Hand.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if model.comfortFailed {
                Text("Dafür braucht es mindestens zehn Sekunden Beschleunigung mit 20 Hz oder mehr.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            runButton("comfort", title: "Auswerten") { await model.runComfort() }
        }
    }

    static func comfortTitle(_ comfortClass: RideComfort.Class) -> LocalizedStringKey {
        switch comfortClass {
        case .veryComfortable: "sehr komfortabel"
        case .comfortable: "komfortabel"
        case .medium: "mittel"
        case .lessComfortable: "weniger komfortabel"
        case .uncomfortable: "unkomfortabel"
        }
    }

    // MARK: - Vibration

    private var vibrationCard: some View {
        card(icon: "waveform.path", title: "Erschütterung") {
            Picker("Gebäudeart", selection: Binding(get: { model.vibrationCategory },
                                                   set: { model.vibrationCategory = $0 })) {
                Text("Gewerbe und Industrie").tag(VibrationScreening.Category.commercial)
                Text("Wohnbauten").tag(VibrationScreening.Category.dwelling)
                Text("Empfindlich oder schützenswert").tag(VibrationScreening.Category.sensitive)
            }
            if let result = model.vibration {
                HStack {
                    Text(verbatim: String(format: "%.1f mm/s", result.governing.peakVelocity))
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    Spacer()
                    if result.exceeded {
                        Label("Richtwert überschritten", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.recording)
                    } else {
                        Label("Unter dem Richtwert", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
                figures([
                    (String(localized: "Richtwert"), String(format: "%.1f mm/s", result.guideValue)),
                    (String(localized: "Frequenz"), String(format: "%.0f Hz", result.governing.frequency)),
                    (String(localized: "Auslastung"), String(format: "%.0f %%", result.ratio * 100)),
                ])
                Text(verbatim: String(format: "x %.1f · y %.1f · z %.1f mm/s", result.x.peakVelocity, result.y.peakVelocity, result.z.peakVelocity))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text("Höchste Schwinggeschwindigkeit je Achse gegen die Richtwerte der DIN 4150-3. Ein Screening mit dem Beschleunigungssensor des Telefons, das nicht kalibriert ist und nicht am Fundament sass: es zeigt, ob man nahe am Richtwert oder weit davon liegt, und ersetzt kein Gutachten.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if model.vibrationFailed {
                Text("Dafür braucht es Beschleunigung mit mindestens 100 Hz über mehr als vier Sekunden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            runButton("vibration", title: "Auswerten") { await model.runVibration() }
        }
    }

    // MARK: - Dataset

    private var datasetCard: some View {
        card(icon: "brain", title: "Datensatz für maschinelles Lernen") {
            Text("Beschriftet mit den Notizen der Aufnahme: eine Notiz gilt bis zur nächsten. Ausgegeben werden die Messwerte im festen Raster, Fenster mit Kennzahlen und je Beschriftung ein Ordner im Format von Create ML.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper(value: $datasetRate, in: 10...200, step: 10) {
                LabeledContent("Rate") { Text(verbatim: "\(Int(datasetRate)) Hz").monospacedDigit() }
            }
            Stepper(value: $datasetWindow, in: 0.5...30, step: 0.5) {
                LabeledContent("Fenster") { Text(verbatim: String(format: "%.1f s", datasetWindow)).monospacedDigit() }
            }
            Stepper(value: $datasetOverlap, in: 0...0.9, step: 0.1) {
                LabeledContent("Überlappung") { Text(verbatim: "\(Int(datasetOverlap * 100)) %").monospacedDigit() }
            }
            if let summary = model.datasetSummary {
                Text(verbatim: summary.labels.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    let sensors = model.metadata.streams.map(\.sensor).filter {
                        [SensorID.userAcceleration, .rotationRate, .gravity, .accelerometer, .gyroscope, .magnetometer].contains($0)
                    }
                    let options = MLDatasetExporter.Options(sensors: sensors, rateHz: datasetRate,
                                                            windowSeconds: datasetWindow, overlap: datasetOverlap)
                    if let url = await model.exportDataset(options: options) { shareItem = ShareItem(url: url) }
                }
            } label: {
                if model.isRunning("dataset") { ProgressView() } else { Label("Datensatz erzeugen", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRunning("dataset"))
        }
    }

    // MARK: - Pieces

    private func card<Content: View>(icon: String, title: LocalizedStringKey,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func runButton(_ key: String, title: LocalizedStringKey, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            if model.isRunning(key) { ProgressView() } else { Label(title, systemImage: "play.fill") }
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .disabled(model.isRunning(key))
    }

    private func figures(_ items: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(verbatim: item.1).font(.callout.monospacedDigit())
                }
            }
        }
    }

    private func renderReport(_ quality: QualityReport) {
        isRenderingReport = true
        let settings = hub.settings
        let model = self.model
        Task {
            let url = RecordingReport.render(metadata: model.metadata, quality: quality, road: model.road,
                                             rides: model.rides, comfort: model.comfort, vibration: model.vibration,
                                             inspector: settings.inspectorName ?? "",
                                             organisation: settings.inspectorOrganisation ?? "")
            isRenderingReport = false
            if let url { shareItem = ShareItem(url: url) }
        }
    }
}

struct VerdictChip: View {
    let verdict: QualityVerdict
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if !compact || verdict != .good { Text(title) }
        }
        .font(compact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.2), in: .capsule)
        .foregroundStyle(color)
    }

    private var title: LocalizedStringKey {
        switch verdict {
        case .good: "gut"
        case .fair: "mit Einschränkungen"
        case .poor: "schlecht"
        }
    }

    private var symbol: String {
        switch verdict {
        case .good: "checkmark.circle.fill"
        case .fair: "exclamationmark.circle.fill"
        case .poor: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch verdict {
        case .good: .green
        case .fair: .orange
        case .poor: Theme.recording
        }
    }
}

enum ReportFormat {
    static func length(_ metres: Double) -> String {
        metres >= 1_000 ? String(format: "%.2f km", metres / 1_000) : String(format: "%.0f m", metres)
    }
}
