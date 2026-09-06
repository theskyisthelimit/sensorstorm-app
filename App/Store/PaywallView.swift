import SensorstormCore
import SwiftUI

/// What the root sheet is showing. A plain `ProFeature?` cannot express „opened from
/// Settings" — that is an absent feature, not an absent sheet.
struct PaywallRequest: Identifiable, Hashable {
    let feature: ProFeature?
    var id: String { feature?.rawValue ?? "overview" }
}

/// The one screen where money changes hands.
///
/// Opened by whichever lock the user tapped, so it leads with *that* feature and lists the
/// rest underneath — someone who wanted GeoJSON should not have to hunt for it in a grid of
/// nine icons.
struct PaywallView: View {
    @Environment(ProEntitlement.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The lock that was tapped. `nil` when the sheet was opened from Settings, where there
    /// is no single feature to lead with.
    let feature: ProFeature?

    /// Everything except the one already shown at the top.
    private var remainingFeatures: [ProFeature] {
        ProFeature.allCases.filter { $0 != feature }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let feature { highlight(feature) }
                    featureList
                    dataPromise
                    if let failure = pro.failure { failureNote(failure) }
                }
                .padding(20)
                .padding(.bottom, 140)
            }
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .navigationTitle("Sensorstorm Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schliessen") { dismiss() }
                        .disabled(pro.isWorking)
                }
            }
        }
        .task { await pro.loadProduct() }
        .onChange(of: pro.isPro) { _, isPro in
            // Nothing more to sell. Leaving the sheet open on a bought product would make
            // the user close a shop they already left.
            if isPro { dismiss() }
        }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Einmal kaufen, dauerhaft behalten")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("Kein Abo, keine Verlängerung, kein Konto.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func highlight(_ feature: ProFeature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.title)
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text(feature.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(feature == nil ? "Pro schaltet frei" : "Ausserdem in Pro")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(remainingFeatures) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        Text(item.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    /// The reassurance that makes the gating defensible — and it is true, enforced by
    /// `ProAccess.freeRecordingFormats` and covered by a test.
    private var dataPromise: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.open")
                .foregroundStyle(.secondary)
            Text("Ohne Pro bleibt der CSV-Export jeder Aufnahme und jeder Begehung offen. Deine Messungen gehören dir, gekauft oder nicht.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureNote(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Theme.recording)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var purchaseBar: some View {
        VStack(spacing: 10) {
            Button {
                Task { await pro.purchase() }
            } label: {
                Group {
                    if pro.isWorking {
                        ProgressView().tint(.black)
                    } else if let price = pro.displayPrice {
                        // The App Store's own formatting, in the storefront's currency.
                        Text("Pro freischalten — \(price)")
                    } else {
                        Text("Pro freischalten")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
            .disabled(pro.isWorking)

            Button("Käufe wiederherstellen") {
                Task { await pro.restore() }
            }
            .font(.footnote)
            .disabled(pro.isWorking)

            HStack(spacing: 14) {
                Button("Datenschutz") { openURL(Self.privacyURL) }
                Button("Nutzungsbedingungen") { openURL(Self.termsURL) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // Both links are required on a screen that sells something. The terms are Apple's
    // standard EULA, which is what applies unless an app ships its own.
    static let privacyURL = URL(string: "https://sensorstorm.ch/datenschutz.html")!
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
