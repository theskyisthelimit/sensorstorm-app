import SensorstormCore
import SwiftUI

/// The options for the photogrammetry export.
///
/// It asks two things, and only two, because only two of them cannot be decided for the
/// user: how many images, and how far away the subject is. The second one is the one that
/// matters — the right spacing between images depends on the distance to what is being
/// photographed, and the recording does not measure that. So the presets say what they
/// assume instead of pretending to know.
struct PhotoSetExportView: View {
    let recording: RecordingMetadata
    let onExport: (PhotoSetOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targetCount = 150.0
    @State private var subject: SubjectDistance = .facade

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Entfernung", selection: $subject) {
                        ForEach(SubjectDistance.allCases, id: \.self) { distance in
                            Text(distance.title).tag(distance)
                        }
                    }
                } header: {
                    Text("Wie weit weg ist das Objekt?")
                } footer: {
                    Text(subject.explanation)
                }

                Section {
                    Stepper(value: $targetCount, in: 20...600, step: 10) {
                        LabeledContent("Bilder", value: "\(Int(targetCount))")
                    }
                } footer: {
                    Text("Ein Richtwert, keine Zusage. Wo die Kamera stehen geblieben ist, kommen weniger Bilder heraus — hundertmal dasselbe Bild nützt keiner Rekonstruktion.")
                }

                Section {
                    Button("Exportieren") {
                        onExport(PhotoSetOptions(targetCount: Int(targetCount), subject: subject))
                        dismiss()
                    }
                } footer: {
                    Text("Die Bilder tragen Brennweite, Ort und Zeit im EXIF. Daneben liegen eine Kameratabelle und ein COLMAP-Modell. Das 3D-Modell rechnet RealityScan, Metashape oder Meshroom — nicht diese App.")
                }
            }
            .navigationTitle("Bilder für Fotogrammetrie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}

extension SubjectDistance {
    var title: LocalizedStringKey {
        switch self {
        case .object: "Objekt, unter 2 m"
        case .facade: "Fassade oder Raum"
        case .terrain: "Gelände oder Strasse"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .object:
            "Kleine Schritte: alle 10 cm ein Bild. Für etwas, das man umrundet."
        case .facade:
            "Alle 35 cm ein Bild. Für eine Wand, einen Raum, eine Maschine."
        case .terrain:
            "Alle 1,5 m ein Bild. Für einen abgelaufenen Weg oder eine Strasse."
        }
    }
}
