import AVFoundation
import Foundation
import MediaEngine
import NDIKit
import Observation
import PresenterCore
import QuartzCore
import RenderEngine
import SlideScene

@MainActor
@Observable
final class ServiceControls {
    private(set) var state = ShowState()

    let appModel: AppModel

    let render: RenderContext
    private let blobs: BlobStore?

    let audio: AudioController

    let timers: TimersController

    let media: MediaTransportController

    let recording: RecordingController

    let streaming: StreamingController

    let mixer: AudioMixerController

    private var liveMediaIDs: Set<String> = []

    private var transitionResweepScheduled = false

    init(appModel: AppModel, render: RenderContext) {
        self.appModel = appModel
        self.render = render
        self.blobs = try? BlobStore(libraryRoot: appModel.client.rootURL)
        self.audio = AudioController(appModel: appModel, media: render.media)
        self.timers = TimersController(render: render)
        self.timers.moveUndo = appModel.moveUndo
        self.media = MediaTransportController(appModel: appModel, render: render)
        self.recording = RecordingController(render: render)
        self.streaming = StreamingController(render: render)
        self.mixer = AudioMixerController(audio: audio)

        appModel.decks.onFillLanded = { [weak self] id in
            self?.presentationFillDidLand(id)
        }

        NDIScreenOutputs.shared.restore(render: render)
        DeckLinkScreenOutputs.shared.restore(render: render)

        VideoInputInventory.shared.warmUp(render: render)

        AudioInputInventory.shared.warmUp()

        mixer.syncPlaythroughs()

        recording.libraryAdoption = RecordingController.LibraryAdoption(
            spoolFolder: RecordingLibrary.spoolDirectory(
                libraryRoot: appModel.client.rootURL),
            adopt: { [weak appModel] url, folder, exportFolder, startedAt, presetID in
                guard let appModel else { return }
                Task { @MainActor in
                    do {
                        _ = try await RecordingLibrary.adopt(
                            fileURL: url, client: appModel.client,
                            folder: folder, recordedAt: startedAt,
                            presetId: presetID,
                            alsoCopyTo: exportFolder.flatMap {
                                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
                            })

                        appModel.noteExternalMutation(of: .media)
                    } catch {
                        DiagnosticsStore.shared.note(
                            "recording.adopt.failed",
                            detail: "\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            })

        streaming.sourceResolver = { [weak self] preset in
            guard let self else { return .unavailable("library unavailable") }
            return self.resolveStreamSource(preset)
        }
        audio.onTransportChanged = { [weak self] in self?.pushAudioVisibility() }
        recording.onSessionsChanged = { [weak self] in self?.pushCaptureVisibility() }
        streaming.onLiveChanged = { [weak self] in self?.pushCaptureVisibility() }
        VideoInputInventory.shared.onConnectedChanged = { [weak self] connected in
            self?.pushConnectedInputVisibility(connected)
        }
    }

    private func pushAudioVisibility() {
        let now = Date()
        var wanted: VideoCountdown?
        if let transport = audio.nowPlayingTransport {
            wanted = VideoCountdown(
                name: transport.name, duration: transport.duration,
                position: transport.elapsed, anchoredAt: now,
                isPlaying: transport.isPlaying
            )
        }
        let current = render.confidenceInfo.audioCountdown
        if let wanted, let current,
           wanted.name == current.name,
           wanted.duration == current.duration,
           wanted.isPlaying == current.isPlaying,
           abs(current.remaining(at: now) - wanted.remaining(at: now)) < 0.3 {
            return 
        }
        if wanted == nil && current == nil { return }
        var info = render.confidenceInfo
        info.audioCountdown = wanted
        render.confidenceInfo = info
    }

    private func pushCaptureVisibility() {
        let active = recording.anyRecording || streaming.live != nil
        guard render.confidenceInfo.captureActive != active else { return }
        var info = render.confidenceInfo
        info.captureActive = active
        render.confidenceInfo = info
    }

    private func pushLiveInputVisibility(_ ids: Set<String>) {
        let sorted = ids.sorted()
        guard render.confidenceInfo.activeLiveInputIds != sorted else { return }
        var info = render.confidenceInfo
        info.activeLiveInputIds = sorted
        render.confidenceInfo = info
    }

    private func pushConnectedInputVisibility(_ connected: [String]) {
        guard render.confidenceInfo.connectedLiveInputIds != connected else { return }
        var info = render.confidenceInfo
        info.connectedLiveInputIds = connected
        render.confidenceInfo = info
    }

    private func resolveStreamSource(_ preset: StreamRecordPreset) -> StreamingController.ResolvedSource {
        switch resolveSourceItem(preset) {
        case nil:
            return .screen
        case .failure(let problem):
            return .unavailable(problem.reason)
        case .success(let item):
            return fileSource(item)
        }
    }

    private func resolveSourceItem(_ preset: StreamRecordPreset) -> Result<MediaItem, StreamSourceProblem>? {
        switch preset.sourceKind ?? .screen {
        case .screen:
            return nil
        case .mediaItem:
            guard let id = preset.sourceMediaId,
                  let item = appModel.media(id) else {
                return .failure(.init("media item not found in the library"))
            }
            return .success(item)
        case .latestRecording:
            let folder = preset.sourceFolder ?? RecordingLibrary.defaultFolder
            let items = appModel.resident.media.values

            let cutoff = preset.sourceMaxAgeHours.map {
                Date().addingTimeInterval(-Double($0) * 3600)
            }
            if let item = RecordingLibrary.latestRecording(
                in: items, folder: folder, notBefore: cutoff) {
                return .success(item)
            }
            if cutoff != nil,
               let stale = RecordingLibrary.latestRecording(in: items, folder: folder) {
                return .failure(.init(
                    "newest recording in \u{201C}\(folder)\u{201D} is "
                        + Self.ageText(stale.recordedAt ?? 0)
                        + " old — over the \(preset.sourceMaxAgeHours ?? 0)h limit"))
            }
            return .failure(.init("no finished recording in \u{201C}\(folder)\u{201D}"))
        }
    }

    struct StreamSourceProblem: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private static func ageText(_ recordedAt: Double) -> String {
        let hours = Int(Date().timeIntervalSince1970 - recordedAt) / 3600
        if hours < 1 { return "under an hour" }
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24) days"
    }

    struct CaptureSourcePreview {
        let text: String
        let isProblem: Bool
    }

    func captureSourcePreview(presetID: String) -> CaptureSourcePreview? {
        guard let preset = try? appModel.streamPreset(presetID) else { return nil }
        return captureSourcePreview(preset: preset)
    }

    func captureSourcePreview(preset: StreamRecordPreset) -> CaptureSourcePreview? {

        let destinations = resolvedDestinations(for: preset)
        if let refusal = StreamDestinationReadiness.startRefusal(kind: preset.resolvedKind, destinations: destinations) {
            return CaptureSourcePreview(text: refusal, isProblem: true)
        }
        let skipped = StreamDestinationReadiness.problems(destinations)
        if !skipped.isEmpty {
            return CaptureSourcePreview(
                text: "Will skip \u{2014} " + skipped.joined(separator: " \u{B7} "),
                isProblem: true)
        }
        switch resolveSourceItem(preset) {
        case nil:
            return nil
        case .failure(let problem):
            return CaptureSourcePreview(
                text: "Won't go live: \(problem.reason)", isProblem: true)
        case .success(let item):
            if case .unavailable(let reason) = fileSource(item) {
                return CaptureSourcePreview(
                    text: "Won't go live: \(reason)", isProblem: true)
            }
            var text = "Restreams \u{201C}\(item.name)\u{201D}"
            if let recordedAt = item.recordedAt {
                text += " \u{B7} recorded \(Self.ageText(recordedAt)) ago"
            }
            return CaptureSourcePreview(text: text, isProblem: false)
        }
    }

    struct CaptureRowDetail {
        var streamsTo: String
        var videoSource: String
        var audioSource: String
        var encoder: String
        var recording: String
        var warning: String?
        var isRecordOnly: Bool
    }

    func captureRowDetail(presetID: String) -> CaptureRowDetail? {
        guard let preset = try? appModel.streamPreset(presetID) else { return nil }
        let destinations = resolvedDestinations(for: preset)
        let names = destinations.map(\.name)
        let video: String
        switch preset.sourceKind ?? .screen {
        case .screen:
            let screen = preset.canvasScreenId.flatMap { id in
                PreviewTargets.screens(render).first { $0.id == id }?.name
            } ?? "Automatic"
            video = "Screen \u{B7} \(screen)"
        case .mediaItem:
            video = "Media file \u{B7} " + (preset.sourceMediaId.flatMap { appModel.entry($0)?.name } ?? "none chosen")
        case .latestRecording:
            video = "Latest recording \u{B7} \(preset.sourceFolder ?? RecordingLibrary.defaultFolder)"
        }
        var audio = AudioSourceMenuItems.title(preset)
        if preset.audioIncludesProgram == true, audio != "Program Audio" { audio += " + Program Audio" }
        if (preset.sourceKind ?? .screen) != .screen { audio = "From the file" }
        let width = preset.width ?? 1920, height = preset.height ?? 1080
        var encoder = "\(min(width, height))p \u{B7} \(preset.frameRate ?? 30) fps"
        if let kbps = preset.videoBitrateKbps { encoder += " \u{B7} \(kbps >= 1000 ? String(format: "%.1f", Double(kbps) / 1000) + " Mbps" : "\(kbps) kbps")" }
        let recording: String
        if preset.isRecordOnly || preset.recordWhileStreaming == true {
            let folder = preset.recordLibraryFolder ?? RecordingLibrary.defaultFolder
            recording = (preset.sourceKind ?? .screen) == .screen ? "\(folder) folder" : "not while restreaming"
        } else {
            recording = "Off"
        }
        return CaptureRowDetail(
            streamsTo: preset.isRecordOnly ? "\u{2014}" : (names.isEmpty ? "no destinations selected" : names.joined(separator: ", ")),
            videoSource: video,
            audioSource: audio,
            encoder: encoder,
            recording: recording,
            warning: captureSourcePreview(preset: preset).flatMap { $0.isProblem ? $0.text : nil },
            isRecordOnly: preset.isRecordOnly)
    }

    private func fileSource(_ item: MediaItem) -> StreamingController.ResolvedSource {
        guard item.mediaKind == .video else {
            return .unavailable("\u{201C}\(item.name)\u{201D} isn't a video")
        }
        guard item.fileStatus == .ready else {
            return .unavailable("\u{201C}\(item.name)\u{201D} isn't ready to play")
        }
        guard let url = blobs?.url(forHash: item.fileHash) else {
            return .unavailable("\u{201C}\(item.name)\u{201D}: file isn't on this Mac")
        }

        let duration = item.durationSeconds.map { full in
            max(0, min(item.outPoint ?? full, full) - max(item.inPoint ?? 0, 0))
        }
        return .file(
            url: url, name: item.name,
            inPoint: item.inPoint, outPoint: item.outPoint,
            durationSeconds: duration)
    }

    enum CaptureMenuNode {
        case preset(id: String, name: String, goesLive: Bool)
        case folder(id: String, name: String, presets: [(id: String, name: String, goesLive: Bool)])
    }

    var captureMenuNodes: [CaptureMenuNode] {

        let info = Dictionary(
            appModel.streamPresets.compactMap { entry -> (String, (name: String, goesLive: Bool))? in
                guard let preset = try? appModel.streamPreset(entry.id) else { return nil }
                return (entry.id, (name: preset.name, goesLive: !preset.isRecordOnly))
            },
            uniquingKeysWith: { first, _ in first })
        let board = appModel.streamBoard
        return board.nodes.compactMap { nodeID in
            if let folder = board.folder(id: nodeID) {
                let presets = folder.itemIds.compactMap { id in
                    info[id].map { (id: id, name: $0.name, goesLive: $0.goesLive) }
                }
                return presets.isEmpty
                    ? nil
                    : .folder(id: nodeID, name: folder.name, presets: presets)
            }
            return info[nodeID].map {
                .preset(id: nodeID, name: $0.name, goesLive: $0.goesLive)
            }
        }
    }

    func startCapture(presetID: String) {
        guard let preset = try? appModel.streamPreset(presetID) else { return }
        startCapture(preset: preset)
    }

    func startCapture(preset: StreamRecordPreset) {
        streaming.startCapture(
            preset: preset,
            destinations: resolvedDestinations(for: preset),
            recording: recording)
    }

    func resolvedDestinations(for preset: StreamRecordPreset) -> [StreamPresetDestination] {
        guard preset.resolvedKind == .stream else { return [] }
        var out = preset.destinations
        for id in preset.destinationIds ?? [] {
            guard let destination = appModel.resolvedStreamDestination(id) else {
                DiagnosticsStore.shared.note(
                    "stream.destination.dangling",
                    detail: "\(preset.name): destination \(id) no longer exists — skipped")
                continue
            }
            out.append(StreamDestinationLibrary.sessionDestination(
                destination, displayName: StreamDestinationLibrary.displayName(destination)))
        }
        return out
    }

    func startWouldReplace(presetID: String) -> String? {
        guard let live = streaming.live else { return nil }
        guard let target = try? appModel.streamPreset(presetID),
              !target.isRecordOnly
        else { return nil }
        return live.presetName
    }

    func runningCount(presetID: String) -> Int {
        var count = streaming.live?.presetID == presetID ? 1 : 0
        count += recording.sessions.filter {
            $0.presetID == presetID && $0.isRecording
        }.count
        return count
    }

    func endAllCapture() {
        streaming.endStream()
        for session in recording.sessions where session.isRecording {
            recording.stop(session)
        }
    }

    func endAll(presetID: String) {
        if streaming.live?.presetID == presetID {
            streaming.endStream()
        }
        for session in recording.sessions where session.presetID == presetID {
            recording.stop(session)
        }
    }

    private(set) var liveContextID: String?
    private(set) var liveOccurrence: Int?

    private(set) var keyboardFires = 0

    func noteKeyboardFire() {
        keyboardFires += 1
    }

    weak var actionRouter: ActionRouter?

    weak var signage: SignageController?

    weak var serviceTracking: ServiceTimingController?

    private(set) var mediaFireContexts: [String: String] = [:]

    func fire(
        slide: Slide, in presentation: Presentation, arrangementId: String? = nil,
        contextID: String? = nil, occurrence: Int? = nil
    ) {

        settlePending()
        let incoming = actionRouter?.predictedOverrideThemes(for: slide, contextID: contextID) ?? Array(slideThemeOverrides.values)
        let handoff = state.handoff(to: slide, incomingOverrides: incoming)
        if handoff.wait > 0 {
            state.dismissLooks(handoff.leaving, atHostTime: CACurrentMediaTime())
            apply()
            let settled = nextFireArrivesSettled
            pendingHandoff = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(handoff.wait))
                guard let self, !Task.isCancelled else { return }
                self.pendingHandoff = nil
                self.nextFireArrivesSettled = settled
                defer { self.nextFireArrivesSettled = false }
                self.fire(slide: slide, in: presentation, arrangementId: arrangementId, contextID: contextID, occurrence: occurrence)
            }
            return
        }

        let themeID = presentation.themeId(for: slide)
        switch appModel.resident.themes.fireRead(themeID) {
        case .now(let theme):
            land(slide: slide, in: presentation, theme: theme, arrangementId: arrangementId, contextID: contextID, occurrence: occurrence)
        case .afterFill:
            let settled = nextFireArrivesSettled
            pendingHandoff = Task { @MainActor [weak self] in
                await self?.appModel.themesFilled([themeID])
                if let self, !Task.isCancelled {
                    self.pendingHandoff = nil
                    self.nextFireArrivesSettled = settled
                    self.land(
                        slide: slide, in: presentation, theme: self.appModel.theme(themeID),
                        arrangementId: arrangementId, contextID: contextID, occurrence: occurrence)
                    self.nextFireArrivesSettled = false
                }
            }
        }
    }

    private func land(
        slide: Slide, in presentation: Presentation, theme: Theme?, arrangementId: String?,
        contextID: String?, occurrence: Int?
    ) {

        actionRouter?.applyPresetSwitches(for: slide, contextID: contextID)

        if let own = RenderContext.sceneTransition(from: slide.transition) {
            render.nextLiveTransitions[.slide] = own
        }
        let deckWasLive = livePresentationID == presentation.id
        state.fire(
            slide: slide, presentation: presentation,
            theme: theme, arrangementId: arrangementId,

            atHostTime: CACurrentMediaTime(),

            arrivesSettled: nextFireArrivesSettled
        )
        liveContextID = contextID
        liveOccurrence = occurrence

        serviceTracking?.noteItemFired(serviceItemID: contextID)
        refreshNextSlide()
        apply()

        for object in slide.objects.map(SlideObjectNormalization.normalized) {
            if let id = SlideSceneBuilder.fillMediaID(object),
               !resolvedLoops(override: object.fill?.loops, mediaID: id) {
                restart(mediaID: id)
            }
        }

        if let background = SlideSceneBuilder.effectiveBackground(
            slide: slide, presentation: presentation, arrangementId: arrangementId
        ), SlideSceneBuilder.layerKind(background.layer) == .videos,
           !resolvedLoops(override: background.loops, mediaID: background.mediaId),
           let transport = render.media.transport(id: background.mediaId),
           MediaTransportController.isFinished(transport, at: Date()) {
            restart(mediaID: background.mediaId)
        }

        actionRouter?.slideDidFire(slide, contextID: contextID)
        armAutoAdvance(for: slide, in: presentation)

        if !deckWasLive {
            appModel.markUsed(presentation.id)
        }
    }

    func advance(steps: Int, settled: Bool = false, otherwise fireSlide: () throws -> Void) rethrows {
        guard steps != 0 else { return }
        if settled, steps > 0 {
            nextFireArrivesSettled = true
            defer { nextFireArrivesSettled = false }
            try fireSlide()
            return
        }
        if steps > 0 {
            if state.advanceStep(atHostTime: CACurrentMediaTime()) {
                apply()
                syncAutoAdvanceArming()
                return
            }
        } else if state.unadvanceStep() {
            apply()
            syncAutoAdvanceArming()
            return
        }
        try fireSlide()
    }

    private var nextFireArrivesSettled = false

    private var pendingHandoff: Task<Void, Never>?

    private var pendingSwitch: (() -> Void)?

    private func settlePending() {
        pendingHandoff?.cancel()
        pendingHandoff = nil
        if let activate = pendingSwitch {
            pendingSwitch = nil
            activate()
        }
    }

    func switchPreset(incomingOverrides: [Theme], activate: @escaping () -> Void) {
        settlePending()
        let change = state.lookSwitch(to: incomingOverrides)
        guard change.wait > 0 else {
            activate()
            return
        }
        state.dismissLooks(change.leaving, atHostTime: CACurrentMediaTime())
        apply()
        pendingSwitch = activate
        pendingHandoff = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(change.wait))
            guard let self, !Task.isCancelled else { return }
            self.pendingHandoff = nil
            if let activate = self.pendingSwitch {
                self.pendingSwitch = nil
                activate()
            }
        }
    }

