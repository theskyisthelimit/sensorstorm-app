import SwiftUI

/// One screen, one decision. A watch app for this is a start button, a pulse and a count —
/// anything more is read from the phone that is already in the same pocket.
struct WatchRootView: View {
    @Environment(WatchRecorder.self) private var recorder

    var body: some View {
        VStack(spacing: 10) {
            heartRate

            switch recorder.phase {
            case .idle:
                button(title: "Aufnahme starten", symbol: "record.circle", tint: .red) {
                    Task { await recorder.start() }
                }
            case .starting:
                ProgressView()
                    .frame(maxHeight: .infinity)
            case .running:
                // A plain computed property would render once and then sit there; the clock
                // has to be told to tick.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(verbatim: elapsed)
                        .font(.title3.monospacedDigit())
                }
                Text("\(recorder.sentSamples) gesendet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                button(title: "Stopp", symbol: "stop.circle", tint: .gray) {
                    recorder.stop()
                }
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                button(title: "Nochmals versuchen", symbol: "arrow.clockwise", tint: .red) {
                    Task { await recorder.start() }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var heartRate: some View {
        if let rate = recorder.heartRate {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("\(Int(rate.rounded()))")
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                Text(verbatim: "bpm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if recorder.phase == .running {
            // The first reading takes a few seconds. A dash says "not yet", a zero would
            // say "no pulse", which is a very different claim.
            Text(verbatim: "—")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var elapsed: String {
        guard let startedAt = recorder.startedAt else { return "0:00" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func button(title: LocalizedStringKey, symbol: String, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .tint(tint)
    }
}
