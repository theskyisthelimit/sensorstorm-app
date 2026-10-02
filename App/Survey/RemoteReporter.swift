import Foundation
import SensorstormCore

/// Sends a case to the systems the person configured: a webhook and an Open311 endpoint.
///
/// Opt-in twice over — the addresses are empty until typed in — and never silent: a send that
/// fails says so on the case, and a send that works writes down when, so the same case is not
/// reported to a city twice by two taps.
enum RemoteReporter {

    enum Outcome: Equatable {
        case sent(reference: String?)
        case failed(String)
        case notConfigured
    }

    static let webhookMark = "_reported.webhook"
    static let open311Mark = "_reported.open311"

    static func isWebhookConfigured(_ settings: RecordingSettings) -> Bool {
        URL(string: settings.webhookURL ?? "")?.host != nil
    }

    static func isOpen311Configured(_ settings: RecordingSettings) -> Bool {
        URL(string: settings.open311URL ?? "")?.host != nil && !(settings.open311ServiceCode ?? "").isEmpty
    }

    static func sendWebhook(_ finding: GroundFinding, in survey: Survey, settings: RecordingSettings,
                            coverPhoto: Data?) async -> Outcome {
        guard let url = URL(string: settings.webhookURL ?? ""), url.host != nil else { return .notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = settings.webhookToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = RemoteReport.webhookJSON(finding, in: survey,
                                                    coverPhoto: settings.webhookIncludesPhoto ? coverPhoto : nil)
        return await perform(request) { _ in nil }
    }

    static func sendOpen311(_ finding: GroundFinding, settings: RecordingSettings) async -> Outcome {
        guard let base = URL(string: settings.open311URL ?? ""), base.host != nil,
              let service = settings.open311ServiceCode, !service.isEmpty else { return .notConfigured }
        var url = base
        if !url.lastPathComponent.hasSuffix(".json") { url.appendPathComponent("requests.json") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = RemoteReport.formBody(RemoteReport.open311Fields(
            finding, serviceCode: service, apiKey: settings.open311Key ?? "", jurisdiction: settings.open311Jurisdiction))
        return await perform(request) { RemoteReport.parseOpen311Response($0) }
    }

    private static func perform(_ request: URLRequest, reference: (Data) -> String?) async -> Outcome {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return .failed("HTTP \(status)")
            }
            return .sent(reference: reference(data))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
