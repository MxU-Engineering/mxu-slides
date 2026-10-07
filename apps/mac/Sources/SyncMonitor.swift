import AVFoundation
import AudioEngine
import MediaEngine
import OutputEngine
import PresenterCore
import QuartzCore
import RenderEngine
import SwiftUI

@MainActor
@Observable
final class SyncMonitorPlayer {
    let displayLayer = AVSampleBufferDisplayLayer()

    private(set) var problem: String?

    private(set) var status = Status()

    struct Status: Equatable {
        var pictureFPS = 0
        var soundArriving = false

        var reanchors = 0
        var soundFormat = ""
        var peakDecibels = -90.0
        var soundSource = ""
        var delayMs = 0

        var mixBacklogMs: Int?
        var output = ""

        var rendererError: String?

        var syncTest: SyncTestReader.Verdict?
    }

    @ObservationIgnored private let audioRenderer = AVSampleBufferAudioRenderer()
    @ObservationIgnored private let synchronizer = AVSampleBufferRenderSynchronizer()
    @ObservationIgnored private var mirror: OutputMirror?
    @ObservationIgnored private var audioFeed: SessionAudioFeed?
    @ObservationIgnored private let render: RenderContext
    @ObservationIgnored private let meter = SyncMonitorMeter()

    @ObservationIgnored private let reader = Locked(SyncTestReader())

    @ObservationIgnored private let gainDecibels = Locked(0.0)
    @ObservationIgnored private let audioQueue = DispatchQueue(
        label: "syncMonitor.audio", qos: .userInitiated)
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var delayTask: Task<Void, Never>?
    @ObservationIgnored private var outputName = "System Default"
    @ObservationIgnored private var lastReadingAt: CFTimeInterval?

    @ObservationIgnored weak var model: AppModel?

