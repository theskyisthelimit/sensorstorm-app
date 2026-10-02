import SensorstormCore
import SwiftUI

/// Send this case on: to the team's webhook and to a city's Open311 reporter.
struct FindingReportCard: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub
    let surveyID: UUID
    let finding: GroundFinding

    @State private var sending: SurveyModel.Destination?
    @State private var message: String?

    var body: some View {
        let webhook = RemoteReporter.isWebhookConfigured(hub.settings)
        let open311 = RemoteReporter.isOpen311Configured(hub.settings)
        if webhook || open311 {
            VStack(alignment: .leading, spacing: 10) {
                Label("Weiterleiten", systemImage: "paperplane").font(.subheadline.weight(.semibold))
                if webhook { row(.webhook, mark: finding.attributes[RemoteReporter.webhookMark], title: "Webhook") }
                if open311 { row(.open311, mark: finding.attributes[RemoteReporter.open311Mark], title: "Open311") }
                if let message {
                    Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card()
        }
    }

    private func row(_ destination: SurveyModel.Destination, mark: String?, title: LocalizedStringKey) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let mark {
                    Label { Text(verbatim: mark).font(.caption2.monospaced()) } icon: { Image(systemName: "checkmark.circle.fill") }
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            Spacer()
            Button {
                send(destination)
            } label: {
                if sending == destination { ProgressView() } else {
                    Text(mark == nil ? "Senden" : "Erneut senden")
                }
            }
            .buttonStyle(.bordered)
            .disabled(sending != nil)
        }
    }

    private func send(_ destination: SurveyModel.Destination) {
        sending = destination
        message = nil
        Task {
            let outcome = await model.send(finding.id, in: surveyID, to: destination)
            sending = nil
            if case .failed(let reason) = outcome {
                message = String(localized: "Senden fehlgeschlagen: \(reason)")
            }
        }
    }
}

/// The destinations, in the settings.
struct ReportingSettingsSection: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        @Bindable var hub = hub
        Section {
            TextField("Webhook-Adresse", text: Binding(
                get: { hub.settings.webhookURL ?? "" }, set: { hub.settings.webhookURL = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField("Zugangstoken (Bearer)", text: Binding(
                get: { hub.settings.webhookToken ?? "" }, set: { hub.settings.webhookToken = $0 }))
            Toggle("Titelfoto mitschicken", isOn: $hub.settings.webhookIncludesPhoto)
            Toggle("Neue Beobachtungen sofort senden", isOn: $hub.settings.autoSendsFindings)
        } header: {
            Text("Weiterleitung: Webhook")
        } footer: {
            Text("Schickt jede Beobachtung als JSON an diese Adresse: Ort, Schweregrad, Zustand, Adresse, Eigenschaften und Messwerte. Ohne Adresse wird nichts gesendet.")
        }
        Section {
            TextField("Open311-Adresse", text: Binding(
                get: { hub.settings.open311URL ?? "" }, set: { hub.settings.open311URL = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Dienstcode", text: Binding(
                get: { hub.settings.open311ServiceCode ?? "" }, set: { hub.settings.open311ServiceCode = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Gemeinde-Kennung", text: Binding(
                get: { hub.settings.open311Jurisdiction ?? "" }, set: { hub.settings.open311Jurisdiction = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("API-Schlüssel", text: Binding(
                get: { hub.settings.open311Key ?? "" }, set: { hub.settings.open311Key = $0 }))
        } header: {
            Text("Weiterleitung: Open311")
        } footer: {
            Text("Für Mängelmelder von Städten und Gemeinden, die Open311 GeoReport v2 sprechen. Die Adresse ist die des Servers; der Dienstcode benennt die Art der Meldung, wie ihn die Gemeinde festgelegt hat.")
        }
    }
}
