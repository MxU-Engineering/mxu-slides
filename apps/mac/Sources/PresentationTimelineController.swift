import AudioEngine
import Foundation
import LocalAPI
import PresenterCore
import QuartzCore
import SlideScene

@MainActor
@Observable
final class PresentationTimelineController: TimelinePlayheadSource {
    @ObservationIgnored weak var controls: ServiceControls?

    private(set) var itemID: String?
    private(set) var presentationID: String?
    private(set) var arrangementId: String?
    private(set) var playing = false
    private(set) var recording = false

    private(set) var timelinePlayheadTime: Double = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var anchorHost: CFTimeInterval = 0
    @ObservationIgnored private var anchorPosition: Double = 0

    @ObservationIgnored private var lastPosition: Double = 0

    @ObservationIgnored private var recordingTimeline: PresentationTimeline?

    @ObservationIgnored private var firing = false

    @ObservationIgnored private var underTimecode = false

    @ObservationIgnored private var timecodePlaysAudio = false

    @ObservationIgnored private var audioSyncHold: CFTimeInterval = 0

    @ObservationIgnored private(set) var timecodeRecording: TimecodeRecording?

    @ObservationIgnored private var tracksSong: String?
    @ObservationIgnored private var tracksAsked: CFTimeInterval = 0

    func isCurrent(_ itemID: String) -> Bool { self.itemID == itemID }

    func insertionTime(for itemID: String) -> Double {
        self.itemID == itemID ? PresentationTimelines.snappedToFrame(timelinePlayheadTime) : 0
    }

    func play(itemID: String, presentation: Presentation, arrangementId: String?) {
        if self.itemID != itemID { select(itemID: itemID, presentation: presentation, arrangementId: arrangementId) }
        guard !playing else { return }

        if timecodeRecording != nil { endRecording() }
        playing = true
        if timelinePlayheadTime <= 0 {
            lastPosition = -PresentationTimelines.frame
        } else {
            land(at: timelinePlayheadTime)
        }
        anchor(at: timelinePlayheadTime)
        publishClock(position: timelinePlayheadTime, running: true)
        startTracks(at: timelinePlayheadTime)
        startTimer()
        DiagnosticsStore.shared.note("timeline.play", detail: String(format: "%.2f", timelinePlayheadTime))
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let againstTimecode = timecodeRecording != nil
        endRecording()
        guard playing else {
            if againstTimecode {
                DiagnosticsStore.shared.note("timeline.stop", detail: "timecode take \(String(format: "%.2f", timelinePlayheadTime))")
            }
            return
        }

        stopTracks()
        playing = false
        publishClock(position: timelinePlayheadTime, running: false)
        DiagnosticsStore.shared.note("timeline.stop", detail: String(format: "%.2f", timelinePlayheadTime))
    }

    private func endRecording() {
        recording = false
        recordingTimeline = nil
        timecodeRecording = nil
    }

    func record(itemID: String, presentation: Presentation, arrangementId: String?, newStart: Int, start: Int? = nil) {
        stop()
        if self.itemID != itemID { select(itemID: itemID, presentation: presentation, arrangementId: arrangementId) }
        if let follower = controls?.timecode, case .timecode(let start) = TimecodeRecording.mode(
            timeline: timeline(of: presentation), start: start, hasInput: follower.hasInput, follows: follower.follows) {
            timecodeRecording = TimecodeRecording(itemID: itemID, start: start)
            recording = true
            DiagnosticsStore.shared.note("timeline.record", detail: "armed for timecode")
            return
        }
        var timeline = timeline(of: presentation) ?? PresentationTimeline(
            id: UUID().uuidString, arrangementId: arrangementId.flatMap { $0.isEmpty ? nil : $0 },
            timecodeEnabled: false, timecodeStart: newStart, cues: [])
        timeline.cues = PresentationTimelines.recording(timeline.cues, from: timelinePlayheadTime)
        recordingTimeline = timeline
        save(timeline, presentationID: presentation.id, undoLabel: "Record Timeline")
        play(itemID: itemID, presentation: presentation, arrangementId: arrangementId)
        recording = true
    }

    func stopTracks() {
        if tracksSong != nil {
            controls?.tracks.stop()
            tracksSong = nil
        }
        guard let controls, let deck = deck() else { return }
        for id in Set((cues(of: deck) ?? []).filter { $0.kind == .audio }.compactMap(\.contentId))
        where controls.audio.player(forAudioItem: id) != nil {
            controls.stopAudio(audioItemID: id)
        }
    }