    init(render: RenderContext) {
        self.render = render
        displayLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    func start(preset: StreamRecordPreset) {
        stop()
        let screenID = preset.canvasScreenId.flatMap { $0.isEmpty ? nil : $0 }
            ?? PreviewTargets.screens(render).first?.id
        let frameRate = preset.frameRate ?? 30
        let size = SyncMonitorSamples.renderSize(
            width: preset.width ?? 1920, height: preset.height ?? 1080)
        let videoRenderer = RendererBox(renderer: displayLayer.sampleBufferRenderer)
        let meter = meter
        let reader = reader
        reader.value = SyncTestReader()
        let mirror = screenID.flatMap { screenID in
            OutputMirror(
                compositor: render.compositor,
                width: size.width, height: size.height,
                framesPerSecond: frameRate,
                provider: render.outputs.previewProvider(for: screenID),
                consumerHeldFrames: SyncMonitorSamples.heldFrames(framesPerSecond: frameRate),
                sink: { buffer, hostSeconds in
                    if let sample = SyncMonitorSamples.video(buffer, hostSeconds: hostSeconds) {
                        videoRenderer.renderer.enqueue(sample)
                        meter.videoFrame()
                    }
                    if let lumas = SyncTestReader.gridLuma(buffer) {
                        reader.value.picture(hostSeconds: hostSeconds, lumas: lumas)
                    }
                })
        }
        if let mirror {
            self.mirror = mirror
            mirror.start()
            openAudio(preset: preset)
            synchronizer.setRate(
                1, time: SyncMonitorSamples.clockTime(atHostSeconds: CACurrentMediaTime()),
                atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
            problem = nil
            DiagnosticsStore.shared.note(
                "syncMonitor.start",
                detail: "\(preset.name) sound=\(Self.soundSource(of: preset)) "
                    + "delay=\(preset.audioDelayMs ?? 0)ms out=\(outputName)")
            watchStatus(presetID: preset.id)
        } else {
            problem = "This preset has no screen to show."
        }
    }

    private func watchStatus(presetID: String) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let self, !Task.isCancelled {
                    tick += 1
                    self.readStatus(presetID: presetID, log: tick % 5 == 0)
                }
            }
        }
    }

    private func readStatus(presetID: String, log: Bool) {
        let reading = meter.drain()
        let now = CACurrentMediaTime()
        let elapsed = max(0.001, now - (lastReadingAt ?? now - 1))
        lastReadingAt = now
        let preset = try? model?.streamPreset(presetID)
        let failed = [audioRenderer.error, displayLayer.sampleBufferRenderer.error]
            .compactMap { $0?.localizedDescription }.first
        status = Status(
            pictureFPS: Int((Double(reading.videoFrames) / elapsed).rounded()),
            soundArriving: reading.audioBuffers > 0,
            reanchors: reading.audioReanchors,
            soundFormat: reading.audioBuffers > 0
                ? "\(Int(reading.sampleRate / 1000)) kHz, \(reading.channels) ch" : "",
            peakDecibels: reading.peakDecibels,
            soundSource: preset.map(Self.soundSource(of:)) ?? "",
            delayMs: preset?.audioDelayMs ?? 0,
            mixBacklogMs: (preset?.audioMixId).flatMap {
                AudioMixerController.current?.feedBacklogMilliseconds(mixId: $0)
            }.map { Int($0) },
            output: outputName,
            rendererError: failed,
            syncTest: reader.value.verdict)
        if log {
            DiagnosticsStore.shared.note(
                "syncMonitor.status",
                detail: "picture \(status.pictureFPS)fps | sound "
                    + "\(Int((Double(reading.audioBuffers) / elapsed).rounded()))buf/s "
                    + "reanchors \(reading.audioReanchors) "
                    + "\(status.soundFormat) peak \(Int(reading.peakDecibels))dB "
                    + "| source=\(status.soundSource) delay=\(status.delayMs)ms "
                    + (status.mixBacklogMs.map { "mixBacklog=\($0)ms " } ?? "") + "out=\(outputName)"
                    + (status.syncTest.map { " | syncTest sound \(Int($0.offsetMs.rounded()))ms vs picture (\($0.pairs))" } ?? "")
                    + (failed.map { " | renderer failed: \($0)" } ?? ""))
        }
    }

    static func soundSource(of preset: StreamRecordPreset) -> String {
        let program = (preset.audioIncludesProgram ?? false) ? " + Program Audio" : ""
        if let mixId = preset.audioMixId, !mixId.isEmpty {
            return "mix \(AudioMixInventory.shared.entry(id: mixId)?.name ?? mixId)" + program
        } else if let inputId = preset.audioInputId, !inputId.isEmpty {
            return "input \(AudioInputInventory.shared.name(forId: inputId) ?? inputId)" + program
        } else if let uid = preset.audioInputUid, !uid.isEmpty {
            return "device \(uid)" + program
        } else {
            return "Program Audio"
        }
    }

    func setVolume(decibels: Double) {
        gainDecibels.value = decibels
    }

    func setOutputDevice(uid: String?, name: String) {
        outputName = name
        setOutputDevice(uid: uid)
    }

    func setOutputDevice(uid: String?) {

        SyncMonitorSamples.route(
            audioRenderer, toDeviceUID: uid ?? AudioDeviceList.defaultOutputDevice()?.uid)
    }

    func audioDelayChanged(preset: StreamRecordPreset) {

        delayTask?.cancel()
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if let self, !Task.isCancelled, self.mirror != nil {
                self.audioFeed?.close()

                let renderer = RendererBox(renderer: self.audioRenderer)
                self.audioQueue.async { renderer.renderer.flush() }
                self.reader.value = SyncTestReader()
                self.openAudio(preset: preset)
                DiagnosticsStore.shared.note(
                    "syncMonitor.audioDelay", detail: "\(preset.audioDelayMs ?? 0)ms, feed reopened")
            }
        }
    }

    func stop() {
        if mirror != nil { DiagnosticsStore.shared.note("syncMonitor.stop", detail: "") }
        statusTask?.cancel()
        statusTask = nil
        delayTask?.cancel()
        delayTask = nil
        lastReadingAt = nil
        mirror?.stop()
        mirror = nil
        audioFeed?.close()
        audioFeed = nil
        synchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
        displayLayer.sampleBufferRenderer.flush()
    }

    private func openAudio(preset: StreamRecordPreset) {
        let audioRenderer = RendererBox(renderer: audioRenderer)
        let meter = meter
        let queue = audioQueue

        let state = Locked(AudioPlayState())
        let gainDecibels = gainDecibels
        let reader = reader
        let play: @Sendable (AVAudioPCMBuffer, Double) -> Void = { buffer, hostSeconds in
            let rate = buffer.format.sampleRate

            meter.audio(buffer)

            let (stamp, overlaps, restarted) = state.withLock { state in
                let stamp = state.timeline.stamp(
                    hostSeconds: hostSeconds, frameCount: Int(buffer.frameLength), sampleRate: rate)

                let overlaps = stamp.reanchored && stamp.seconds < state.queuedUntil
                let restarted = stamp.reanchored && state.started
                state.started = true
                state.queuedUntil = stamp.seconds + Double(buffer.frameLength) / rate
                return (stamp, overlaps, restarted)
            }

            if let data = buffer.floatChannelData {
                let channels = Int(buffer.format.channelCount)
                let samples = (0..<Int(buffer.frameLength)).map { data[0][$0 * channels] }
                reader.value.sound(startSeconds: stamp.seconds, samples: samples, sampleRate: rate)
            }
            SyncMonitorSamples.applyGain(buffer, decibels: gainDecibels.value)

            let time = CMTime(
                value: CMTimeValue((stamp.seconds * rate).rounded()), timescale: CMTimeScale(rate))
            if let sample = Recorder.sampleBuffer(from: buffer, presentationTime: time) {
                if overlaps { audioRenderer.renderer.flush() }
                if restarted { meter.audioReanchored() }
                audioRenderer.renderer.enqueue(sample)
            }
        }
        audioFeed = SessionAudioFeed.open(
            audioMixId: preset.audioMixId,
            audioInputId: preset.audioInputId,
            audioInputUid: preset.audioInputUid,
            includeProgram: preset.audioIncludesProgram ?? false,
            delayMilliseconds: preset.audioDelayMs ?? 0
        ) { buffer, _, hostSeconds in

            if let playable = SyncMonitorSamples.interleaved(buffer) {
                let handoff = PlayableAudio(buffer: playable)
                queue.async { play(handoff.buffer, hostSeconds) }
            }
        }
    }
}

