import Charts
import SensorstormCore
import SwiftUI

// MARK: - HTTP speed test

@MainActor @Observable
final class SpeedTestModel {
    enum Stage: Equatable {
        case idle, latency, download, upload, done
    }

    var downloadURL = ThroughputEngine.defaultDownload.absoluteString
    var uploadURL = ThroughputEngine.defaultUpload.absoluteString

    private(set) var stage: Stage = .idle
    private(set) var idleLatency: [Double] = []
    private(set) var loadedLatency: [Double] = []
    private(set) var download: ThroughputEngine.Result?
    private(set) var upload: ThroughputEngine.Result?
    private(set) var live: [ThroughputEngine.Sample] = []
    private(set) var invalidURL = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { stage != .idle && stage != .done }

    /// The median, because one stray round trip should not move the figure.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func start() {
        guard !isRunning else { return }
        guard let down = URL(string: downloadURL), let up = URL(string: uploadURL),
              down.host != nil, up.host != nil else {
            invalidURL = true
            return
        }
        invalidURL = false
        idleLatency = []
        loadedLatency = []
        download = nil
        upload = nil
        live = []
        task = Task { [weak self] in
            guard let self else { return }
            stage = .latency
            idleLatency = await ThroughputEngine.latency()

            // While the line is full, ask how long a small round trip takes: the difference to
            // the idle figure is what a video call feels while a download runs.
            stage = .download
            live = []
            let probes = Task { [weak self] in
                var values: [Double] = []
                while !Task.isCancelled {
                    let result = await TCP.probe(host: "1.1.1.1", port: 443, timeout: 2)
                    if let roundTrip = result.roundTrip { values.append(roundTrip) }
                    await self?.setLoaded(values)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            download = await ThroughputEngine.run(.download, url: down) { sample in
                Task { @MainActor [weak self] in self?.live.append(sample) }
            }
            probes.cancel()
            if Task.isCancelled { stage = .idle; return }

            stage = .upload
            live = []
            upload = await ThroughputEngine.run(.upload, url: up) { sample in
                Task { @MainActor [weak self] in self?.live.append(sample) }
            }
            stage = Task.isCancelled ? .idle : .done
        }
    }

    private func setLoaded(_ values: [Double]) {
        loadedLatency = values
    }

    func cancel() {
        task?.cancel()
        task = nil
        stage = .idle
    }
}

struct SpeedTestView: View {
    @State private var model = SpeedTestModel()

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Button {
                    if model.isRunning { model.cancel() } else { model.start() }
                } label: {
                    if model.isRunning {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Messung starten", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
            } footer: {
                Text("Misst, wie schnell das Telefon aus dem Internet lädt und dorthin sendet, und wie stark sich die Antwortzeit verschlechtert, solange die Leitung voll ist. Vier Verbindungen, je acht Sekunden. Standardmässig gegen die öffentlichen Messpunkte von Cloudflare; das verbraucht Datenvolumen.")
            }

            switch model.stage {
            case .latency: Section { Label("Antwortzeit …", systemImage: "waveform.path.ecg") }
            case .download: Section { Label("Download …", systemImage: "arrow.down.circle") }
            case .upload: Section { Label("Upload …", systemImage: "arrow.up.circle") }
            case .idle, .done: EmptyView()
            }

            if !model.live.isEmpty {
                Section {
                    Chart {
                        ForEach(Array(model.live.enumerated()), id: \.offset) { _, sample in
                            LineMark(x: .value("Zeit", sample.time), y: .value("Wert", sample.megabits))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .chartYAxisLabel { Text(verbatim: "Mbit/s") }
                    .frame(height: 140)
                }
            }

            if model.download != nil || model.upload != nil || !model.idleLatency.isEmpty {
                Section("Ergebnis") {
                    if let down = model.download {
                        LabeledContent("Download") { Text(verbatim: NetFormat.megabits(down.megabits)).monospacedDigit() }
                    }
                    if let up = model.upload {
                        LabeledContent("Upload") { Text(verbatim: NetFormat.megabits(up.megabits)).monospacedDigit() }
                    }
                    if let idle = SpeedTestModel.median(model.idleLatency) {
                        LabeledContent("Antwortzeit im Leerlauf") {
                            Text(verbatim: NetFormat.milliseconds(idle)).monospacedDigit()
                        }
                    }
                    if let loaded = SpeedTestModel.median(model.loadedLatency) {
                        LabeledContent("Antwortzeit unter Last") {
                            Text(verbatim: NetFormat.milliseconds(loaded)).monospacedDigit()
                        }
                        if let idle = SpeedTestModel.median(model.idleLatency), loaded > idle * 3, loaded - idle > 0.03 {
                            Label("Die Antwortzeit steigt unter Last stark. Das deutet auf einen überfüllten Puffer im Router hin (Bufferbloat).",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section {
                TextField("Download-Adresse", text: $model.downloadURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Upload-Adresse", text: $model.uploadURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                if model.invalidURL {
                    Text("Eine der Adressen ist ungültig.").foregroundStyle(Theme.recording)
                }
            } header: {
                Text("Gegenstelle")
            } footer: {
                Text("Jeder Server, der eine grosse Datei ausliefert und POST-Daten annimmt, taugt — auch einer im eigenen Netz, um das WLAN ohne Internet zu messen.")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Geschwindigkeit")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.cancel() }
    }
}

// MARK: - iperf3

@MainActor @Observable
final class Iperf3Model {
    enum State: Equatable {
        case idle, running, done, failed(String)
    }

    private(set) var state: State = .idle
    private(set) var result: Iperf3Result?
    private(set) var live: [ThroughputEngine.Sample] = []
    private var task: Task<Void, Never>?

    func start(host: String, port: Int, duration: Int, streams: Int, reverse: Bool) {
        guard state != .running else { return }
        state = .running
        result = nil
        live = []
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { [weak self] in
            do {
                let outcome = try await Iperf3Client.run(
                    host: target, port: UInt16(clamping: port), duration: duration, parallel: streams,
                    reverse: reverse) { sample in
                        Task { @MainActor [weak self] in self?.live.append(sample) }
                    }
                guard let self else { return }
                result = outcome
                state = .done
            } catch {
                guard let self else { return }
                state = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}

struct Iperf3View: View {
    @State private var host = ""
    @State private var port = 5_201
    @State private var duration = 10
    @State private var streams = 1
    @State private var reverse = false
    @State private var model = Iperf3Model()

    var body: some View {
        List {
            Section {
                TargetField(title: "Adresse des Servers", text: $host)
                Stepper(value: $port, in: 1...65_535) {
                    LabeledContent("Port") { Text(verbatim: "\(port)").monospacedDigit() }
                }
                Stepper(value: $duration, in: 5...60, step: 5) {
                    LabeledContent("Dauer") { Text(verbatim: "\(duration) s").monospacedDigit() }
                }
                Stepper(value: $streams, in: 1...8) {
                    LabeledContent("Verbindungen") { Text(verbatim: "\(streams)").monospacedDigit() }
                }
                Toggle("Rückrichtung (Server sendet)", isOn: $reverse)
                Button {
                    if model.state == .running {
                        model.cancel()
                    } else {
                        model.start(host: host, port: port, duration: duration, streams: streams, reverse: reverse)
                    }
                } label: {
                    if model.state == .running {
                        Label("Anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Test starten", systemImage: "play.fill")
                    }
                }
                .disabled(model.state != .running && host.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Spricht mit einem iperf3-Server (Standardport 5201), den du selbst betreibst: iperf3 -s. Gemessen wird TCP. Der Test belastet das Netz voll; das Ergebnis der Empfängerseite sagt, was tatsächlich ankam.")
            }

            if model.state == .running { Section { ProgressView() } }
            if case .failed(let text) = model.state {
                Section {
                    Label { Text(verbatim: text) } icon: { Image(systemName: "xmark.octagon") }
                        .foregroundStyle(Theme.recording)
                }
            }
            if !model.live.isEmpty {
                Section {
                    Chart {
                        ForEach(Array(model.live.enumerated()), id: \.offset) { _, sample in
                            LineMark(x: .value("Zeit", sample.time), y: .value("Wert", sample.megabits))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .chartYAxisLabel { Text(verbatim: "Mbit/s") }
                    .frame(height: 140)
                }
            }
            if let result = model.result {
                Section("Ergebnis") {
                    LabeledContent("Sender") { Text(verbatim: NetFormat.megabits(result.senderMegabits)).monospacedDigit() }
                    LabeledContent("Empfänger") { Text(verbatim: NetFormat.megabits(result.receiverMegabits)).monospacedDigit() }
                    LabeledContent("Verbindungen") { Text(verbatim: "\(result.streams)").monospacedDigit() }
                    LabeledContent("Dauer") { Text(verbatim: "\(Int(result.duration)) s").monospacedDigit() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("iperf3")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.cancel() }
    }
}