    func seek(to position: Double, itemID: String, presentation: Presentation, arrangementId: String?) {
        if self.itemID != itemID {
            stop()
            select(itemID: itemID, presentation: presentation, arrangementId: arrangementId)
        }
        let position = max(position, 0)
        setPlayhead(position)
        if playing {
            land(at: position)
            anchor(at: position)
            if tracksSong != nil {
                controls?.tracks.seek(to: position)
                tracksAsked = CACurrentMediaTime()
            }
        }
        publishClock(position: position, running: playing)
    }

    private func multitrackSong() -> MultitrackSong? {
        guard let controls, let itemID, let presentationID, let deck = deck(),
              let cues = timeline(of: deck)?.cues else { return nil }
        let model = controls.appModel
        var missing = 0
        let stems = TimelineTracks.stems(cues).compactMap { cue -> MultitrackStem? in
            guard let channel = cue.trackChannelId, let id = cue.mediaId, let item = model.audio(id),
                  let url = controls.audioFileURL(item), FileManager.default.fileExists(atPath: url.path)
            else { missing += 1; return nil }
            return MultitrackStem(path: url.path, channelId: channel, at: cue.at, inPoint: item.inPoint, duration: cue.duration)
        }
        if missing > 0 { DiagnosticsStore.shared.note("tracks.missing", detail: "\(missing) stems not on this Mac") }
        guard !stems.isEmpty else { return nil }
        return MultitrackSong(id: [itemID, presentationID, arrangementId ?? ""].joined(separator: "|"), stems: stems)
    }

    private func startTracks(at position: Double) {
        guard let song = multitrackSong() else { return }
        tracksSong = song.id
        tracksAsked = CACurrentMediaTime()
        controls?.tracks.play(song, from: position)
    }

    func clearTracks() {
        if TracksClear.stopsTimeline(ownClockPlaying: playing, playingTracks: tracksSong != nil) {
            stop()
        } else {
            controls?.tracks.stop()
            tracksSong = nil
        }
    }

    func resume(fromTracks status: TracksPlayerStatus) {
        guard let controls, let key = status.songID, !playing else { return }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }

        guard let deck = controls.appModel.presentation(parts[1]) else {
            Task { [weak self] in
                guard await controls.appModel.presentationsFilled([parts[1]])[parts[1]] != nil,
                      let fresh = controls.tracks.latest.value, fresh.playing, fresh.songID == key else { return }
                self?.resume(fromTracks: fresh)
            }
            return
        }
        select(itemID: parts[0], presentation: deck, arrangementId: parts[2].isEmpty ? nil : parts[2])
        let position = status.position()
        playing = true
        tracksSong = key
        tracksAsked = CACurrentMediaTime()
        land(at: position)
        anchor(at: position)
        setPlayhead(position)
        publishClock(position: position, running: true)
        startTimer()

