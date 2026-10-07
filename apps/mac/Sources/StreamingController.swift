import Foundation
import Observation
import os
import OutputEngine
import PresenterCore
import RenderEngine
import StreamEngine

@MainActor
@Observable
final class StreamingController {
    struct LiveStream: Identifiable {
        let id = UUID()
        let presetID: String
        let presetName: String
        let sessions: [StreamSession]

        let mirrors: [OutputMirror]

        let fileSource: MediaFileSource?

        let mediaDurationSeconds: Double?
        let audioFeed: SessionAudioFeed?
        let startedAt: Date
    }

    private(set) var live: LiveStream? {
        didSet { onLiveChanged?() }
    }

    var onLiveChanged: (() -> Void)?

    private(set) var startNotice: String?
    private let render: RenderContext

    enum ResolvedSource {
        case screen
        case file(
            url: URL, name: String, inPoint: Double?, outPoint: Double?,
            durationSeconds: Double?)
        case unavailable(String)
    }
    var sourceResolver: ((StreamRecordPreset) -> ResolvedSource)?

    init(render: RenderContext) {
        self.render = render
    }

    var isLive: Bool { live != nil }

    var worstTint: StreamTint { StreamHealthRollup.tint(rollupInputs) }

    var captionWord: String { StreamHealthRollup.word(rollupInputs) }

    private var rollupInputs: [StreamHealthRollup.Input] {
        guard let live else { return [] }
        return live.sessions.map { session in
            StreamHealthRollup.Input(state: session.status.state, verdict: nil)
        }
    }

    typealias StreamTint = StreamHealthRollup.Tint

    func startCapture(
        preset: StreamRecordPreset, destinations: [StreamPresetDestination],
        recording: RecordingController
    ) {

        startNotice = nil
        if preset.isRecordOnly {
            startRecordOnly(preset: preset, recording: recording)
        } else {
            goLive(preset: preset, destinations: destinations, recording: recording)
        }
    }

    private func startRecordOnly(preset: StreamRecordPreset, recording: RecordingController) {

        guard (preset.sourceKind ?? .screen) == .screen else {
            DiagnosticsStore.shared.note(
                "stream.source",
                detail: "\(preset.name): record-only preset needs a screen source")
            return
        }
        let width = preset.width ?? 1920
        let height = preset.height ?? 1080
        let frameRate = preset.frameRate ?? 30
        let screenID: String
        if let chosen = preset.canvasScreenId, !chosen.isEmpty {
            screenID = chosen
        } else if let first = PreviewTargets.screens(render).first?.id {
            screenID = first
        } else {
            return
        }
        let codec = RecordingConfiguration.Codec(rawValue: preset.recordCodec ?? "") ?? .h264
        try? recording.start(
            targetID: screenID,
            targetName: preset.name,
            codec: codec,
            width: width, height: height, frameRate: frameRate,
            audioMixId: preset.audioMixId,
            audioInputId: preset.audioInputId,
            audioInputUid: preset.audioInputUid,
            audioIncludesProgram: preset.audioIncludesProgram ?? false,
            audioDelayMs: preset.audioDelayMs ?? 0,
            presetID: preset.id,
            libraryFolder: preset.recordLibraryFolder ?? RecordingLibrary.defaultFolder,
            exportFolder: preset.recordExportFolder)
    }

    func goLive(
        preset: StreamRecordPreset, destinations: [StreamPresetDestination],
        recording: RecordingController
    ) {

        let source = sourceResolver?(preset) ?? .screen
        if case .unavailable(let reason) = source {
            startNotice = "\(preset.name): \(reason)"
            DiagnosticsStore.shared.note(
                "stream.source.unavailable", detail: "\(preset.name): \(reason)")
            return
        }

        if let refusal = StreamDestinationReadiness.startRefusal(kind: .stream, destinations: destinations) {
            let sentence = "\(preset.name) \u{2014} \(refusal)"
            startNotice = sentence
            DiagnosticsStore.shared.note("stream.destination.refused", detail: sentence)
            Self.log.warning("\(sentence, privacy: .public)")
            return
        }

        let outgoing = live?.presetID
        endStream()
        if let outgoing {
            recording.stopAll(presetID: outgoing)
        }

        startSessions(
            preset: preset, recording: recording, source: source,
            plans: destinations.map(Self.sessionPlan))
    }

    private struct SessionPlan {
        var destination: StreamEndpoint
        var codec: StreamVideoConfiguration.Codec
        var maxHeight: Int?
        var maxBitrateKbps: Int?
        var hdr: Bool

        var canvasScreenId: String?
        var width: Int?
        var height: Int?
        var frameRate: Int?
    }

