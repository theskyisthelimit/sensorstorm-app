import SensorstormCore
import SwiftUI

struct RecordingDetailView: View {
    @Environment(RecordingLibrary.self) private var library
    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    @State private var playback: RecordingPlayback
    @State private var shareItem: ShareItem?
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showsDeleteConfirmation = false

    let recording: RecordingMetadata

    init(recording: RecordingMetadata, store: RecordingStore) {
        self.recording = recording
        _playback = State(initialValue: RecordingPlayback(metadata: recording, store: store))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let player = playback.player {
                    PlayerLayerView(player: player)
                        .aspectRatio(videoAspectRatio, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 16))
                }

                transportBar

                if !playback.annotations.isEmpty {
                    annotationStrip
                }

                if playback.isLoading {
                    ProgressView().padding(40)
                } else {
                    // The same display filter as the live view. Hiding a stream here never
                    // touches the recording — the chart is gone, the data is not.
                    ForEach(playback.charts.filter { hub.settings.isVisible($0.sensor) }) { data in
                        SensorChartCard(
                            data: data,
                            playhead: playback.playhead,
                            visibleRange: playback.visibleRange,
                            currentValues: playback.values(for: data.sensor),
                            annotations: annotationTimes,
                            onScrub: { playback.pause(); playback.seek(to: $0) }
                        )
                        .contextMenu {
                            Button {
                                hub.settings.setVisible(false, for: data.sensor)
                            } label: {
                                Label("Ausblenden", systemImage: "eye.slash")
                            }
                            Text("Die Daten bleiben in der Aufnahme")
                        }
                    }
                    hiddenChartsFooter
                }

                infoCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(recording.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await playback.load() }
        .onDisappear { playback.pause() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Umbenennen", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Sichern") {
                library.rename(recording, to: draftName)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Aufnahme löschen?", isPresented: $showsDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                library.delete(recording)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Sensordaten und das Video werden entfernt.")
        }
        .overlay {
            if library.isExporting {
                exportOverlay
            }
        }
        .libraryErrorAlert(library)
    }

    @ViewBuilder
    private var hiddenChartsFooter: some View {
        @Bindable var hub = hub
        let hidden = playback.charts.count { !hub.settings.isVisible($0.sensor) }

        if hidden > 0 {
            Button {
                for chart in playback.charts {
                    hub.settings.setVisible(true, for: chart.sensor)
                }
            } label: {
                Label("\(hidden) Diagramm(e) ausgeblendet · einblenden", systemImage: "eye")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }

    private var videoAspectRatio: CGFloat {
        guard let video = recording.video, video.width > 0, video.height > 0 else { return 16.0 / 9 }
        // The file stores landscape dimensions even for a portrait recording; the rotation
        // lives in the track transform, which the player layer already honours.
        return CGFloat(video.width) / CGFloat(video.height)
    }

    private var annotationTimes: [Double] {
        playback.annotations.map { $0.hostTime - recording.startHostTime }
    }

    // MARK: - Transport

    private var transportBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

                Text(Format.timecode(playback.playhead))
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())

                Spacer()

                Text(Format.duration(playback.duration))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { playback.playhead },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...playback.duration
            ) { editing in
                if editing { playback.pause() }
            }
            .tint(Theme.accent)

            HStack(spacing: 8) {
                transportButton("gobackward.5") { playback.step(by: -5) }
                transportButton("minus.magnifyingglass") { playback.zoom(by: 2) }
                transportButton("plus.magnifyingglass") { playback.zoom(by: 0.5) }
                transportButton("goforward.5") { playback.step(by: 5) }

                Spacer()

                if playback.isZoomed {
                    Button("Alles") { playback.resetZoom() }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    Text(Format.duration(playback.visibleRange.upperBound
                                         - playback.visibleRange.lowerBound))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .card()
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote)
                .frame(width: 34, height: 30)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Annotations

    private var annotationStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(playback.annotations) { annotation in
                    Button {
                        playback.pause()
                        playback.seek(to: annotation.hostTime - recording.startHostTime)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.timecode(annotation.hostTime - recording.startHostTime))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.accent)
                            Text(annotation.text)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Info

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            infoRow("Start", recording.startedAt.formatted(date: .abbreviated, time: .standard))
            infoRow("Dauer", Format.duration(recording.duration))
            infoRow("Gerät", recording.device.model)
            infoRow("System", "\(recording.device.systemName) \(recording.device.systemVersion)")
            infoRow("Abtastrate", Format.rate(recording.requestedRateHz))
            infoRow("Messwerte", Format.sampleCount(recording.totalSampleCount))
            infoRow("Grösse", Format.bytes(library.byteSize(of: recording)))

            if let video = recording.video {
                Divider().overlay(Theme.cardBorder)
                infoRow("Video", "\(video.width)×\(video.height) · \(Int(video.nominalFrameRate)) fps")
                infoRow("Versatz", String(format: "%+.3f s",
                                          video.offset(from: recording.startHostTime)))
            }
            if let audio = recording.audio {
                Divider().overlay(Theme.cardBorder)
                infoRow("Audio", "\(Int(audio.sampleRate)) Hz · \(audio.channelCount) Kanäle")
            }

            Divider().overlay(Theme.cardBorder)

            ForEach(recording.streams) { stream in
                HStack {
                    Text(stream.sensor.title)
                        .font(.caption)
                    Spacer()
                    Text("\(Format.sampleCount(stream.sampleCount)) · \(Format.rate(stream.effectiveRateHz))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { shareItem = await library.export(recording, format: .csvBundle)
                        .map(ShareItem.init) }
                } label: {
                    Label("Als CSV exportieren", systemImage: "tablecells")
                }
                Button {
                    Task { shareItem = await library.export(recording, format: .rawBundle)
                        .map(ShareItem.init) }
                } label: {
                    Label("Rohdaten exportieren", systemImage: "shippingbox")
                }
                if recording.video != nil {
                    Button {
                        Task { shareItem = await library.export(recording, format: .sceneBundle)
                            .map(ShareItem.init) }
                    } label: {
                        Label("Als 3D-Szene exportieren", systemImage: "move.3d")
                    }
                }
                Divider()
                Button {
                    Task { shareItem = await library.export(recording, format: .sensorLoggerBundle)
                        .map(ShareItem.init) }
                } label: {
                    Label("Sensor Logger", systemImage: "arrow.triangle.branch")
                }
                if recording.stream(.gyroscope) != nil, recording.video != nil {
                    Button {
                        Task { shareItem = await library.export(recording, format: .gyroflowLog)
                            .map(ShareItem.init) }
                    } label: {
                        Label("Gyroflow-Log", systemImage: "camera.aperture")
                    }
                }
                Divider()
                Button {
                    draftName = recording.name
                    isRenaming = true
                } label: {
                    Label("Umbenennen", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Export läuft …")
                    .font(.footnote)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
    }
}
