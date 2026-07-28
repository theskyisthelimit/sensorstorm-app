import Charts
import SensorstormCore
import SwiftUI

/// One stream, one chart, with the playhead drawn on it and the values at the playhead
/// spelled out underneath — so the numbers and the curve can never disagree.
struct SensorChartCard: View {
    let data: SensorChartData
    let playhead: Double
    let visibleRange: ClosedRange<Double>
    let currentValues: [Double]?
    let annotations: [Double]
    let onScrub: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chart
                .frame(height: 130)
            legend
        }
        .padding(14)
        .card()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: data.sensor.symbol)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text(data.sensor.title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(data.sensor.descriptor.unit)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(data.series.enumerated()), id: \.offset) { index, points in
                ForEach(points, id: \.time) { point in
                    LineMark(
                        x: .value("Zeit", point.time),
                        y: .value("Wert", point.value),
                        series: .value("Kanal", data.channels[index])
                    )
                    .foregroundStyle(Theme.color(forChannel: channelIndex(for: index)))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }

            ForEach(annotations, id: \.self) { time in
                RuleMark(x: .value("Markierung", time))
                    .foregroundStyle(Theme.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            RuleMark(x: .value("Position", playhead))
                .foregroundStyle(.white.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXScale(domain: visibleRange)
        .chartYScale(domain: data.yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.cardBorder)
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(Format.duration(seconds))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.cardBorder)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.value(number))
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    // Tap to put the playhead on a spot in the curve. Deliberately the only
                    // gesture here: any drag recogniser attached inside the enclosing
                    // ScrollView swallows vertical swipes, and a page of fifteen charts that
                    // cannot be scrolled is worse than one that cannot be drag-scrubbed.
                    // Continuous scrubbing lives on the transport slider.
                    .onTapGesture { location in
                        scrub(at: location, proxy: proxy, geometry: geometry)
                    }
            }
        }
    }

    private func scrub(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        guard let time: Double = proxy.value(atX: location.x - origin.x) else { return }
        onScrub(min(max(time, visibleRange.lowerBound), visibleRange.upperBound))
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(data.channels.enumerated()), id: \.offset) { index, channel in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.color(forChannel: channelIndex(for: index)))
                            .frame(width: 6, height: 6)
                        Text(channel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(valueText(for: index))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if index < data.channels.count - 1 { Spacer(minLength: 0) }
            }
            Spacer(minLength: 0)
        }
    }

    /// Keeps a channel's colour tied to its position in the *sensor*, not in the plotted
    /// subset — so "speed" doesn't turn red just because latitude isn't charted.
    private func channelIndex(for plotIndex: Int) -> Int {
        let all = data.sensor.descriptor.channels
        guard plotIndex < data.channels.count,
              let actual = all.firstIndex(of: data.channels[plotIndex]) else { return plotIndex }
        return actual
    }

    private func valueText(for plotIndex: Int) -> String {
        let channel = channelIndex(for: plotIndex)
        guard let currentValues, currentValues.indices.contains(channel) else { return "—" }
        return Format.channelValue(sensor: data.sensor, channel: channel,
                                   value: currentValues[channel])
    }
}
