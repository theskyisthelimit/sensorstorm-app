import Charts
import SensorstormCore
import SwiftUI

/// One external stream, one chart, with the playhead on it and the values at the playhead
/// underneath. The counterpart of ``SensorChartCard`` for streams that are not built-in
/// sensors: title, unit and channel names come from the stream itself.
struct ExternalChartCard: View {
    let data: ExternalChartData
    let playhead: Double
    let visibleRange: ClosedRange<Double>
    let currentValues: [Double]?
    let annotations: [Double]
    let onScrub: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: data.info.source.symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(verbatim: data.info.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer()
            }
            chart
                .frame(height: 130)
            legend
        }
        .padding(14)
        .card()
    }

    private var chart: some View {
        Chart {
            ForEach(Array(data.series.enumerated()), id: \.offset) { index, points in
                ForEach(points, id: \.time) { point in
                    if point.value.isFinite {
                        LineMark(
                            x: .value("Zeit", point.time),
                            y: .value("Wert", point.value),
                            series: .value("Kanal", data.info.channels[index])
                        )
                        .foregroundStyle(Theme.color(forChannel: index))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
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
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let origin = geometry[plotFrame].origin
                        guard let time: Double = proxy.value(atX: location.x - origin.x) else { return }
                        onScrub(min(max(time, visibleRange.lowerBound), visibleRange.upperBound))
                    }
            }
        }
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 74), spacing: 12, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Array(data.info.channels.enumerated()), id: \.offset) { index, channel in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.color(forChannel: index))
                            .frame(width: 6, height: 6)
                        Text(verbatim: channel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Text(verbatim: valueText(index))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func valueText(_ channel: Int) -> String {
        guard let currentValues, currentValues.indices.contains(channel) else { return "—" }
        return Format.value(currentValues[channel], unit: data.info.unit(forChannel: channel))
    }
}
