import AVFoundation
import Observation
import SensorstormCore
import SwiftUI

/// Listens to the microphone for a moment and reports the A-weighted level in dBFS(A), for
/// the one purpose of calibrating it against a reference.
@MainActor @Observable
final class CalibrationMeter {
    private(set) var level: Double?
    private(set) var denied = false
    private let engine = AVAudioEngine()
    private let meter = AWeightedMeter()
    private var smoothed: Double?

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            denied = true
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [])
        try? session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let meter = self.meter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let value = meter.level(from: buffer)?.average else { return }
            Task { @MainActor in self?.update(value) }
        }
        engine.prepare()
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func update(_ value: Double) {
        // About a second of memory: a calibrator tone is steady, and the reading should be too.
        let previous = smoothed ?? value
        smoothed = previous * 0.85 + value * 0.15
        level = smoothed
    }
}

/// Pins the microphone's dBFS(A) to a known sound pressure level.
///
/// A phone microphone has no stated sensitivity, so its level is only relative until it is
/// held against something of known loudness: an acoustic calibrator (94 dB at 1 kHz), or a
/// sound level meter next to it in a steady noise. The difference becomes an offset that is
/// added to every dB(A) value and written to the recording.
struct AudioCalibrationView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var meter = CalibrationMeter()
    @State private var reference = 94.0

    var body: some View {
        @Bindable var hub = hub
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Pegel jetzt") {
                        if let level = meter.level {
                            Text(verbatim: String(format: "%.1f dBFS(A)", level)).monospacedDigit()
                        } else if meter.denied {
                            Text("Kein Zugriff aufs Mikrofon")
                        } else {
                            ProgressView()
                        }
                    }
                    Stepper(value: $reference, in: 30...130, step: 0.5) {
                        LabeledContent("Soll") { Text(verbatim: String(format: "%.1f dB", reference)).monospacedDigit() }
                    }
                    Button {
                        if let level = meter.level { hub.settings.audioCalibrationDecibels = reference - level }
                    } label: {
                        Label("Jetzt entspricht dieser Pegel dem Soll", systemImage: "checkmark.circle")
                    }
                    .disabled(meter.level == nil)
                } footer: {
                    Text("Das Telefon an einen akustischen Kalibrator halten (94 dB bei 1 kHz) oder neben ein Schallpegelmessgerät in gleichmässiges Rauschen legen, den Wert dort ablesen und hier eintragen.")
                }
                Section {
                    if let offset = hub.settings.audioCalibrationDecibels {
                        LabeledContent("Aufschlag") { Text(verbatim: String(format: "%+.1f dB", offset)).monospacedDigit() }
                        if let level = meter.level {
                            LabeledContent("Anzeige jetzt") {
                                Text(verbatim: String(format: "%.1f dB(A)", level + offset)).monospacedDigit()
                            }
                        }
                        Button("Kalibrierung entfernen", role: .destructive) { hub.settings.audioCalibrationDecibels = nil }
                    } else {
                        Text("Nicht kalibriert: die Werte sind relativ, nicht dB(SPL).").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Kalibrierung")
                } footer: {
                    Text("Der Aufschlag gilt für dieses Gerät und diese Hülle. Er wird mit jeder Aufnahme gespeichert, die den Strom „Lautstärke dB(A)“ enthält.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Mikrofon kalibrieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .task { await meter.start() }
        .onDisappear { meter.stop() }
    }
}
