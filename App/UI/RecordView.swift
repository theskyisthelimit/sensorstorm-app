import SensorstormCore
import SwiftUI

struct RecordView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(RecordingLibrary.self) private var library

    @State private var annotationText = ""
    @State private var isAddingAnnotation = false
    @State private var showsSavedBanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if hub.settings.isVideoEnabled && hub.isCameraAvailable {
                        cameraPreview
                    }
                    if hub.phase == .recording {
                        annotationRow
                    }
                    liveSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            // Timecode and the record button are pinned rather than scrolled. With the
            // camera on, the preview pushed them off the bottom and the app's primary
            // control ended up behind the tab bar, reachable only by scrolling for it.
            .safeAreaInset(edge: .bottom, spacing: 0) { transportPanel }
            .navigationTitle("Sensorstorm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(activeSensorSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await hub.startMonitoring()
        }
        .alert("Fehler", isPresented: .init(
            get: { hub.errorMessage != nil },
            set: { if !$0 { hub.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { hub.errorMessage = nil }
        } message: {
            Text(hub.errorMessage ?? "")
        }
        .overlay(alignment: .top) { savedBanner }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraPreview: some View {
        Group {
            if hub.usesARKit(for: hub.settings) {
                ARPreviewView(session: hub.poseRecorder.session)
            } else {
                CameraPreviewView(session: hub.videoRecorder.session,
                                  isMirrored: hub.settings.videoMode.isFront)
            }
        }
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            // Capped, or the preview eats the screen and pushes the sensors out of sight.
            .frame(maxHeight: 300)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 16))
            .overlay(alignment: .topLeading) {
                Label(videoLabel, systemImage: "video.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(10)
            }
    }

    /// The shape of the frame that actually gets written, not a convenient box to crop it
    /// into. The classic path rotates its video horizon-level, so held upright it stores a
    /// portrait movie; ARKit stores sensor-native landscape so its intrinsics stay valid.
    /// Showing the wrong one would promise a framing the file does not contain.
    private var previewAspectRatio: CGFloat {
        if hub.usesARKit(for: hub.settings) {
            return 4.0 / 3.0
        }
        let size = hub.settings.videoQuality.pixelSize
        return CGFloat(size.height) / CGFloat(size.width)
    }

    private var videoLabel: String {
        let quality = switch hub.settings.videoQuality {
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4k: "4K"
        }
        if hub.usesARKit(for: hub.settings) {
            return "ARKit · \(quality)"
        }
        let camera = hub.settings.videoMode.isFront
            ? String(localized: "Front")
            : String(localized: "Rück")
        return "\(camera) · \(quality)"
    }

    // MARK: - Transport

    /// Timecode and record button, side by side so the whole thing stays one row high and
    /// leaves the screen to the camera and the sensors.
    private var transportPanel: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.timecode(hub.elapsed))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(hub.phase == .recording ? Theme.recording : .primary)
                    .contentTransition(.numericText())
                    .animation(.default, value: hub.elapsed)

                Text(hub.phase == .recording
                     ? "\(Format.sampleCount(hub.writtenSampleCount)) Messwerte"
                     : String(localized: "Bereit"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            recordButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var activeSensorSummary: String {
        let active = hub.settings.enabledSensors.filter(hub.isAvailable).count
        return "\(active)/\(hub.availableSensors.count)"
    }

    // MARK: - Controls

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 62, height: 62)
                RoundedRectangle(cornerRadius: hub.phase == .recording ? 6 : 25)
                    .fill(Theme.recording)
                    .frame(width: hub.phase == .recording ? 26 : 50,
                           height: hub.phase == .recording ? 26 : 50)
                if hub.phase == .starting || hub.phase == .finishing {
                    ProgressView().tint(.white)
                }
            }
            .animation(.spring(duration: 0.25), value: hub.phase)
        }
        .buttonStyle(.plain)
        .disabled(hub.phase == .starting || hub.phase == .finishing)
        .accessibilityLabel(hub.phase == .recording
                            ? Text("Aufnahme stoppen")
                            : Text("Aufnahme starten"))
    }

    private func toggleRecording() async {
        if hub.phase == .recording {
            let finished = await hub.stopRecording()
            library.refresh()
            if finished != nil {
                withAnimation { showsSavedBanner = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showsSavedBanner = false }
            }
        } else {
            await hub.startRecording()
        }
    }

    // MARK: - Annotations

    private var annotationRow: some View {
        VStack(spacing: 10) {
            Button {
                isAddingAnnotation = true
            } label: {
                Label("Markierung setzen", systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)

            if !hub.annotations.isEmpty {
                Text("\(hub.annotations.count) Markierungen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .alert("Markierung", isPresented: $isAddingAnnotation) {
            TextField("Text", text: $annotationText)
            Button("Sichern") {
                hub.addAnnotation(annotationText)
                annotationText = ""
            }
            Button("Abbrechen", role: .cancel) { annotationText = "" }
        } message: {
            Text("Wird mit dem aktuellen Zeitstempel gespeichert.")
        }
    }

    // MARK: - Live values

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(SensorCategory.allCases, id: \.self) { category in
                let recorded = recordedSensors(in: category)
                if !recorded.isEmpty {
                    categoryGroup(category, recorded: recorded)
                }
            }
            hiddenFooter
        }
    }

    @ViewBuilder
    private func categoryGroup(_ category: SensorCategory,
                               recorded: [SensorID]) -> some View {
        @Bindable var hub = hub
        let shown = recorded.filter { hub.settings.isVisible($0) }
        let collapsed = hub.settings.isCollapsed(category)

        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    hub.settings.setCollapsed(!collapsed, for: category)
                }
            } label: {
                HStack(spacing: 6) {
                    Label(category.title, systemImage: category.symbol)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    if collapsed || shown.count < recorded.count {
                        Text("\(shown.count)/\(recorded.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(collapsed ? Text("Aufklappen") : Text("Zuklappen"))

            if !collapsed, !shown.isEmpty {
                // A category with a single sensor gets the full width; in a two-column grid
                // it would sit in the left half with the right half conspicuously empty.
                if shown.count == 1 {
                    tile(shown[0])
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(shown, id: \.self) { sensor in
                            tile(sensor)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ sensor: SensorID) -> some View {
        @Bindable var hub = hub
        return LiveSensorTile(sensor: sensor, sample: hub.live[sensor])
            .contextMenu {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        hub.settings.setVisible(false, for: sensor)
                    }
                } label: {
                    Label("Ausblenden", systemImage: "eye.slash")
                }
                // Said out loud, because hiding a tile deliberately does *not* stop the
                // recording, and that is the whole point of separating the two.
                Text("Wird weiterhin aufgezeichnet")
            }
    }

    @ViewBuilder
    private var hiddenFooter: some View {
        @Bindable var hub = hub
        let hidden = hub.settings.hiddenCount(among: hub.availableSensors)
        let collapsed = hub.settings.collapsedCategories?.count ?? 0

        if hidden > 0 || collapsed > 0 {
            Button {
                withAnimation(.snappy(duration: 0.2)) { hub.settings.showAllSensors() }
            } label: {
                Label(hidden > 0
                      ? "\(hidden) ausgeblendet · alle einblenden"
                      : "Alle Gruppen aufklappen",
                      systemImage: "eye")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }

    /// Sensors this category is actually recording — the pool the display filter selects from.
    private func recordedSensors(in category: SensorCategory) -> [SensorID] {
        SensorCatalog.descriptors(in: category)
            .map(\.id)
            .filter { hub.settings.isEnabled($0) && hub.isAvailable($0) }
    }

    // MARK: - Banner

    @ViewBuilder
    private var savedBanner: some View {
        if showsSavedBanner {
            Label("Aufnahme gesichert", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// One compact readout: name, live rate, and the channels that matter for this sensor.
struct LiveSensorTile: View {
    let sensor: SensorID
    let sample: LiveSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: sensor.symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(sensor.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            if let sample {
                // A `Grid` rather than stacked `HStack`s with a fixed label width: it lines
                // the two columns up across rows *and* sizes the label column to the longest
                // name in this tile. The fixed 34 pt it replaces fitted "x" and "yaw" but
                // hyphenated "relativeAltitude" across four lines.
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                    ForEach(sensor.highlightChannels, id: \.self) { channel in
                        if sample.values.indices.contains(channel) {
                            GridRow {
                                Text(sensor.descriptor.channels[channel])
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(Format.channelValue(sensor: sensor, channel: channel,
                                                         value: sample.values[channel]))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.color(forChannel: channel))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .gridColumnAlignment(.leading)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.rate(sample.rateHz))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("wartet …")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .card()
    }
}
