import Charts
import SensorstormCore
import SwiftUI

/// One external stream, alone: every channel spelled out and a curve that starts the moment
/// the sheet opens. The counterpart of ``SensorDetailView`` for streams that are not the
/// phone's own sensors — the data comes from the live dictionary, not from a recording.
struct ExternalDetailView: View {
    let streamID: String

    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var history: [Reading] = []

    private static let window: TimeInterval = 60

    private struct Reading: Identifiable {
        let id = UUID()
        let hostTime: Double
        let values: [Double]
    }

    private var sample: LiveExternalSample? {
        hub.externalLive.first { $0.id == streamID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let sample {
                        chartCard(sample)
                        valuesCard(sample)
                    } else {
                        Text("Dieses Gerät sendet gerade nicht.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .card()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle(sample?.info.title ?? streamID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .onChange(of: sample) { _, new in
            if let new { append(new) }
        }
        .onAppear {
            if let sample { append(sample) }
        }
    }

    private func append(_ sample: LiveExternalSample) {
        if let last = history.last, last.hostTime == sample.hostTime { return }
        history.append(Reading(hostTime: sample.hostTime, values: sample.values))
        let cutoff = sample.hostTime - Self.window
        history.removeAll { $0.hostTime < cutoff }
    }

    private func chartCard(_ sample: LiveExternalSample) -> some View {
        let newest = history.last?.hostTime ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Verlauf")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if history.count < 2 {
                Text("wartet …")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                // One curve per unit: a temperature and a humidity on one axis put one of
                // them flat on the floor.
                let groups = unitGroups(sample.info)
                ForEach(groups, id: \.unit) { group in
                    if groups.count > 1 {
                        Text(verbatim: group.unit.isEmpty ? "–" : group.unit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Chart {
                        ForEach(group.channels, id: \.self) { channel in
                            ForEach(history) { reading in
                                if reading.values.indices.contains(channel),
                                   reading.values[channel].isFinite {
                                    LineMark(
                                        x: .value("Zeit", reading.hostTime - newest),
                                        y: .value("Wert", reading.values[channel]),
                                        series: .value("Kanal", sample.info.channels[channel]))
                                    .foregroundStyle(Theme.color(forChannel: channel))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: -Self.window...0)
                    .chartYAxis { AxisMarks(position: .leading) }
                    .chartLegend(.hidden)
                    .frame(height: groups.count > 1 ? 120 : 160)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func unitGroups(_ info: ExternalStreamInfo) -> [(unit: String, channels: [Int])] {
        var order: [String] = []
        var grouped: [String: [Int]] = [:]
        for channel in info.channels.indices {
            let unit = info.unit(forChannel: channel)
            if grouped[unit] == nil { order.append(unit) }
            grouped[unit, default: []].append(channel)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func valuesCard(_ sample: LiveExternalSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Werte")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Format.rate(sample.rateHz))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(Array(sample.info.channels.enumerated()), id: \.offset) { index, name in
                    GridRow {
                        Text(verbatim: name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(verbatim: sample.values.indices.contains(index)
                             ? Format.value(sample.values[index], unit: sample.info.unit(forChannel: index))
                             : "—")
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
}
