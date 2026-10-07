import PresenterCore
import SwiftUI

struct OneOffCaptureSheet: View {
    let controls: ServiceControls

    @Environment(\.dismiss) private var dismiss

    @AppStorage("oneoff.mode") private var modeRaw = "record"
    @AppStorage("oneoff.transport") private var transportRaw = "rtmp"
    @AppStorage("oneoff.url") private var url = ""
    @AppStorage("oneoff.streamKey") private var streamKey = ""
    @AppStorage("oneoff.rung") private var rungID = "1920x1080@30"

    @AppStorage("oneoff.screen") private var screenRaw = ""

    @AppStorage("oneoff.source") private var sourceRaw = "screen"

    @AppStorage("oneoff.sourceFolder") private var sourceFolder = ""
    @AppStorage("oneoff.mediaId") private var mediaId = ""
    @State private var pickingMedia = false

    @AppStorage("broadcast.record.codec") private var codecRaw = "h264"

    @AppStorage("oneoff.audio") private var audioRaw = ""
    @AppStorage("oneoff.audioAddProgram") private var audioAddProgram = false

    @State private var pendingReplace: String?

    private enum Mode: String, CaseIterable {
        case stream, record, both

        var title: String {
            switch self {
            case .stream: "Stream"
            case .record: "Record"
            case .both: "Stream + Record"
            }
        }
    }

    private var mode: Mode { isReplay ? .stream : (Mode(rawValue: modeRaw) ?? .record) }
    private var streams: Bool { mode != .record }
    private var records: Bool { mode != .stream }
    private var transport: StreamTransport {
        StreamTransport(rawValue: transportRaw) ?? .rtmp
    }
    private var rung: StreamQualityRung {
        StreamQualityRung.rungs.first { $0.id == rungID }
            ?? StreamQualityRung.rungs[2]
    }
    private var screens: [(id: String, name: String)] {
        PreviewTargets.screens(controls.render)
    }