    private static func sessionPlan(_ destination: StreamPresetDestination) -> SessionPlan {
        SessionPlan(
            destination: StreamEndpoint(
                id: destination.id,
                name: destination.name,
                kind: kind(for: destination.transport),
                url: destination.url,
                streamKey: destination.streamKey ?? ""),
            codec: codec(for: destination),
            maxHeight: destination.maxHeight,
            maxBitrateKbps: nil,
            hdr: hdr(for: destination),
            canvasScreenId: destination.canvasScreenId,
            width: destination.width,
            height: destination.height,
            frameRate: destination.frameRate)
    }

    private static func hdr(for destination: StreamPresetDestination) -> Bool {

        destination.hdr == true && destination.transport == .hls && destination.videoCodec == .hevc
    }

    private static func codec(for destination: StreamPresetDestination) -> StreamVideoConfiguration.Codec {

        destination.videoCodec == .hevc && destination.transport == .hls ? .hevc : .h264
    }

    private func startSessions(
        preset: StreamRecordPreset, recording: RecordingController,
        source: ResolvedSource = .screen,
        plans rawPlans: [SessionPlan]
    ) {
        let presetWidth = preset.width ?? 1920
        let presetHeight = preset.height ?? 1080
        let presetFrameRate = preset.frameRate ?? 30
        let presetBitrate = preset.videoBitrateKbps ?? 4500
        let isFileSource: Bool = {
            if case .file = source { return true }
            return false
        }()

        let plans: [SessionPlan] = isFileSource
            ? rawPlans.map { plan in
                var plan = plan
                plan.hdr = false
                return plan
            }
            : rawPlans

        let defaultScreenID: String
        if isFileSource {
            defaultScreenID = ""
        } else if let chosen = preset.canvasScreenId, !chosen.isEmpty {
            defaultScreenID = chosen
        } else if let first = PreviewTargets.screens(render).first?.id {
            defaultScreenID = first
        } else {
            return
        }

        struct ResolvedSession {
            var session: StreamSession
            var screenID: String
            var width: Int
            var height: Int
            var frameRate: Int
            var hdr: Bool
        }
        let resolved: [ResolvedSession] = plans.map { plan in
            let overridden = plan.width != nil || plan.height != nil
            var sessionWidth = plan.width ?? presetWidth
            var sessionHeight = plan.height ?? presetHeight
            let sessionRate = plan.frameRate ?? presetFrameRate
            var sessionBitrate: Int
            if overridden {
                sessionBitrate = StreamQualityRung.recommendedKbps(
                    width: sessionWidth, height: sessionHeight,
                    fps: sessionRate, hdr: plan.hdr)
                    ?? max(2000, presetBitrate * (sessionWidth * sessionHeight) / (presetWidth * presetHeight))
            } else {
                sessionBitrate = presetBitrate
            }
            if let cap = plan.maxHeight, cap < sessionHeight {
                let scale = Double(cap) / Double(sessionHeight)
                sessionWidth = max(2, Int((Double(sessionWidth) * scale).rounded())) & ~1
                let unscaledPixels = (plan.width ?? presetWidth) * (plan.height ?? presetHeight)
                sessionBitrate = max(2000, sessionBitrate * (sessionWidth * cap) / unscaledPixels)
                sessionHeight = cap
            }
            if let bitrateCap = plan.maxBitrateKbps {
                sessionBitrate = min(sessionBitrate, bitrateCap)
            }
            return ResolvedSession(
                session: StreamSession(
                    destination: plan.destination,
                    video: StreamVideoConfiguration(
                        width: sessionWidth, height: sessionHeight,
                        frameRate: sessionRate, bitrateKbps: sessionBitrate,
                        codec: plan.codec, hdr: plan.hdr)),
                screenID: plan.canvasScreenId?.isEmpty == false ? plan.canvasScreenId! : defaultScreenID,
                width: sessionWidth, height: sessionHeight,
                frameRate: sessionRate, hdr: plan.hdr)
        }
        let sessions = resolved.map(\.session)
        guard !sessions.isEmpty else { return }
        sessions.forEach { $0.start() }

        var fileSource: MediaFileSource?
        var mediaDurationSeconds: Double?
        if case .file(let url, let name, let inPoint, let outPoint, let duration) = source {
            mediaDurationSeconds = duration
            let box = Locked<MediaFileSource?>(nil)
            let presetName = preset.name
            let pump = MediaFileSource(
                url: url, inPoint: inPoint, outPoint: outPoint,
                frameSink: { pixelBuffer, hostSeconds in
                    for session in sessions {
                        session.append(pixelBuffer, atHostSeconds: hostSeconds)
                    }
                },
                audioSink: { buffer, when in
                    for session in sessions {
                        session.appendAudio(buffer, when: when)
                    }
                },
                onEnded: { [weak self] reason in
                    Task { @MainActor in
                        guard let self, let ended = box.value,
                              self.live?.fileSource === ended else { return }
                        DiagnosticsStore.shared.note(
                            "stream.mediaEnded",
                            detail: "\(name): \(reason ?? "end of media") — ending stream")
                        if let reason {
                            self.startNotice = "\(presetName): \(reason)"
                        }
                        self.endStream()
                    }
                })
            box.value = pump
            pump.start()
            fileSource = pump
        }

        var mirrors: [OutputMirror] = []
        let groups = isFileSource ? [:] : Dictionary(grouping: resolved, by: \.screenID)
        for (screenID, group) in groups {
            let mirrorWidth = group.map(\.width).max() ?? presetWidth
            let mirrorHeight = group.map(\.height).max() ?? presetHeight
            let mirrorRate = group.map(\.frameRate).max() ?? presetFrameRate
            let color: PixelBufferConverter.Color =
                group.contains(where: \.hdr) ? .hlg2020 : .sdr
            let groupSessions = group.map(\.session)
            guard let mirror = OutputMirror(
                compositor: render.compositor,
                width: mirrorWidth, height: mirrorHeight, framesPerSecond: mirrorRate,
                color: color,
                provider: render.outputs.previewProvider(for: screenID),
                sink: { pixelBuffer, hostSeconds in

                    for session in groupSessions {
                        session.append(pixelBuffer, atHostSeconds: hostSeconds)
                    }
                }
            ) else {
                sessions.forEach { $0.stop() }
                mirrors.forEach { $0.stop() }
                return
            }
            mirrors.append(mirror)
        }
        mirrors.forEach { $0.start() }
        let screenID = defaultScreenID
        let width = presetWidth
        let height = presetHeight
        let frameRate = presetFrameRate

        if preset.recordWhileStreaming == true, !isFileSource {
            let codec = RecordingConfiguration.Codec(
                rawValue: preset.recordCodec ?? "") ?? .h264
            try? recording.start(
                targetID: screenID,
                targetName: preset.name,
                codec: codec,
                width: width, height: height, frameRate: frameRate,
                audioMixId: preset.audioMixId,
                audioInputId: preset.audioInputId,
                audioInputUid: preset.audioInputUid,
                audioIncludesProgram: preset.audioIncludesProgram ?? false,
                audioDelayMs: preset.audioDelayMs ?? 0,
                presetID: preset.id,
                libraryFolder: preset.recordLibraryFolder ?? RecordingLibrary.defaultFolder,
                exportFolder: preset.recordExportFolder)
        }

        let audioFeed: SessionAudioFeed? = isFileSource ? nil : SessionAudioFeed.open(
            audioMixId: preset.audioMixId,
            audioInputId: preset.audioInputId,
            audioInputUid: preset.audioInputUid,
            includeProgram: preset.audioIncludesProgram ?? false,
            delayMilliseconds: preset.audioDelayMs ?? 0
        ) { buffer, when, _ in
            for session in sessions {
                session.appendAudio(buffer, when: when)
            }
        }

        live = LiveStream(
            presetID: preset.id, presetName: preset.name,
            sessions: sessions, mirrors: mirrors, fileSource: fileSource,
            mediaDurationSeconds: mediaDurationSeconds,
            audioFeed: audioFeed,
            startedAt: Date())

        let liveID = live?.id
        Task { [weak self] in
            while let self, let live = self.live, live.id == liveID {
                for session in live.sessions {
                    let status = session.status
                    let mirrorDelivered = live.mirrors.reduce(0) { $0 + $1.framesDelivered }
                    let mirrorDropped = live.mirrors.reduce(0) { $0 + $1.framesDropped }
                    Self.log.info("heartbeat: \(session.destination.name, privacy: .public) state=\(String(describing: status.state), privacy: .public) submitted=\(status.framesSubmitted) dropped=\(status.framesDropped) mirrorDelivered=\(mirrorDelivered) mirrorDropped=\(mirrorDropped)")
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private static let log = Logger(
        subsystem: "com.example.mxuslides", category: "stream")

    func endStream() {

        startNotice = nil
        guard let live else { return }
        live.mirrors.forEach { $0.stop() }
        live.fileSource?.stop()
        live.audioFeed?.close()
        live.sessions.forEach { $0.stop() }
        self.live = nil
    }

    private static func kind(for transport: StreamTransport) -> StreamEndpoint.Kind {
        switch transport {
        case .rtmp: .rtmp
        case .rtmps: .rtmps
        case .srt: .srt
        case .hls: .hls
        }
    }
}