private struct PlayableAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private struct AudioPlayState: Sendable {
    var timeline = SyncMonitorAudioTimeline()
    var started = false

    var queuedUntil = -Double.infinity
}

private struct RendererBox<Renderer: AVQueuedSampleBufferRendering>: @unchecked Sendable {
    let renderer: Renderer
}

private struct SyncMonitorPicture: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct SyncMonitorReadout: View {
    let status: SyncMonitorPlayer.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(soundLine)
                    .foregroundStyle(status.soundArriving ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                Spacer(minLength: 0)
                ProgressView(value: max(0, min(1, (status.peakDecibels + 60) / 60)))
                    .frame(width: 120)
            }
            Text(secondLine.text)
                .foregroundStyle(secondLine.problem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .font(.callout.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var soundLine: String {
        status.soundArriving
            ? "Picture \(status.pictureFPS) fps \u{B7} Sound: \(status.soundSource) \u{B7} \(status.soundFormat) \u{B7} \(status.delayMs) ms delay \u{B7} on \(status.output)"
            : "Picture \(status.pictureFPS) fps \u{B7} Sound: nothing is arriving from \(status.soundSource.isEmpty ? "this preset\u{2019}s audio source" : status.soundSource)"
    }

    private var secondLine: (text: String, problem: Bool) {
        if let error = status.rendererError {
            ("Playback failed: \(error)", true)
        } else if status.reanchors > 0 {
            ("Sound restarted \(status.reanchors)\u{D7} in the last second", true)
        } else if let verdict = status.syncTest {
            (String(
                format: verdict.offsetMs < 0
                    ? "Sync Test here: sound %.0f ms AHEAD of picture (%d downbeats)"
                    : "Sync Test here: sound %.0f ms BEHIND picture (%d downbeats)",
                abs(verdict.offsetMs), verdict.pairs), false)
        } else {
            (" ", false)
        }
    }
}

struct SyncMonitorSheet: View {
    let model: AppModel
    let controls: ServiceControls
    let presetID: String
    @State private var player: SyncMonitorPlayer

    @State private var takesOverDevice = true

    @State private var liveHold = false

    @State private var outputs: [AudioOutputDevice] = []

    @AppStorage("syncMonitor.outputUID") private var outputUID = ""

    private let pictureSize: CGSize = (NSScreen.main?.visibleFrame.height ?? 1080) >= 950
        ? CGSize(width: 960, height: 540) : CGSize(width: 640, height: 360)

    @AppStorage("syncMonitor.volumeDecibels") private var volumeDecibels = 12.0
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, controls: ServiceControls, presetID: String) {
        self.model = model
        self.controls = controls
        self.presetID = presetID
        _player = State(initialValue: SyncMonitorPlayer(render: controls.render))
    }

    private var preset: StreamRecordPreset? { try? model.streamPreset(presetID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            SyncMonitorPicture(layer: player.displayLayer)
                .frame(width: pictureSize.width, height: pictureSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let problem = player.problem {
                Text(problem).foregroundStyle(.secondary)
            }
            SyncMonitorReadout(status: player.status)
            Picker("Listen on", selection: $outputUID) {
                Text("System Default").tag("")
                ForEach(outputs) { Text($0.name).tag($0.uid) }
                if !outputUID.isEmpty, !outputs.contains(where: { $0.uid == outputUID }) {
                    Text("Not connected").tag(outputUID)
                }
            }
            if liveHold {
                Text("A stream, recording or service is running, so MxU Slides\u{2019} other audio on this device keeps playing. What you hear here may not be this window\u{2019}s sound alone \u{2014} watch the level meter.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Silence MxU Slides\u{2019} other audio on this device while this window is open", isOn: $takesOverDevice)
            }
            syncTestRow
            HStack {
                Text("Volume")
                Slider(value: $volumeDecibels, in: SyncMonitorSamples.gainRange)
                Text(String(format: "%+.0f dB", volumeDecibels))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            HStack {
                Text("Audio delay")
                Spacer()
                TextField("", value: delayBinding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("ms").foregroundStyle(.secondary)
                Stepper("", value: delayBinding, in: 0...2000, step: 5).labelsHidden()
            }
            Text("This is the preset's picture and sound as its stream and recording will hold them, played \(SyncMonitorSamples.lagDescription) behind live \u{2014} so compare the picture here with the sound here, never with the room. Sound before the picture: raise Audio delay. Listen on wired headphones or speakers \u{2014} Bluetooth adds a delay of its own. Listen on only chooses where this window plays; the stream's audio is untouched. Pick headphones or speakers you listen on \u{2014} never an output that feeds your stream (a DAW or switcher return), or this window\u{2019}s sound loops back into the mix it is playing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: pictureSize.width + 40)
        .onAppear {
            player.model = model
            liveHold = controls.streaming.isLive
                || controls.recording.sessions.contains { $0.isRecording }
            applyOutput()
            if let preset { player.start(preset: preset) }
        }
        .onChange(of: takesOverDevice) { applyOutput() }
        .onChange(of: volumeDecibels, initial: true) { player.setVolume(decibels: volumeDecibels) }
        .task {
            outputs = await Task.detached(priority: .userInitiated) { AudioDeviceList.outputDevices() }.value
        }
        .onChange(of: outputUID) { applyOutput() }
        .onChange(of: outputs) { applyOutput() }
        .onDisappear {
            player.stop()
            controls.mixer.setMonitorTakeover(deviceUID: nil, active: false)
        }
        .onChange(of: preset?.audioDelayMs) {
            if let preset { player.audioDelayChanged(preset: preset) }
        }
    }

    private var presetScreen: PlaceholderScreen? {
        preset?.canvasScreenId.flatMap(UUID.init(uuidString:)).flatMap { id in
            controls.render.outputs.placeholderScreens.first { $0.id == id }
        }
    }

    private var syncTestRow: some View {
        HStack(spacing: 10) {
            if let screen = presetScreen {
                Toggle(
                    "Show \(SyncTestPattern.name) on \(screen.name)",
                    isOn: Binding(
                        get: { controls.render.outputs.syncTestScreens.contains(screen.id) },
                        set: { controls.render.outputs.setSyncTest($0, forScreen: screen.id) }))
                Text("\(SyncTestPattern.beatsPerMinute) BPM: a click and a flash every beat, the circle fills each bar")
                    .foregroundStyle(.secondary)
            } else {
                Text("Turn on \(SyncTestPattern.name) for a screen in Outputs and show it through this preset.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(height: 24)
    }

    private func applyOutput() {
        let remembered = outputs.first { $0.uid == outputUID }
        if outputUID.isEmpty {
            player.setOutputDevice(uid: nil, name: "System Default")
            controls.mixer.setMonitorTakeover(deviceUID: nil, active: takesOverDevice && !liveHold)
        } else if let remembered {
            player.setOutputDevice(uid: remembered.uid, name: remembered.name)
            controls.mixer.setMonitorTakeover(deviceUID: remembered.uid, active: takesOverDevice && !liveHold)
        } else if !outputs.isEmpty {
            player.setOutputDevice(uid: nil, name: "System Default (chosen output not connected)")
            controls.mixer.setMonitorTakeover(deviceUID: nil, active: takesOverDevice && !liveHold)
        }
    }

    private var delayBinding: Binding<Int> {
        Binding(
            get: { preset?.audioDelayMs ?? 0 },
            set: { value in
                model.updateStreamPreset(presetID) {
                    $0.audioDelayMs = value == 0 ? nil : min(max(value, 0), 2000)
                }
            })
    }
}