    private var isReplay: Bool { sourceRaw != "screen" }
    private var audioSource: StreamAudioSource { StreamAudioSource(storageValue: audioRaw) }
    private var canStart: Bool {
        if streams, url.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if sourceRaw == "media", mediaId.isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture One-Off")
                .font(.system(size: 12, weight: .semibold))
            Picker("", selection: $modeRaw) {
                ForEach(Mode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isReplay)  

            fieldLabel("SOURCE & QUALITY")
            HStack(spacing: 6) {
                menuChip(title: sourceName) {
                    Button("Program Scene") {
                        sourceRaw = "screen"
                        screenRaw = ""
                    }
                    ForEach(screens, id: \.id) { screen in
                        Button(screen.name) {
                            sourceRaw = "screen"
                            screenRaw = screen.id
                        }
                    }
                    Divider()

                    Menu("Latest Recording") {
                        Button("\(RecordingLibrary.defaultFolder) (default)") {
                            sourceRaw = "latest"
                            sourceFolder = ""
                            modeRaw = "stream"
                        }
                        let paths = controls.appModel.folders(in: .media)
                        if !paths.isEmpty {
                            Divider()
                            FolderScopeMenuItems(
                                nodes: FolderTreeLogic.tree(paths: paths),
                                isActive: { sourceRaw == "latest" && sourceFolder == $0 },
                                select: { path in
                                    sourceRaw = "latest"
                                    sourceFolder = path
                                    modeRaw = "stream"
                                })
                        }
                    }
                    Button("Media Item\u{2026}") { pickingMedia = true }
                }
                menuChip(title: rung.label) {
                    ForEach(StreamQualityRung.rungs) { rung in
                        Button(rung.label) { rungID = rung.id }
                    }
                }
                if records {
                    menuChip(title: codecName) {
                        ForEach(Self.codecs, id: \.raw) { codec in
                            Button(codec.name) { codecRaw = codec.raw }
                        }
                    }
                }
            }

            if isReplay, let preview = controls.captureSourcePreview(preset: ephemeralPreset) {
                Text(preview.text)
                    .font(.system(size: 9))
                    .foregroundStyle(preview.isProblem ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }

            if !isReplay {
                fieldLabel("AUDIO")
                HStack(spacing: 6) {
                    menuChip(title: AudioSourceMenuItems.title(ephemeralPreset)) {
                        AudioSourceMenuItems { audioRaw = $0.storageValue }
                    }
                    if audioSource != .program {
                        Toggle("Add Program Audio", isOn: $audioAddProgram)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                            .controlSize(.small)
                    }
                }
            }

            if streams {
                fieldLabel("DESTINATION")
                HStack(spacing: 6) {
                    menuChip(title: transport.rawValue.uppercased()) {
                        ForEach(StreamTransport.allCases, id: \.self) { transport in
                            Button(transport.rawValue.uppercased()) {
                                transportRaw = transport.rawValue
                            }
                        }
                    }
                    field("rtmp://host/app or srt://host:port", text: $url)
                }
                if transport != .srt {
                    field("Stream key", text: $streamKey)
                }
            }

            HStack {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(CardButtonStyle())
                Button("Start") { requestStart() }
                    .buttonStyle(CardButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(16)
        .frame(width: 400)
        .presentationBackground(Color.basePlane)
        .sheet(isPresented: $pickingMedia) {
            LibraryPickerSheet(appModel: controls.appModel) { entry in
                sourceRaw = "media"
                mediaId = entry.id
                modeRaw = "stream"
                pickingMedia = false
            }
        }
        .confirmationDialog(
            "Switch capture?",
            isPresented: Binding(
                get: { pendingReplace != nil },
                set: { if !$0 { pendingReplace = nil } }),
            presenting: pendingReplace
        ) { replacing in
            Button("End \(replacing) & Start One-Off", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: { replacing in
            Text("\(replacing) is on air. Starting the one-off ends it — stream and recording — first.")
        }
    }

    private func requestStart() {

        if streams, let live = controls.streaming.live {
            pendingReplace = live.presetName
        } else {
            start()
        }
    }

    private func start() {
        controls.startCapture(preset: ephemeralPreset)
        dismiss()
    }

    private var ephemeralPreset: StreamRecordPreset {
        let destinations: [StreamPresetDestination] = streams
            ? [StreamPresetDestination(
                id: UUID().uuidString,
                name: "One-Off",
                transport: transport,
                url: url.trimmingCharacters(in: .whitespaces),
                streamKey: transport == .srt || streamKey.isEmpty ? nil : streamKey)]
            : []
        var preset = StreamRecordPreset(
            id: "oneoff-\(UUID().uuidString)",
            name: "One-Off Capture",
            destinations: destinations,
            width: rung.width,
            height: rung.height,
            frameRate: rung.fps,
            videoBitrateKbps: rung.sdrKbps,
            canvasScreenId: screenRaw.isEmpty ? nil : screenRaw,
            recordWhileStreaming: mode == .both ? true : nil,
            recordCodec: records ? codecRaw : nil,
            sourceKind: {
                switch sourceRaw {
                case "latest": .latestRecording
                case "media": .mediaItem
                default: nil
                }
            }(),
            sourceMediaId: sourceRaw == "media" ? mediaId : nil,
            sourceFolder: sourceRaw == "latest" && !sourceFolder.isEmpty
                ? sourceFolder : nil
        )
        if !isReplay {
            audioSource.apply(to: &preset, includingProgram: audioAddProgram)
        }
        return preset
    }

    private var screenName: String {
        screens.first { $0.id == screenRaw }?.name ?? "Program Scene"
    }

    private var sourceName: String {
        switch sourceRaw {
        case "latest":
            let folder = sourceFolder.isEmpty
                ? RecordingLibrary.defaultFolder
                : sourceFolder.split(separator: "/").last.map(String.init) ?? sourceFolder
            return "Latest in \u{201C}\(folder)\u{201D}"
        case "media":
            return controls.appModel.entry(mediaId)?.name ?? "Choose Media\u{2026}"
        default:
            return screenName
        }
    }

    private var footnote: String {
        if isReplay {
            return "A replay ends the stream when the file ends."
        }
        return records
            ? "Recordings save to the media library (\(RecordingLibrary.defaultFolder))."
            : " "
    }

    private static let codecs: [(raw: String, name: String)] = [
        (raw: "h264", name: "H.264"),
        (raw: "hevc", name: "HEVC"),
        (raw: "hevc10", name: "HEVC 10-bit (HDR)"),
        (raw: "proRes422", name: "ProRes 422"),
        (raw: "proRes4444", name: "ProRes 4444 (Alpha)"),
    ]

    private var codecName: String {
        Self.codecs.first { $0.raw == codecRaw }?.name ?? "H.264"
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(6)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
    }

    private func menuChip<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
