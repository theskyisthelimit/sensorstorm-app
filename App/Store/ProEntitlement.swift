import Foundation
import SensorstormCore
import StoreKit

/// Whether this device owns „Sensorstorm Pro", and the one place that can change it.
///
/// StoreKit 2 answers the question against the signed-in Apple Account, on the device.
/// There is no server of ours, no account of ours and no receipt to validate — which is
/// what keeps „Keine Wolke, kein Konto, kein Tracking" literally true with a paid unlock
/// in the app. `PrivacyInfo.xcprivacy` stays empty for the same reason: we collect nothing.
@MainActor
@Observable
final class ProEntitlement {
    static let productID = "ch.sensorstorm.app.pro"

    private(set) var isPro = false
    private(set) var product: Product?
    /// A purchase or restore is in flight; the paywall's buttons wait for it.
    private(set) var isWorking = false
    /// Shown on the paywall. Not an alert: the sheet is already the place the user is
    /// looking, and an alert on top of a sheet is a stack nobody asked for.
    var failure: String?

    /// Drives the single paywall sheet at the root, so nine gated controls in five screens
    /// need no sheet plumbing of their own.
    var paywall: PaywallRequest?

    var access: ProAccess { ProAccess(isPro: isPro) }

    /// The price, in the storefront's currency, as the App Store formats it. Never a
    /// hardcoded number: the price lives in App Store Connect, so changing it is a setting
    /// rather than a build, and every country shows its own.
    var displayPrice: String? { product?.displayPrice }

    // MARK: - Lifecycle

    /// Runs for as long as the app does — started from `RootView`'s `.task`.
    ///
    /// The listener is not optional. A purchase can land without going through our button:
    /// a redeemed code, a Family Sharing grant from another family member, or an
    /// Ask-to-Buy approval that a parent gives hours later. Without `Transaction.updates`
    /// those users would pay and see nothing unlock until the next launch.
    func start() async {
        await refresh()
        await loadProduct()

        for await update in Transaction.updates {
            if case .verified(let transaction) = update {
                await transaction.finish()
            }
            await refresh()
        }
    }

    /// Reads the current truth from StoreKit. Also the recovery path after a refund: the
    /// entitlement disappears, the locks come back — and every recording stays readable,
    /// because `ProAccess` never gates CSV.
    func refresh() async {
        var unlocked = false
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil else { continue }
            unlocked = true
        }
        isPro = unlocked
    }

    func loadProduct() async {
        guard product == nil else { return }
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            // Not surfaced on its own: an unreachable App Store is only worth a message
            // once the user actually tries to buy, and `purchase()` says it then.
            product = nil
        }
    }

    // MARK: - Actions

    /// A lock was tapped — open the paywall on that feature.
    func requestUnlock(_ feature: ProFeature) {
        failure = nil
        paywall = PaywallRequest(feature: feature)
    }

    /// Opened from Settings, where there is no single feature to lead with.
    func showPaywall() {
        failure = nil
        paywall = PaywallRequest(feature: nil)
    }

    /// - Returns: `true` when Pro is unlocked afterwards.
    @discardableResult
    func purchase() async -> Bool {
        isWorking = true
        defer { isWorking = false }
        failure = nil

        // The product load on launch can have failed on a flaky connection; the button is
        // the second chance, not a dead end.
        if product == nil { await loadProduct() }
        guard let product else {
            failure = String(localized: "Der App Store ist gerade nicht erreichbar. Versuche es später noch einmal.")
            return false
        }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    failure = String(localized: "Der Kauf liess sich nicht überprüfen und wurde nicht freigeschaltet.")
                    return false
                }
                await transaction.finish()
                await refresh()
                return isPro
            case .userCancelled:
                return false
            case .pending:
                // Ask to Buy, or a payment method that needs confirming. The purchase is
                // not lost — `Transaction.updates` picks it up whenever it clears.
                failure = String(localized: "Der Kauf wartet auf Freigabe. Sobald sie erteilt ist, schaltet sich Pro von selbst frei.")
                return false
            @unknown default:
                return false
            }
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    /// Required by App Store Review guideline 3.1.1 for a non-consumable, and by anyone who
    /// has switched phones.
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil

        do {
            try await AppStore.sync()
        } catch {
            // A cancelled sign-in sheet throws too. Refresh anyway and let the outcome
            // speak: if the entitlement is there, nothing went wrong worth reporting.
        }
        await refresh()
        if !isPro {
            failure = String(localized: "Zu diesem Apple-Account wurde kein Kauf von Sensorstorm Pro gefunden.")
        }
    }
}
