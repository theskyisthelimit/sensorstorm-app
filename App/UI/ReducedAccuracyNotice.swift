import SwiftUI
import UIKit

/// Shown while the app may only know the approximate location.
///
/// iOS then hands out positions blurred to a few kilometres. Everything downstream stays
/// honest about it — the accuracy column says 3000 m — but a number in a column is read
/// after the walk, and this has to be read before it.
struct ReducedAccuracyNotice: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nur ungefährer Standort", systemImage: "location.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Positionen sind damit auf mehrere Kilometer ungenau. In den Einstellungen unter „Ort“ den genauen Standort einschalten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}