    var slideAnimationStep: (consumed: Int, total: Int)? { state.slideAnimationStep }

    private var exitSweep: Timer?

    private func syncExitSweep() {
        let needsSweep = state.hasPendingExits
        if needsSweep, exitSweep == nil {
            let clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.state.sweepFinishedExits(now: CACurrentMediaTime()) {
                        self.exitLanded()
                    }
                    if !self.state.hasPendingExits {
                        self.exitSweep?.invalidate()
                        self.exitSweep = nil
                    }
                }
            }
            RunLoop.main.add(clock, forMode: .common)
            exitSweep = clock
        } else if !needsSweep, let clock = exitSweep {
            clock.invalidate()
            exitSweep = nil
        }
    }

    private func exitLanded() {
        if state.liveSlide == nil, liveContextID != nil {
            liveContextID = nil
            liveOccurrence = nil
            cancelAutoAdvance()
            refreshNextSlide()
        }
        apply()
        syncFlashClock()
    }

    private var autoAdvanceTimer: Timer?

    private var autoAdvancePoll: Timer?
    private var autoAdvanceWatch: (slideID: String, mediaID: String, armedAt: Date)?

    private static let autoAdvanceWatchGraceSeconds: Double = 10

    struct AutoAdvancePending: Equatable {

        var firesAt: Date?

        var mediaID: String?

        var delaySeconds: Double = 0
    }
    private(set) var autoAdvancePending: AutoAdvancePending?

    private(set) var autoAdvancePaused = false
    private var autoAdvanceHeldRemaining: TimeInterval?

    private enum AdvanceTimedContext {
        case slide(String)
        case mediaItem(serviceItemID: String, mediaID: String)
    }
    private var advanceTimedContext: AdvanceTimedContext?

    func autoAdvanceRemaining(at date: Date = Date()) -> TimeInterval? {
        guard let pending = autoAdvancePending else { return nil }
        if autoAdvancePaused, let held = autoAdvanceHeldRemaining { return held }
        if let firesAt = pending.firesAt { return max(firesAt.timeIntervalSince(date), 0) }
        if let mediaID = pending.mediaID,
           let transport = render.media.transport(id: mediaID), transport.duration > 0 {
            let remaining = (transport.duration - transport.position(at: date))
                / max(transport.rate, 0.01)
            return max(remaining + pending.delaySeconds, 0)
        }
        return nil
    }

    func setAutoAdvancePaused(_ paused: Bool) {
        guard paused != autoAdvancePaused, autoAdvancePending != nil else { return }
        autoAdvancePaused = paused
        if paused {
            if let timer = autoAdvanceTimer ?? mediaAdvanceTimer {
                autoAdvanceHeldRemaining = max(timer.fireDate.timeIntervalSinceNow, 0)
            }
            autoAdvanceTimer?.invalidate()
            autoAdvanceTimer = nil
            mediaAdvanceTimer?.invalidate()
            mediaAdvanceTimer = nil

        } else if let held = autoAdvanceHeldRemaining {
            autoAdvanceHeldRemaining = nil
            switch advanceTimedContext {
            case .slide(let slideID):
                scheduleAutoAdvanceDelay(held, from: slideID)
            case .mediaItem(let serviceItemID, let mediaID):
                scheduleMediaAdvanceDelay(held, from: serviceItemID, mediaID: mediaID)
            case nil:
                break
            }
        }
    }

    private func clearAdvanceVisibility() {
        autoAdvancePending = nil
        autoAdvancePaused = false
        autoAdvanceHeldRemaining = nil
        advanceTimedContext = nil
    }

    private func cancelAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
        autoAdvancePoll?.invalidate()
        autoAdvancePoll = nil
        autoAdvanceWatch = nil
        autoAdvanceArmTimer?.invalidate()
        autoAdvanceArmTimer = nil
        autoAdvanceAwaitingSteps = nil
        clearAdvanceVisibility()
    }

    private var autoAdvanceAwaitingSteps: String?

    private var autoAdvanceArmTimer: Timer?

    private func syncAutoAdvanceArming() {
        guard let waitingID = autoAdvanceAwaitingSteps ?? advanceTimedContextSlideID,
              let live = state.liveSlide, live.slide.id == waitingID,
              state.slideAdvanceCount > 0,
              SlideSceneBuilder.effectiveAutoAdvance(
                  slide: live.slide, presentation: live.presentation
              ) != nil
        else { return }
        autoAdvanceArmTimer?.invalidate()
        autoAdvanceArmTimer = nil
        guard let completedAt = state.slideStepsCompletedAt() else {

            autoAdvanceTimer?.invalidate()
            autoAdvanceTimer = nil
            autoAdvancePoll?.invalidate()
            autoAdvancePoll = nil
            autoAdvanceWatch = nil
            clearAdvanceVisibility()
            autoAdvanceAwaitingSteps = live.slide.id
            return
        }
        autoAdvanceAwaitingSteps = nil
        let remaining = completedAt - CACurrentMediaTime()
        if remaining <= 0 {
            armAutoAdvanceTimers(for: live.slide, in: live.presentation)
            return
        }
        let slideID = live.slide.id
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let live = self.state.liveSlide,
                      live.slide.id == slideID,
                      self.state.slideStepsCompletedAt() != nil else { return }
                self.autoAdvanceArmTimer = nil
                self.armAutoAdvanceTimers(for: live.slide, in: live.presentation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoAdvanceArmTimer = timer
    }

    private var advanceTimedContextSlideID: String? {
        if case .slide(let id) = advanceTimedContext { return id }
        return nil
    }

    private func armAutoAdvance(for slide: Slide, in presentation: Presentation?) {
        cancelAutoAdvance()

        cancelMediaAdvance()

        guard SlideSceneBuilder.effectiveAutoAdvance(
            slide: slide, presentation: presentation
        ) != nil else { return }

        if state.slideAdvanceCount > 0 {
            autoAdvanceAwaitingSteps = slide.id
            return
        }
        armAutoAdvanceTimers(for: slide, in: presentation)
    }

    private func armAutoAdvanceTimers(for slide: Slide, in presentation: Presentation?) {
        guard let advance = SlideSceneBuilder.effectiveAutoAdvance(
            slide: slide, presentation: presentation
        ) else { return }
        if advance.afterPlayback ?? false, let mediaID = autoAdvanceMediaID(for: slide) {
            autoAdvanceWatch = (slide.id, mediaID, Date())
            autoAdvancePending = AutoAdvancePending(
                mediaID: mediaID, delaySeconds: advance.delaySeconds
            )

            let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoAdvancePollTick() }
            }
            RunLoop.main.add(poll, forMode: .common)
            autoAdvancePoll = poll
            return
        }

        scheduleAutoAdvanceDelay(advance.delaySeconds, from: slide.id)
    }

    private func scheduleAutoAdvanceDelay(_ seconds: Double, from slideID: String) {

        let delay = max(seconds, 0.1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fireAutoAdvance(from: slideID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoAdvanceTimer = timer
        autoAdvancePending = AutoAdvancePending(firesAt: Date().addingTimeInterval(delay))
        advanceTimedContext = .slide(slideID)
    }

    private func autoAdvanceMediaID(for slide: Slide) -> String? {
        if let background = slide.background, !background.mediaId.isEmpty,
           isForegroundVideo(background) {
            return background.mediaId
        }

        for object in slide.objects {
            guard let id = SlideSceneBuilder.fillMediaID(object),
                  let item = appModel.media(id),
                  item.mediaKind == .video
            else { continue }
            return id
        }
        return nil
    }

    private func isForegroundVideo(_ media: CueMedia) -> Bool {
        if let layer = media.layer { return layer == .videos }
        guard let item = appModel.media(media.mediaId)
        else { return false }
        return item.mediaKind == .video && item.classification != .background
    }

    private func autoAdvancePollTick() {
        guard let watch = autoAdvanceWatch,
              let live = state.liveSlide, live.slide.id == watch.slideID,
              let advance = SlideSceneBuilder.effectiveAutoAdvance(
                slide: live.slide, presentation: live.presentation)
        else { return cancelAutoAdvance() }
        let now = Date()
        let lead = MediaAutoAdvance.leadSeconds(fromDelay: advance.delaySeconds)
        if let transport = render.media.transport(id: watch.mediaID) {
            let ended: Bool
            if lead > 0, !transport.isLooping, transport.duration > 0 {

                let remaining = (transport.duration - transport.position(at: now))
                    / max(transport.rate, 0.01)
                ended = MediaAutoAdvance.shouldPreFire(
                    remainingWallClock: remaining, delay: advance.delaySeconds
                )
            } else {

                ended = MediaTransportController.isFinished(transport, at: now)
                    || (transport.isLooping && transport.duration > 0
                        && now.timeIntervalSince(watch.armedAt) >= transport.duration - lead)
            }
            guard ended else { return }
        } else {
            guard now.timeIntervalSince(watch.armedAt) > Self.autoAdvanceWatchGraceSeconds
            else { return }
        }

        if autoAdvancePaused { return cancelAutoAdvance() }
        autoAdvancePoll?.invalidate()
        autoAdvancePoll = nil
        autoAdvanceWatch = nil
        if advance.delaySeconds <= 0 {

            fireAutoAdvance(from: watch.slideID)
        } else {
            scheduleAutoAdvanceDelay(advance.delaySeconds, from: watch.slideID)
        }
    }

    private func fireAutoAdvance(from slideID: String) {
        autoAdvanceTimer = nil
        clearAdvanceVisibility()

        guard let live = state.liveSlide, live.slide.id == slideID,
              let presentation = live.presentation
        else { return }

        if state.slideAdvanceCount > 0, state.slideStepsCompletedAt() == nil {
            autoAdvanceAwaitingSteps = slideID
            return
        }
        let slides = SlideSceneBuilder.arrangedSlides(
            for: presentation, arrangementId: live.arrangementId
        )

        guard let current = liveOccurrence ?? slides.firstIndex(where: { $0.id == slideID })
        else { return }
        if let next = SlideSceneBuilder.autoAdvanceTarget(
            occurrence: current, count: slides.count,
            loopToStart: SlideSceneBuilder.effectiveAutoAdvance(
                slide: live.slide, presentation: presentation)?.loopToStart ?? false
        ), slides.indices.contains(next) {
            fire(
                slide: slides[next], in: presentation, arrangementId: live.arrangementId,
                contextID: liveContextID, occurrence: next
            )
            return
        }

        guard let contextID = liveContextID,
              let serviceID = appModel.currentServiceID,
              let service = try? appModel.service(serviceID),
              let itemIndex = service.items.firstIndex(where: { $0.id == contextID })
        else { return }
        fireNextServiceItem(after: contextID, in: service)
    }

    private func fireNextServiceItem(after itemID: String, in service: Service) {

        guard let next = ServiceRunOrder.nextFireable(in: appModel.fireableItems(service), after: itemID)
        else { return }
        switch fireServiceItem(next) {
        case .fired, .decoding:
            return
        case .unresolvable:
            fireNextServiceItem(after: next.id, in: service)
        }
    }

    enum ServiceItemFireResult {
        case fired

        case decoding

        case unresolvable
    }

    @discardableResult
    func fireServiceItem(_ item: ServiceItem) -> ServiceItemFireResult {
        switch item.itemKind {
        case .presentation:
            guard let presentation = appModel.presentation(item.refId) else { return .decoding }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: item.arrangementId
            )
            guard let first = slides.first else { return .unresolvable }
            fire(
                slide: first, in: presentation, arrangementId: item.arrangementId,
                contextID: item.id, occurrence: 0
            )
            return .fired
        case .media:
            guard let media = appModel.media(item.refId) else { return .unresolvable }
            fire(mediaItem: media, context: .serviceItem(id: item.id))
            return .fired
        default:
            return .unresolvable
        }
    }

    private var mediaAdvanceTimer: Timer?
    private var mediaAdvancePoll: Timer?
    private var mediaAdvanceWatch: (serviceItemID: String, mediaID: String, armedAt: Date)?

    private func cancelMediaAdvance() {
        mediaAdvanceTimer?.invalidate()
        mediaAdvanceTimer = nil
        mediaAdvancePoll?.invalidate()
        mediaAdvancePoll = nil
        mediaAdvanceWatch = nil
        clearAdvanceVisibility()
    }

    private func armMediaAdvance(for item: MediaItem, serviceItemID: String) {
        cancelMediaAdvance()
        guard let advance = item.autoAdvance else { return }
        if advance.afterPlayback ?? false, item.mediaKind == .video {
            mediaAdvanceWatch = (serviceItemID, item.id, Date())
            autoAdvancePending = AutoAdvancePending(
                mediaID: item.id, delaySeconds: advance.delaySeconds
            )
            let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaAdvancePollTick() }
            }
            RunLoop.main.add(poll, forMode: .common)
            mediaAdvancePoll = poll
            return
        }

        scheduleMediaAdvanceDelay(advance.delaySeconds, from: serviceItemID, mediaID: item.id)
    }

    private func scheduleMediaAdvanceDelay(_ seconds: Double, from serviceItemID: String, mediaID: String) {
        let delay = max(seconds, 0.1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fireMediaAdvance(from: serviceItemID, mediaID: mediaID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        mediaAdvanceTimer = timer
        autoAdvancePending = AutoAdvancePending(firesAt: Date().addingTimeInterval(delay))
        advanceTimedContext = .mediaItem(serviceItemID: serviceItemID, mediaID: mediaID)
    }

    private func mediaAdvancePollTick() {
        guard let watch = mediaAdvanceWatch,
              isMediaLive(watch.mediaID),
              let advance = appModel.media(watch.mediaID)?.autoAdvance
        else { return cancelMediaAdvance() }
        let now = Date()
        let lead = MediaAutoAdvance.leadSeconds(fromDelay: advance.delaySeconds)
        if let transport = render.media.transport(id: watch.mediaID) {
            let ended: Bool
            if lead > 0, !transport.isLooping, transport.duration > 0 {

                let remaining = (transport.duration - transport.position(at: now))
                    / max(transport.rate, 0.01)
                ended = MediaAutoAdvance.shouldPreFire(
                    remainingWallClock: remaining, delay: advance.delaySeconds
                )
            } else {

                ended = MediaTransportController.isFinished(transport, at: now)
                    || (transport.isLooping && transport.duration > 0
                        && now.timeIntervalSince(watch.armedAt) >= transport.duration - lead)
            }
            guard ended else { return }
        } else {
            guard now.timeIntervalSince(watch.armedAt) > Self.autoAdvanceWatchGraceSeconds
            else { return }
        }

        if autoAdvancePaused { return cancelMediaAdvance() }
        let serviceItemID = watch.serviceItemID
        let mediaID = watch.mediaID
        mediaAdvancePoll?.invalidate()
        mediaAdvancePoll = nil
        mediaAdvanceWatch = nil
        if advance.delaySeconds <= 0 {
            fireMediaAdvance(from: serviceItemID, mediaID: mediaID)
        } else {
            scheduleMediaAdvanceDelay(advance.delaySeconds, from: serviceItemID, mediaID: mediaID)
        }
    }

    private func fireMediaAdvance(from serviceItemID: String, mediaID: String) {
        mediaAdvanceTimer = nil
        clearAdvanceVisibility()

        guard isMediaLive(mediaID),
              let serviceID = appModel.currentServiceID,
              let service = try? appModel.service(serviceID),
              service.items.contains(where: { $0.id == serviceItemID })
        else { return }
        fireNextServiceItem(after: serviceItemID, in: service)
    }

    private func resolvedLoops(override: Bool?, mediaID: String) -> Bool {
        override ?? (appModel.media(mediaID)?.loops ?? true)
    }

    private func restart(mediaID: String) {
        guard !mediaID.isEmpty,
              render.media.transport(id: mediaID) != nil
        else { return }
        render.media.seek(id: mediaID, to: 0, precise: true)
        render.media.resume(id: mediaID)
        media.refresh()
    }

    func fire(overlay: Overlay) {
        state.fire(overlay: overlay, atHostTime: CACurrentMediaTime())
        apply()

        for object in overlay.objects.map(SlideObjectNormalization.normalized) {
            if let id = SlideSceneBuilder.fillMediaID(object),
               !resolvedLoops(override: object.fill?.loops, mediaID: id) {
                restart(mediaID: id)
            }
        }
        appModel.markUsed(overlay.id)
    }

    enum MediaFireContext {

        case direct

        case playlistWalk

        case serviceItem(id: String)
    }

    @discardableResult
    func fire(
        mediaItem: MediaItem, loopsOverride: Bool? = nil,
        context: MediaFireContext = .direct
    ) -> LayerKind {

        let layer = SlideSceneBuilder.layerKind(CueMedia.dropped(for: mediaItem).layer)

        guard !appModel.isMediaFileMissing(mediaItem) else {
            DiagnosticsStore.shared.note("media.fire.missingFile", detail: mediaItem.name)
            return layer
        }

        let contextID: String? = if case .serviceItem(let id) = context { id } else { nil }
        if let contextID {
            mediaFireContexts[mediaItem.id] = contextID
        } else {
            mediaFireContexts[mediaItem.id] = nil
        }
        actionRouter?.applyPresetSwitches(forMedia: mediaItem, contextID: contextID)

        if let own = RenderContext.sceneTransition(from: mediaItem.transition) {
            render.nextLiveTransitions[layer] = own
        }
        state.fire(
            media: CueMedia(
                mediaId: mediaItem.id, loops: loopsOverride,
                classification: mediaItem.classification),
            on: layer)
        apply()

        if mediaItem.classification != .background {
            restart(mediaID: mediaItem.id)
        }

        actionRouter?.mediaDidFire(mediaItem, on: layer)
        switch context {
        case .direct: cancelMediaAdvance()
        case .playlistWalk: break
        case .serviceItem(let id):
            armMediaAdvance(for: mediaItem, serviceItemID: id)
            serviceTracking?.noteItemFired(serviceItemID: id)
        }
        appModel.markUsed(mediaItem.id)
        return layer
    }

    func dismissOverlay(id: String) {
        state.dismissOverlay(id: id, atHostTime: CACurrentMediaTime())
        apply()
    }

    func dismissAllOverlays() {
        let now = CACurrentMediaTime()
        for overlay in state.liveOverlays {
            state.dismissOverlay(id: overlay.id, atHostTime: now)
        }
        apply()
    }

    func fire(liveInputKind: CaptureSourceKind, sourceId: String, on layer: LayerKind = .videoInput) {
        let engineID = "input::\(liveInputKind.rawValue)::\(sourceId)"
        state.fire(media: CueMedia(mediaId: engineID), on: layer)
        apply()
    }

    func fire(liveInputId: String, on layer: LayerKind = .videoInput) {
        state.fire(
            media: CueMedia(mediaId: VideoInputInventory.engineIDPrefix + liveInputId),
            on: layer)
        apply()
    }

    func fire(playlist: Playlist, startAt entryID: String? = nil, repeatOverride: Bool? = nil) {
        let replaced = audio.play(
            playlist: playlist, startAt: entryID, repeatOverride: repeatOverride)
        for cue in replaced { state.dismissAudio(cue) }
        state.fire(audio: CueAudio(playlistId: playlist.id))
        apply()
        appModel.markUsed(playlist.id)
    }

    func stopAudio(playlistID: String) {
        if let cue = audio.stop(playlistID: playlistID) { state.dismissAudio(cue) }
        apply()
    }

    func stopAudio(audioItemID: String) {
        if let cue = audio.stop(audioItemID: audioItemID) { state.dismissAudio(cue) }
        apply()
    }

    func fire(audioItem: AudioItem, repeatOverride: Bool? = nil) {
        let replaced = audio.play(audioItem: audioItem, repeatOverride: repeatOverride)
        for cue in replaced { state.dismissAudio(cue) }
        state.fire(audio: CueAudio(audioItemId: audioItem.id))
        apply()
        appModel.markUsed(audioItem.id)
    }

    private(set) var alertVisible = true
    private var flashClock: Timer?

    func fireAlert(
        id: String = UUID().uuidString,
        message: String, behavior: AlertBehavior,
        target: AlertTarget = .confidence, themeId: String? = nil,
        layer: LayerKind? = nil
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingAlertTheme?.cancel()
        pendingAlertTheme = nil

        let styling = target != .confidence ? themeId ?? "" : ""
        switch appModel.resident.themes.fireRead(styling) {
        case .now(let theme):
            show(alert: CueAlert(
                id: id, message: trimmed, behavior: behavior, target: target,
                theme: theme, layer: layer
            ))
        case .afterFill:
            pendingAlertTheme = Task { @MainActor [weak self] in
                await self?.appModel.themesFilled([styling])
                if let self, !Task.isCancelled {
                    self.pendingAlertTheme = nil
                    self.show(alert: CueAlert(
                        id: id, message: trimmed, behavior: behavior, target: target,
                        theme: self.appModel.theme(styling), layer: layer
                    ))
                }
            }
        }
    }

    private var pendingAlertTheme: Task<Void, Never>?

    private func show(alert: CueAlert) {
        let theme = alert.theme
        state.fire(alert: alert, atHostTime: CACurrentMediaTime())
        alertVisible = true
        apply()

        if let template = AlertSceneBuilder.alertsThemeSlide(in: theme) {
            for object in template.objects.map(SlideObjectNormalization.normalized) {
                if let mediaID = SlideSceneBuilder.fillMediaID(object),
                   !resolvedLoops(override: object.fill?.loops, mediaID: mediaID) {
                    restart(mediaID: mediaID)
                }
            }
        }
        syncFlashClock()
    }

    func fire(alertPreset: AlertPreset, message: String? = nil) {
        appModel.markUsed(alertPreset.id)
        fireAlert(
            id: alertPreset.id,
            message: message ?? alertPreset.message,
            behavior: alertPreset.behavior,
            target: alertPreset.target ?? .confidence,
            themeId: alertPreset.themeId,
            layer: alertPreset.layer.flatMap(LayerKind.init(rawValue:))
        )
    }

    func dismissAlert() {
        pendingAlertTheme?.cancel()
        pendingAlertTheme = nil
        clear(function: .alerts)
    }

    private func syncFlashClock() {
        let needsClock = state.liveAlert?.behavior == .flash
        if needsClock, flashClock == nil {
            let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.alertVisible.toggle()
                    self.apply()
                }
            }
            RunLoop.main.add(clock, forMode: .common)
            flashClock = clock
        } else if !needsClock, let clock = flashClock {
            clock.invalidate()
            flashClock = nil
            if !alertVisible {
                alertVisible = true
                apply()
            }
        }
    }

    func clear(function: ShowFunction) {
        settlePending()
        if function == .media {
            stashExitTransition(for: Array(state.liveMedia.keys))
        }

        state.clear(function: function, atHostTime: CACurrentMediaTime())
        if function == .slides, state.liveSlide == nil {
            liveContextID = nil
            liveOccurrence = nil
            cancelAutoAdvance()
            refreshNextSlide()
        }
        if function == .audio { audio.stop() }
        if function == .signage { signage?.clearAllChannels() }
        apply()
        if function == .alerts { syncFlashClock() }
    }

    private func stashExitTransition(for layers: some Sequence<LayerKind>) {
        for layer in layers {
            guard let cue = state.liveMedia[layer],
                  let item = appModel.media(cue.mediaId),
                  let own = RenderContext.sceneTransition(from: item.transition)
            else { continue }
            render.nextLiveTransitions[layer] = own
        }

    }

    func clear(layer: LayerKind) {
        settlePending()
        stashExitTransition(for: [layer])
        state.clear(layer: layer, atHostTime: CACurrentMediaTime())
        if layer == .slide, state.liveSlide == nil {
            liveContextID = nil
            liveOccurrence = nil
            cancelAutoAdvance()
            refreshNextSlide()
        }
        apply()
        if layer == .alerts { syncFlashClock() }
    }

    static let clearAllIncludesAudioKey = "serviceControls.clearAllIncludesAudio"

    func clearAll(protecting: Set<LayerKind> = [], cancelsPendingActions: Bool = true) {
        settlePending()
        if cancelsPendingActions { actionRouter?.cancelPendingDelayedActions() }
        let includeAudio = UserDefaults.standard.object(
            forKey: Self.clearAllIncludesAudioKey
        ) as? Bool ?? true
        state.clearAll(includingAudio: includeAudio, protecting: protecting)
        if includeAudio { audio.stop() }

        signage?.clearAllChannels()

        if state.liveSlide == nil {
            liveContextID = nil
            liveOccurrence = nil
            cancelAutoAdvance()
        }
        cancelMediaAdvance()
        refreshNextSlide()
        apply()
        syncFlashClock()
    }

    func hasContent(function: ShowFunction) -> Bool {
        switch function {
        case .slides: state.liveSlide != nil
        case .media: !state.liveMedia.isEmpty
        case .overlays: !state.liveOverlays.isEmpty
        case .audio: !state.liveAudio.isEmpty
        case .alerts: state.liveAlert != nil
        case .signage: signage?.hasAnyChannelContent ?? false
        }
    }

    func hasContent(layer: LayerKind) -> Bool {
        switch layer {
        case .loopingVideos, .stillGraphics, .videos, .videoInput:

            state.liveMedia[layer] != nil
        case .slide:
            state.liveSlide != nil
        case .overlays:
            !state.liveOverlays.isEmpty
        case .alerts:
            state.liveAlert != nil
        }
    }

    var hasAnyClearableContent: Bool {
        ShowFunction.allCases.contains { hasContent(function: $0) }
    }

    var liveSlideID: String? { state.liveSlide?.slide.id }

    var livePresentationID: String? { state.liveSlide?.presentation?.id }

    func isMediaLive(_ mediaID: String) -> Bool {
        state.liveMedia.values.contains { $0.mediaId == mediaID }
    }

    private(set) var nextSlideInfo: ConfidenceInfo.SlideText?

    var nextSlideText: String? { nextSlideInfo?.body }

    private(set) var slidePosition: ConfidenceInfo.SlidePosition?
    private(set) var currentItemName: String?
    private(set) var nextItemName: String?

    private struct FireContext {
        var upcoming: [(slide: Slide, presentation: Presentation?)] = []
        var slidePosition: ConfidenceInfo.SlidePosition?
        var currentItemName: String?
        var nextItemName: String?
    }

    static let nextSkipsBlanksKey = "confidence.nextSkipsBlankSlides"

    private var nextSkipsBlanks: Bool {
        UserDefaults.standard.object(forKey: Self.nextSkipsBlanksKey) as? Bool ?? true
    }

    func presentationEdited(_ id: String) {
        let onGlass = state.liveSlide?.presentation?.id == id || state.lastSlide?.presentation?.id == id
        let held = onGlass ? appModel.heldPresentation(id) : nil
        if held != nil || !onGlass {
            presentationEdited(id, fresh: held)
        } else {
            Task { [weak self] in
                if let self {
                    presentationEdited(id, fresh: await appModel.presentationsFilled([id])[id])
                }
            }
        }
    }

    private func presentationEdited(_ id: String, fresh: Presentation?) {
        if let fresh {
            state.presentationEdited(fresh)
        }
        refreshNextSlide()

        if autoAdvanceTimer == nil, autoAdvancePoll == nil,
           let live = state.liveSlide, live.presentation?.id == id {
            armAutoAdvance(for: live.slide, in: live.presentation)
        }
    }

    func presentationFillDidLand(_ id: String) {
        guard liveContextID != nil,
              let serviceID = appModel.currentServiceID,
              let service = try? appModel.service(serviceID),
              service.items.contains(where: { $0.refId == id })
        else { return }
        refreshNextSlide()
    }

    func refreshNextSlide() {
        let context = fireContext()
        nextSlideInfo = ConfidenceSceneBuilder.nextSlide(
            in: context.upcoming.map(\.slide), skippingBlanks: nextSkipsBlanks
        ).map { next in
            ConfidenceSceneBuilder.slideText(
                for: next,
                in: context.upcoming.first { $0.slide.id == next.id }?.presentation
            )
        }
        slidePosition = context.slidePosition
        currentItemName = context.currentItemName
        nextItemName = context.nextItemName
        if state.hasLinkedText {

            apply()
        } else {
            pushConfidence()
        }
    }

    private struct ServicePosition {
        var itemID: String
        var occurrence: Int
        var slide: Slide
        var presentation: Presentation
        var arrangementId: String?
    }

    private func servicePositions(in service: Service) -> [ServicePosition] {
        var positions: [ServicePosition] = []
        for item in appModel.runOfShow(service) where item.itemKind == .presentation {

            guard let presentation = appModel.presentation(item.refId) else { continue }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: item.arrangementId
            )
            for (index, slide) in slides.enumerated() {
                positions.append(ServicePosition(
                    itemID: item.id, occurrence: index, slide: slide,
                    presentation: presentation, arrangementId: item.arrangementId
                ))
            }
        }
        return positions
    }

    private func fireContext() -> FireContext {
        var context = FireContext()
        guard let contextID = liveContextID, let occurrence = liveOccurrence else { return context }

        if let serviceID = appModel.currentServiceID,
           let service = try? appModel.service(serviceID),
           let itemIndex = service.items.firstIndex(where: { $0.id == contextID }) {
            let positions = servicePositions(in: service)
            guard let current = positions.firstIndex(where: {
                $0.itemID == contextID && $0.occurrence == occurrence
            }) else { return context }
            context.upcoming = positions[(current + 1)...].map { ($0.slide, $0.presentation) }
            context.slidePosition = ConfidenceInfo.SlidePosition(
                index: occurrence + 1,
                total: positions.filter { $0.itemID == contextID }.count
            )
            context.currentItemName = service.items[itemIndex].name

            let show = appModel.runOfShow(service)
            if let showIndex = show.firstIndex(where: { $0.id == contextID }) {
                context.nextItemName = show[(showIndex + 1)...]
                    .first { $0.itemKind != .header }?.name
            }
            return context
        }

        guard let live = state.liveSlide, let presentation = live.presentation else { return context }
        let slides = SlideSceneBuilder.arrangedSlides(
            for: presentation, arrangementId: live.arrangementId
        )
        if slides.indices.contains(occurrence) {
            context.slidePosition = ConfidenceInfo.SlidePosition(
                index: occurrence + 1, total: slides.count
            )
        }
        if slides.indices.contains(occurrence + 1) {
            context.upcoming = slides[(occurrence + 1)...].map { ($0, presentation) }
        }
        return context
    }

    private func apply() {

        let pageTurn = Paging.Turn.following(
            UserDefaults.standard.string(forKey: "transition.slide.kind").flatMap(TransitionKind.init(rawValue:)),
            duration: UserDefaults.standard.object(forKey: "transition.slide.duration") as? Double ?? 0.5)

        if state.pageTurn != pageTurn {
            state.pageTurn = pageTurn
        }

        pushConfidence()
        let now = Date()
        let base = state.scene(
            alertVisible: alertVisible,
            linkedText: render.confidenceInfo, at: now
        )

        .applyingMediaEffects { appModel.mediaSceneEffects(id: $0) }

        var variants: [String: RenderScene] = [:]
        for (themeID, theme) in slideThemeOverrides {
            variants[themeID] = state.scene(
                alertVisible: alertVisible,
                linkedText: render.confidenceInfo,
                slideThemeOverride: theme, at: now
            )
            .applyingMediaEffects { appModel.mediaSceneEffects(id: $0) }
        }
        render.setLiveScenes(base, variants: variants)
        syncMedia()
        syncLinkedTextClock()
        syncExitSweep()

        appModel.noteOnAirDeck(livePresentationID)
    }

    private var slideThemeOverrides: [String: Theme] = [:]

    func setSlideThemeOverrides(_ overrides: [String: Theme]) {
        guard overrides != slideThemeOverrides else { return }
        slideThemeOverrides = overrides

        state.slideThemeOverrides = overrides.sorted { $0.key < $1.key }.map(\.value)
        apply()
    }

    private var linkedTextClock: Timer?

    private func syncLinkedTextClock() {

        let alertTicks = state.liveAlert.map {
            LinkedText.alertMessageHasTimerToken(
                $0.message, timers: render.confidenceInfo.timers)
        } ?? false
        let interval = state.linkedTextTickInterval(
            slideThemeOverrides: Array(slideThemeOverrides.values)
        ) ?? (alertTicks ? 1.0 : nil)
        if let interval {

            if linkedTextClock?.timeInterval != interval {
                linkedTextClock?.invalidate()
                let clock = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.apply()
                    }
                }
                RunLoop.main.add(clock, forMode: .common)
                linkedTextClock = clock
            }
        } else if let clock = linkedTextClock {
            clock.invalidate()
            linkedTextClock = nil
        }
    }

    private func pushConfidence() {
        var info = render.confidenceInfo
        info.current = state.liveSlide.map {
            var text = ConfidenceSceneBuilder.slideText(for: $0.slide, in: $0.presentation)

            if let step = state.slideAnimationStep {
                text.stepIndex = step.consumed
                text.stepCount = step.total
            }
            return text
        }
        info.next = nextSlideInfo

        info.nextStep = state.liveSlide.flatMap { _ -> ConfidenceInfo.SlideText? in
            guard let step = state.slideAnimationStep, step.consumed < step.total else { return nil }

            return state.upcomingRevealText().map { ConfidenceInfo.SlideText(body: $0) }
        }

        info.last = state.lastSlide.map {
            ConfidenceSceneBuilder.slideText(for: $0.slide, in: $0.presentation)
        }
        info.slidePosition = slidePosition
        info.currentItemName = currentItemName

        info.currentGroupName = state.liveSlide.flatMap { live in
            guard let sectionId = live.slide.sectionId, !sectionId.isEmpty else { return nil }
            return live.presentation?.sections?.first { $0.id == sectionId }?.name
        }
        info.nextItemName = nextItemName

        info.currentPresentationName = state.liveSlide?.presentation?.name
        info.alert = state.liveAlert
        info.alertVisible = alertVisible
        render.confidenceInfo = info
    }

    private var confidenceMediaWants: [String: Bool?] = [:]

    func setConfidenceMediaWants(_ wants: [String: Bool?]) {
        guard wants != confidenceMediaWants else { return }
        confidenceMediaWants = wants

        syncMedia()
    }

    private var previewMediaWants: [String: Bool?] = [:]

    func setPreviewMediaWants(_ wants: [String: Bool?]) {
        if wants != previewMediaWants {
            previewMediaWants = wants
            syncMedia()
        }
    }

    private func syncMedia() {
        let onAir = state.wantedMedia(
            slideThemeOverrides: Array(slideThemeOverrides.values)
        )
        .merging(confidenceMediaWants) { show, _ in show }
        let wanted = MonitoringMedia.wanted(onAir: onAir, monitoring: previewMediaWants)
        let wantedIDs = Set(wanted.keys)

        let held = render.transitions.heldMediaIDs()
            .union(render.heldVariantMediaIDs())
            .intersection(liveMediaIDs)
        for id in liveMediaIDs.subtracting(wantedIDs) {

            if id.hasPrefix("input::"), VideoInputInventory.shared.isInventoried(engineID: id) {
                continue
            }
            if held.contains(id) { continue }
            render.media.stop(id: id)
        }
        let added = wantedIDs.subtracting(liveMediaIDs)
        liveMediaIDs = wantedIDs.union(held)
        if !held.isEmpty, !transitionResweepScheduled {
            transitionResweepScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.transitionResweepScheduled = false
                self?.syncMedia()
            }
        }

        let liveNamedInputs = MonitoringMedia.liveInputs(
            onAir: onAir, prefix: VideoInputInventory.engineIDPrefix)
        mixer.setLiveVideoInputs(liveNamedInputs)

        pushLiveInputVisibility(liveNamedInputs)
        let seeds = state.transportSeeds()
        media.refresh(seeds: seeds)
        guard !added.isEmpty, let blobs else { return }
        Task { [render, appModel, media] in
            for mediaID in added {

                if mediaID.hasPrefix(ScreenMirrorService.prefix) {
                    ScreenMirrorService.shared.start(id: mediaID, render: render)
                    continue
                }

                if mediaID.hasPrefix("input::") {
                    if mediaID.hasPrefix(VideoInputInventory.engineIDPrefix) {

                        VideoInputInventory.shared.startIfNeeded(engineID: mediaID)
                    } else {

                        Self.startLiveInput(id: mediaID, render: render)
                    }
                    continue
                }
                guard let item = appModel.media(mediaID)
                else { continue }
                guard let url = blobs.url(forHash: item.fileHash) else {

                    DiagnosticsStore.shared.note("media.file.missing", detail: item.name)
                    continue
                }
                switch item.mediaKind {
                case .video:
                    if let prepared = try? await render.media.prepare(url: url) {
                        render.media.play(
                            prepared, id: mediaID,
                            loop: (wanted[mediaID] ?? nil) ?? item.loops,

                            options: PlaybackOptions(
                                inPoint: item.inPoint, outPoint: item.outPoint,
                                rate: item.playRate
                            )
                        )
                    }
                case .image:
                    _ = try? await render.media.showStill(url: url, id: mediaID)
                }
            }

            media.refresh(seeds: seeds)
        }
    }

    private static func startLiveInput(id: String, render: RenderContext) {
        let parts = id.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "input" else { return }
        let source = parts.dropFirst(2).joined(separator: ":")
        switch parts[1] {
        case "item":

            VideoInputInventory.shared.startIfNeeded(engineID: id)
        case "camera":

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    Task { @MainActor in
                        if granted {
                            startLiveInput(id: id, render: render)
                        } else {
                            DiagnosticsStore.shared.note(
                                "input.camera", detail: "permission declined")
                        }
                    }
                }
                return
            case .denied, .restricted:
                DiagnosticsStore.shared.note(
                    "input.camera",
                    detail: "permission denied — enable in System Settings › Privacy › Camera")
                return
            default:
                break
            }
            guard let device = AVCaptureDevice(uniqueID: source) else {
                DiagnosticsStore.shared.note("input.camera", detail: "device missing: \(source)")
                return
            }
            do {
                try render.media.startCapture(device: device, id: id)
                DiagnosticsStore.shared.note(
                    "input.camera", detail: "started: \(device.localizedName)")
            } catch {
                DiagnosticsStore.shared.note("input.camera", detail: "start failed: \(error)")
            }
        case "ndi":
            do {
                let library = try NDILibrary.load()
                let input = NDIInputSource(library: library, sourceNameContaining: source)
                render.media.registerLiveSource(
                    id: id,
                    latestFrame: { input.latestFrame() },
                    onStop: { input.stop() })
            } catch {
                DiagnosticsStore.shared.note("input.ndi", detail: "runtime unavailable: \(error)")
            }
        default:
            break
        }
    }
}