        PresentationTimelineCards.shared.open.insert(parts[0])
        DiagnosticsStore.shared.note("timeline.resume", detail: "tracks at \(String(format: "%.2f", position))")
    }

    func follow(
        _ command: TimecodeFollow.Command, itemID: String, presentation: Presentation, arrangementId: String?,
        playsAudio: Bool = false
    ) {
        if self.itemID != itemID || presentationID != presentation.id || self.arrangementId != arrangementId {
            select(itemID: itemID, presentation: presentation, arrangementId: arrangementId)
        } else if playing {
            stop()
        }
        underTimecode = true
        timecodePlaysAudio = playsAudio
        defer { underTimecode = false }
        switch command {
        case .play(_, let from, let to):

            lastPosition = timecodeRecording?.started == true ? max(from, lastPosition) : from
            advance(to: to)
        case .land(_, let at):
            land(at: at)
        }

        let now = CACurrentMediaTime()
        if case .land = command { audioSyncHold = now + 0.5 }
        if playsAudio, now >= audioSyncHold, let controls, let deck = deck(), let cues = cues(of: deck) {
            var playing: [String: Double] = [:]
            for id in Set(cues.filter { $0.kind == .audio }.compactMap(\.contentId)) {
                if let player = controls.audio.player(forAudioItem: id), player.isPlaying { playing[id] = player.elapsed }
            }
            let sync = TimecodeFollow.audioSync(cues, at: command.position, playing: playing)
            if sync.contains(where: { if case .playAudio = $0 { true } else { false } }) { audioSyncHold = now + 0.5 }
            apply(sync, cues: cues, deck: deck)

            if let song = multitrackSong() {
                let heard = controls.tracks.position(of: song.id)
                if tracksSong != song.id || heard.map({ abs($0 - command.position) > 0.5 }) ?? (now - tracksAsked > 1) {
                    tracksSong = song.id
                    tracksAsked = now
                    audioSyncHold = now + 0.5
                    controls.tracks.play(song, from: command.position)
                }
            }
        }
        setPlayhead(command.position)
        publishClock(position: command.position, running: true)
    }

    func timecodeHeld() {
        guard clockAnchor?.running == true, !playing else { return }
        publishClock(position: timelinePlayheadTime, running: false)
    }

    func timecodeRecordingTick(_ reading: TimecodeClock.Reading) -> TimecodeRecording? {
        guard var take = timecodeRecording else { return nil }
        switch take.step(reading) {
        case .none:
            break
        case .end:
            stop()
            return nil
        case .begin(let start, let at):
            guard let deck = deck() else { break }
            var timeline = timeline(of: deck) ?? PresentationTimeline(
                id: UUID().uuidString, arrangementId: arrangementId.flatMap { $0.isEmpty ? nil : $0 },
                timecodeEnabled: true, timecodeStart: start, cues: [])
            timeline.cues = PresentationTimelines.recording(timeline.cues, from: at)
            recordingTimeline = timeline
            save(timeline, presentationID: deck.id, undoLabel: "Record Timeline")
            take.start = start
            take.started = true
            timecodeRecording = take
            lastPosition = at
            setPlayhead(at)
            DiagnosticsStore.shared.note(
                "timeline.record", detail: "against timecode from \(String(format: "%.3f", at)), start \(start)")
        }
        return take
    }

    struct ClockAnchor: Equatable {
        var itemID: String
        var position: Double
        var at: Date
        var running: Bool
        var length: Double
    }

    private(set) var clockAnchor: ClockAnchor?

    private func publishClock(position: Double, running: Bool) {
        guard let itemID else {
            if clockAnchor != nil { clockAnchor = nil }
            return
        }
        let now = Date()
        let length = deck().flatMap { timeline(of: $0) }.map(PresentationTimelines.length) ?? 0
        if let held = clockAnchor, held.itemID == itemID, held.running == running, held.length == length,
           abs(held.position + (running ? now.timeIntervalSince(held.at) : 0) - position) < 0.1 {
            return
        }
        clockAnchor = ClockAnchor(itemID: itemID, position: position, at: now, running: running, length: length)
    }

    private func select(itemID: String, presentation: Presentation, arrangementId: String?) {
        stop()
        self.itemID = itemID
        presentationID = presentation.id
        self.arrangementId = arrangementId
        setPlayhead(0)
        publishClock(position: 0, running: false)
    }

    private func anchor(at position: Double) {
        anchorHost = CACurrentMediaTime()
        anchorPosition = position
        lastPosition = position
    }

    private func setPlayhead(_ position: Double) {
        if timelinePlayheadTime != position { timelinePlayheadTime = position }
    }

    private func tick() {
        guard playing else { return }
        var position = anchorPosition + (CACurrentMediaTime() - anchorHost)
        if let song = tracksSong {
            if let heard = controls?.tracks.position(of: song) {

                position = heard
                anchorHost = CACurrentMediaTime()
                anchorPosition = heard
            } else if CACurrentMediaTime() - tracksAsked < 2 {

                anchorHost = CACurrentMediaTime()
                return
            } else {
                DiagnosticsStore.shared.note("tracks.silent", detail: "no answer from the Tracks Player; own clock")
                tracksSong = nil
            }
        }
        advance(to: position)
        setPlayhead(position)
        if !recording, let deck = deck(), let timeline = timeline(of: deck),
           position > PresentationTimelines.length(timeline) + 1 {
            stop()
        }
    }

    func advance(to position: Double) {
        guard let deck = deck(), let cues = cues(of: deck) else {
            lastPosition = position
            return
        }
        let effects = PresentationTimelines.crossing(
            cues, blocks: blocks(of: deck), from: lastPosition, to: position, live: live())
        lastPosition = position
        apply(effects, cues: cues, deck: deck)
    }

    func land(at position: Double) {
        lastPosition = position
        guard let deck = deck(), let cues = cues(of: deck) else { return }
        apply(PresentationTimelines.landing(cues, blocks: blocks(of: deck), at: position, live: live()), cues: cues, deck: deck)
    }

    private func apply(_ effects: [PresentationTimelines.Effect], cues: [TimelineCue], deck: Presentation) {

        let effects = underTimecode ? TimecodeFollow.underTimecode(effects, playsAudio: timecodePlaysAudio) : effects
        guard !effects.isEmpty else { return }

        APIFireSource.$current.withValue(APIFireSource(kind: underTimecode ? .timecode : .timeline)) {
            fire(effects, cues: cues, deck: deck)
        }
    }

    private func fire(_ effects: [PresentationTimelines.Effect], cues: [TimelineCue], deck: Presentation) {
        guard let controls else { return }
        let model = controls.appModel
        for effect in effects {
            switch effect {
            case .showSlide(let occurrence, let actions):
                let slides = model.arrangedSlides(deck, arrangementId: arrangementId)
                guard slides.indices.contains(occurrence) else { continue }
                firing = true
                controls.fire(
                    slide: slides[occurrence], in: deck, arrangementId: arrangementId,
                    contextID: itemID, occurrence: occurrence, slideActions: actions)
                firing = false
            case .fire(let lane, let id):
                switch lane {
                case .overlays:
                    if let overlay = model.overlay(id) { controls.fire(overlay: overlay) }
                case .alerts:
                    if let preset = try? model.alertPreset(id) { controls.fire(alertPreset: preset) }
                case .videoInput:
                    controls.fire(liveInputId: id)
                case .videos, .stillGraphics, .loopingVideos:
                    if let media = model.media(id) { controls.fire(mediaItem: media) }
                case .slide, .audio, .actions:
                    break
                }
            case .clear(let lane, let id):

                switch lane {
                case .overlays:
                    controls.dismissOverlay(id: id)
                case .alerts:
                    if controls.state.liveAlert?.id == id { controls.dismissAlert() }
                case .audio:
                    if controls.audio.player(forAudioItem: id) != nil { controls.stopAudio(audioItemID: id) }
                case .videos, .stillGraphics, .loopingVideos, .videoInput:
                    let engineID = lane == .videoInput ? VideoInputInventory.engineIDPrefix + id : id
                    if let layer = controls.state.liveMedia.first(where: { $0.value.mediaId == engineID })?.key {
                        controls.clear(layer: layer)
                    }
                case .slide, .actions:
                    break
                }
            case .playAudio(let id, let from):

                if controls.audio.player(forAudioItem: id) == nil, let item = model.audio(id) {
                    controls.fire(audioItem: item, repeatOverride: false)
                }
                if from > PresentationTimelines.frame { controls.audio.player(forAudioItem: id)?.seek(to: from) }
            case .runActions(let cueID):
                if let actions = cues.first(where: { $0.id == cueID })?.actions, !actions.isEmpty {
                    controls.actionRouter?.execute(actions)
                }
            }
            DiagnosticsStore.shared.note("timeline.fire", detail: "\(effect) at \(String(format: "%.3f", lastPosition))")
        }
    }

    private func live() -> PresentationTimelines.Live {
        guard let state = controls?.state else { return [] }
        var live = Set(state.liveMedia.values.map { cue in
            cue.mediaId.hasPrefix(VideoInputInventory.engineIDPrefix)
                ? String(cue.mediaId.dropFirst(VideoInputInventory.engineIDPrefix.count)) : cue.mediaId
        })
        live.formUnion(state.liveOverlays.map(\.id))
        live.formUnion(state.liveAudio.compactMap(\.audioItemId))
        if let alert = state.liveAlert { live.insert(alert.id) }
        return live
    }

    func noteSlideLanded(contextID: String?, occurrence: Int?) {
        guard recording, !firing, let itemID, contextID == itemID, let occurrence,
              timecodeRecording.map(\.started) ?? true,
              let deck = deck(), var timeline = recordingTimeline,
              let anchor = PresentationTimelines.anchor(occurrence: occurrence, in: blocks(of: deck))
        else { return }
        let cue = PresentationTimelines.slideCue(
            id: UUID().uuidString, at: PresentationTimelines.snappedToFrame(lastPosition), anchor: anchor)
        timeline.cues = PresentationTimelines.recorded(cue, into: timeline.cues)
        recordingTimeline = timeline

        lastPosition = max(lastPosition, cue.at)
        save(timeline, presentationID: deck.id, undoLabel: nil)
        DiagnosticsStore.shared.note("timeline.record", detail: "\(occurrence) at \(cue.at)")
    }

    private func deck() -> Presentation? {
        presentationID.flatMap { controls?.appModel.presentation($0) }
    }

    private func timeline(of deck: Presentation) -> PresentationTimeline? {
        PresentationTimelines.timeline(for: arrangementId, in: deck)
    }

    private func cues(of deck: Presentation) -> [TimelineCue]? {
        guard let cues = recordingTimeline?.cues ?? timeline(of: deck)?.cues else { return nil }

        return underTimecode && timecodeRecording == nil
            ? TimecodeFollow.followedCues(cues, blocks: blocks(of: deck)) : cues
    }

    private func blocks(of deck: Presentation) -> [TimelinePlayedBlock] {
        SlideSceneBuilder.timelineBlocks(for: deck, arrangementId: arrangementId)
    }

    func save(_ timeline: PresentationTimeline, presentationID: String, undoLabel: String?) {
        guard let model = controls?.appModel else { return }
        let all = PresentationTimelines.replacing(timeline, in: model.presentation(presentationID)?.timelines)
        model.updatePresentationField(presentationID, \.timelines, key: "timelines", to: all, undoLabel: undoLabel)
    }
}
