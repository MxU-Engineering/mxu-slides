import StreamEngine
import SwiftUI

struct BroadcastStatusChip: View {
    let controls: ServiceControls

    @Environment(\.openSettings) private var openSettings
    @Environment(\.runOnly) private var runOnly

    @State private var showingOneOff = false

    @State private var showingStartList = false

    @State private var pendingStart: PendingStart?

    private struct PendingStart: Identifiable {
        let id: String
        let name: String
        let replacing: String
    }

    var body: some View {
        Menu {
            menuContent
        } label: {

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                chipLabel
            }
        }

        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Stream & Record — stream and recording status")
        .popover(isPresented: $showingStartList, arrowEdge: .bottom) {
            CaptureFromPresetPicker(
                nodes: controls.captureMenuNodes,
                detail: { controls.captureRowDetail(presetID: $0) },
                start: { id, name in
                    showingStartList = false
                    requestStart(id: id, name: name)
                },
                edit: { id in
                    showingStartList = false
                    SettingsRouter.shared.openStreamRecord(tab: .presets, presetID: id)
                    openSettings()
                })
        }
        .sheet(isPresented: $showingOneOff) {
            OneOffCaptureSheet(controls: controls)
        }
        .confirmationDialog(
            "Switch capture?",
            isPresented: Binding(
                get: { pendingStart != nil },
                set: { if !$0 { pendingStart = nil } }),
            presenting: pendingStart
        ) { pending in
            Button("End \(pending.replacing) & Start \(pending.name)", role: .destructive) {
                controls.startCapture(presetID: pending.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("\(pending.replacing) is on air. Starting \(pending.name) ends it — stream and recording — first.")
        }
    }

    private func requestStart(id: String, name: String) {
        if let replacing = controls.startWouldReplace(presetID: id) {
            pendingStart = PendingStart(id: id, name: name, replacing: replacing)
        } else {
            controls.startCapture(presetID: id)
        }
    }

    private var tint: Color? {
        switch controls.streaming.worstTint {
        case .red: return .red
        case .amber: return .orange
        case .green, .none: break
        }
        if controls.recording.anyStoppedAbnormally { return .orange }
        if controls.streaming.isLive || controls.recording.anyRecording {
            return .green
        }

        if controls.streaming.startNotice != nil { return .orange }
        return nil
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {

            Glyph(kind: .broadcast, size: 12)
            if let liveCaption {
                Text(liveCaption)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (tint ?? .primary).opacity(tint == nil ? 0.06 : 0.1),
            in: Capsule()
        )
        .overlay {
            Capsule().strokeBorder(
                Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .contentShape(Capsule())
    }

    private var liveCaption: String? {
        var parts: [String] = []
        if let liveStream = controls.streaming.live {
            let total = Int(Date().timeIntervalSince(liveStream.startedAt))

            switch controls.streaming.worstTint {
            case .amber:

                parts.append(String(
                    format: "%@ %d:%02d", controls.streaming.captionWord,
                    total / 60, total % 60))
            case .red:
                parts.append("STREAM FAILED")
            case .green, .none:

                if let duration = liveStream.mediaDurationSeconds {
                    let remaining = max(0, Int(duration) - total)
                    parts.append(String(
                        format: "REPLAY %d:%02d", remaining / 60, remaining % 60))
                } else {
                    parts.append(String(format: "LIVE %d:%02d", total / 60, total % 60))
                }
            }
        }
        if let session = controls.recording.sessions.first(where: \.isRecording) {
            let total = Int(session.status.elapsedSeconds)
            parts.append(String(format: "REC %d:%02d", total / 60, total % 60))
            if controls.recording.sessions.filter(\.isRecording).count > 1 {
                parts[0] += " +\(controls.recording.sessions.filter(\.isRecording).count - 1)"
            }
        }
        if controls.recording.anyStoppedAbnormally { parts.append("stopped") }
        if parts.isEmpty, controls.streaming.startNotice != nil {
            parts.append("NOT STARTED")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{B7} ")
    }

    @ViewBuilder
    private var menuContent: some View {
        let liveStream = controls.streaming.live
        let presetRunning = liveStream.map {
            controls.runningCount(presetID: $0.presetID)
        } ?? 0
        let hasStopItems = liveStream != nil || !controls.recording.sessions.isEmpty

        let notice = controls.streaming.startNotice
        if liveStream != nil || notice != nil
            || controls.recording.sessions.contains(where: \.isRecording) {
            Section("Status") {
                if let liveStream {
                    ForEach(liveStream.sessions, id: \.destination.id) { session in
                        Text(healthLine(session))
                    }
                }

                if let notice {
                    Text(notice)
                }
                ForEach(controls.recording.sessions) { session in
                    if session.isRecording {
                        Text(Self.recordingHealthLine(session))
                    }
                }
            }
        }

        if !runOnly, let liveStream, presetRunning > 1 {
            Section {
                Button("End All — \(liveStream.presetName)") {
                    controls.endAll(presetID: liveStream.presetID)
                }
            }
        }

        if hasStopItems {
            stopRows(liveStream: liveStream, headered: !runOnly && presetRunning > 1)
                .onAppear { controls.recording.reapFinished() }
        }

        if !runOnly {
            if hasStopItems { Divider() }

            Button("Capture from Preset\u{2026}") { showingStartList = true }
            Button("One-Time Capture\u{2026}") { showingOneOff = true }
            Divider()

            Button("Stream & Record Settings\u{2026}") { openStreamSettings() }
        }
    }

    @ViewBuilder
    private func stopRows(
        liveStream: StreamingController.LiveStream?, headered: Bool
    ) -> some View {

        Section(headered ? "End one at a time" : "") {
            if let liveStream {
                if runOnly {
                    Text("Streaming — \(liveStream.presetName)")
                } else {
                    Button("End Stream — \(liveStream.presetName)") {
                        controls.streaming.endStream()
                    }
                }
            }
            ForEach(controls.recording.sessions) { session in
                if session.isRecording {
                    if runOnly {
                        Text("Recording \(session.targetName)")
                    } else {
                        Button("Stop Recording — \(session.targetName)") {
                            controls.recording.stop(session)
                        }
                    }
                } else {
                    Button("Dismiss stopped recording — \(session.targetName)") {
                        controls.recording.dismiss(session)
                    }
                }
            }
        }
    }

    private func healthLine(_ session: StreamSession) -> String {
        let status = session.status
        let state: String
        switch status.state {
        case .publishing: state = "Live"
        case .connecting: state = "Connecting\u{2026}"
        case .reconnecting(let attempt): state = "Reconnecting (try \(attempt))"
        case .failed(let reason): state = "Failed \u{2014} \(reason)"
        case .idle, .stopped: state = "Stopped"
        }
        var parts = ["\(session.destination.name) \u{2014} \(state)"]
        if status.framesDropped > 0 {
            parts.append("\(status.framesDropped) dropped")
        }
        return parts.joined(separator: " \u{B7} ")
    }

    private static func recordingHealthLine(_ session: RecordingController.Session) -> String {
        let status = session.status
        var parts = ["\(session.targetName) \u{2014} Recording"]

        if status.freeDiskBytes != .max {
            parts.append(ByteCountFormatter.string(
                fromByteCount: status.freeDiskBytes, countStyle: .file) + " free")
        }
        if status.droppedFrames > 0 {
            parts.append("\(status.droppedFrames) dropped")
        }
        return parts.joined(separator: " \u{B7} ")
    }

    private func openStreamSettings() {
        SettingsRouter.shared.openStreamRecord(tab: .presets)
        openSettings()
    }
}

private struct CaptureFromPresetPicker: View {
    let nodes: [ServiceControls.CaptureMenuNode]
    let detail: (String) -> ServiceControls.CaptureRowDetail?
    let start: (String, String) -> Void
    let edit: (String) -> Void

    @AppStorage("capture.lastPresetID") private var lastPresetID = ""

    @State private var selectedID: String?
    @State private var expandedID: String?

    private var flatPresets: [(id: String, name: String, goesLive: Bool)] {
        nodes.flatMap { node -> [(id: String, name: String, goesLive: Bool)] in
            switch node {
            case .preset(let id, let name, let goesLive): [(id, name, goesLive)]
            case .folder(_, _, let presets): presets
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capture from Preset")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            if nodes.isEmpty {
                Text("No presets yet — create one in Stream & Record Settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                            switch node {
                            case .preset(let id, let name, let goesLive):
                                row(id: id, name: name, goesLive: goesLive)
                            case .folder(_, let folderName, let presets):
                                Text(folderName.uppercased())
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .tracking(0.5)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 6)
                                ForEach(presets, id: \.id) { preset in
                                    row(id: preset.id, name: preset.name, goesLive: preset.goesLive)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                Divider()
                footer
            }
        }
        .padding(8)
        .frame(width: 400)
        .onAppear {
            let ids = flatPresets.map(\.id)

            selectedID = ids.contains(lastPresetID) ? lastPresetID : nil
        }
    }

    private func row(id: String, name: String, goesLive: Bool) -> some View {
        let selected = selectedID == id
        let expanded = expandedID == id
        let detail = expanded ? detail(id) : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    expandedID = expanded ? nil : id
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what this preset does")
                Button {
                    selectedID = id
                } label: {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 11, weight: selected ? .medium : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if expanded {
                            Button("Edit\u{2026}") { edit(id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                        } else if !goesLive {
                            Text("Record only")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let detail {
                VStack(alignment: .leading, spacing: 2) {
                    if !detail.isRecordOnly { detailRow("Streams to", detail.streamsTo) }
                    detailRow("Video Source", detail.videoSource)
                    detailRow("Audio Source", detail.audioSource)
                    detailRow("Encoder", detail.encoder)
                    detailRow("Recording", detail.recording)
                    if let warning = detail.warning {
                        Text(warning)
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .padding(.leading, 14)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            selected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            Text(value)
                .font(.system(size: 9))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let selected = selectedID.flatMap { id in flatPresets.first { $0.id == id } }
        HStack(spacing: 8) {
            Spacer()
            Button {
                guard let selected else { return }
                lastPresetID = selected.id
                start(selected.id, selected.name)
            } label: {
                Text(selected?.goesLive == false ? "\u{25CF} Record" : "\u{25B6} Go Live")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        selected == nil ? Color.secondary : Color.accentColor,
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selected == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 2)
    }
}
