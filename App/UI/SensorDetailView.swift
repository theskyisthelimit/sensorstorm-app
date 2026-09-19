import Charts
import SensorstormCore
import SwiftUI

/// One sensor, alone and up close: every channel spelled out, a curve that starts the
/// moment the sheet opens, and the actions that belong to this stream.
///
/// Three pieces of tester feedback on build 14 pointed at the same missing thing. „Wieso
/// gibts hier nicht mehr Infos?!“ on the network tile, which shows one of its three
/// channels. „Ich muss doch den Barometer kalibrieren oder resetten können… da braucht es
/// einen Knopf“ — the button existed, but only in a long-press menu, which is the same as
/// not existing. And „auf einen Sensor klicken und dann mehr Infos und auch einen Verlauf
/// für nur diesen Sensor sehen und zu resetten“.
///
/// A tile is small on purpose: eighteen of them have to fit on one screen. This is where
/// the room is.
struct SensorDetailView: View {
    let sensor: SensorID

    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    /// The rolling window, filled from the live dictionary rather than from the recording.
    /// That is the point: the curve runs while the record screen is merely open, so a
    /// barometer can be watched settling before anything is written to disk.
    @State private var history: [Reading] = []

    /// How much of the past the curve shows. Thirty seconds is long enough to see a step
    /// and short enough to stay readable at 100 Hz without thinning the data.
    private static let window: TimeInterval = 30

    private struct Reading: Identifiable {
        let id = UUID()
        let hostTime: Double
        let values: [Double]
    }

    private var descriptor: SensorDescriptor { sensor.descriptor }
    private var sample: LiveSample? { hub.live[sensor] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    chartCard
                    valuesCard
                    actionsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle(sensor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .onChange(of: sample) { _, new in
            guard let new else { return }
            append(new)
        }
        .onAppear {
            if let sample { append(sample) }
        }
    }

    // MARK: - Der Verlauf

    private func append(_ sample: LiveSample) {
        // The live dictionary is refreshed on a 10 Hz display timer, so the same sample can
        // arrive twice for a slow stream. A repeated timestamp would draw a vertical line
        // through the curve.
        if let last = history.last, last.hostTime == sample.hostTime { return }
        history.append(Reading(hostTime: sample.hostTime, values: sample.values))
        let cutoff = sample.hostTime - Self.window
        if let first = history.first, first.hostTime < cutoff {
            history.removeAll { $0.hostTime < cutoff }
        }
    }

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verlauf")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if history.count < 2 {
                Text("wartet …")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                // Eine Kurve je Einheit. Druck in Kilopascal und Höhe in Metern auf
                // derselben Achse heisst: 97 gegen 0, die Höhe liegt platt am Boden und
                // das Einzige, wofür man sie ansieht — ob sie sich bewegt — ist das
                // Einzige, was man nicht sieht.
                ForEach(unitGroups, id: \.unit) { group in
                    if unitGroups.count > 1 {
                        Text(group.unit.isEmpty ? String(localized: "ohne Einheit") : group.unit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    chart(channels: group.channels)
                        .frame(height: unitGroups.count > 1 ? 120 : 160)
                }
            }

            Text("Läuft, seit diese Ansicht offen ist. Die Aufnahme startet weiterhin auf der Hauptseite.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    /// Die gezeigten Kanäle, nach Einheit gruppiert und in der Reihenfolge des Stroms.
    private var unitGroups: [(unit: String, channels: [Int])] {
        var order: [String] = []
        var grouped: [String: [Int]] = [:]
        for channel in sensor.highlightChannels {
            let unit = descriptor.unit(forChannel: channel)
            if grouped[unit] == nil { order.append(unit) }
            grouped[unit, default: []].append(channel)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func chart(channels: [Int]) -> some View {
        // Seconds before now, so the newest value sits at the right edge and the axis needs
        // no absolute clock — which would be meaningless for a thirty-second window.
        let newest = history.last?.hostTime ?? 0
        return Chart {
            ForEach(channels, id: \.self) { channel in
                ForEach(history) { reading in
                    if reading.values.indices.contains(channel) {
                        LineMark(
                            x: .value("Zeit", reading.hostTime - newest),
                            y: .value("Wert", reading.values[channel]),
                            series: .value("Kanal", descriptor.channels[channel])
                        )
                        .foregroundStyle(Theme.color(forChannel: channel))
                    }
                }
            }
        }
        .chartXScale(domain: -Self.window...0)
        .chartXAxis {
            AxisMarks(values: [-Self.window, -Self.window / 2, 0]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(Format.seconds(seconds))
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(.hidden)
    }

    // MARK: - Die Werte

    private var valuesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Werte")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let sample {
                    Text(Format.rate(sample.rateHz))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            // Every channel, not the two or three the tile has room for. The network tile
            // showing „type“ alone is what prompted „Wieso gibts hier nicht mehr Infos?!“.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(Array(descriptor.channels.enumerated()), id: \.offset) { index, name in
                    GridRow {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(sample.flatMap { $0.values.indices.contains(index)
                                              ? Format.channelValue(sensor: sensor, channel: index,
                                                                    value: $0.values[index])
                                              : nil } ?? "—")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(Theme.color(forChannel: index))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    // MARK: - Was sich hier tun lässt

    private var actionsCard: some View {
        VStack(spacing: 0) {
            if sensor == .barometer {
                Button {
                    hub.zeroBarometer()
                    history.removeAll()
                } label: {
                    actionLabel("Höhe hier nullen", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.cardBorder)
            }

            Button {
                history.removeAll()
            } label: {
                actionLabel("Verlauf zurücksetzen", systemImage: "clear")
            }
            .buttonStyle(.plain)
            .disabled(history.isEmpty)
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
}
