import Foundation
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

    func isCurrent(_ itemID: String) -> Bool { self.itemID == itemID }

    func insertionTime(for itemID: String) -> Double {
        self.itemID == itemID ? PresentationTimelines.snappedToFrame(timelinePlayheadTime) : 0
    }

    func play(itemID: String, presentation: Presentation, arrangementId: String?) {
        if self.itemID != itemID { select(itemID: itemID, presentation: presentation, arrangementId: arrangementId) }
        guard !playing else { return }
        playing = true
        if timelinePlayheadTime <= 0 {
            lastPosition = -PresentationTimelines.frame
        } else {
            land(at: timelinePlayheadTime)
        }
        anchor(at: timelinePlayheadTime)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DiagnosticsStore.shared.note("timeline.play", detail: String(format: "%.2f", timelinePlayheadTime))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        guard playing else { return }
        playing = false
        recording = false
        recordingTimeline = nil
        DiagnosticsStore.shared.note("timeline.stop", detail: String(format: "%.2f", timelinePlayheadTime))
    }

    func record(itemID: String, presentation: Presentation, arrangementId: String?, newStart: Int) {
        stop()
        if self.itemID != itemID { select(itemID: itemID, presentation: presentation, arrangementId: arrangementId) }
        var timeline = timeline(of: presentation) ?? PresentationTimeline(
            id: UUID().uuidString, arrangementId: arrangementId.flatMap { $0.isEmpty ? nil : $0 },
            timecodeEnabled: false, timecodeStart: newStart, cues: [])
        timeline.cues = PresentationTimelines.recording(timeline.cues, from: timelinePlayheadTime)
        recordingTimeline = timeline
        save(timeline, presentationID: presentation.id, undoLabel: "Record Timeline")
        play(itemID: itemID, presentation: presentation, arrangementId: arrangementId)
        recording = true
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
        }
    }

    private func select(itemID: String, presentation: Presentation, arrangementId: String?) {
        stop()
        self.itemID = itemID
        presentationID = presentation.id
        self.arrangementId = arrangementId
        setPlayhead(0)
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
        let position = anchorPosition + (CACurrentMediaTime() - anchorHost)
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
        guard let controls, !effects.isEmpty else { return }
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
            case .fireOverlay(let id):
                if let overlay = model.overlay(id) { controls.fire(overlay: overlay) }
            case .clearOverlay(let id):
                controls.dismissOverlay(id: id)
            case .fireMedia(let id, _):
                if let media = model.media(id) { controls.fire(mediaItem: media) }
            case .clearMedia(let id):

                if let layer = controls.state.liveMedia.first(where: { $0.value.mediaId == id })?.key {
                    controls.clear(layer: layer)
                }
            case .runActions(let cueID):
                if let actions = cues.first(where: { $0.id == cueID })?.actions, !actions.isEmpty {
                    controls.actionRouter?.execute(actions)
                }
            }
            DiagnosticsStore.shared.note("timeline.fire", detail: "\(effect)")
        }
    }

    private func live() -> PresentationTimelines.Live {
        guard let state = controls?.state else { return PresentationTimelines.Live() }
        return PresentationTimelines.Live(
            mediaIds: Set(state.liveMedia.values.map(\.mediaId)),
            overlayIds: Set(state.liveOverlays.map(\.id)))
    }

    func noteSlideLanded(contextID: String?, occurrence: Int?) {
        guard recording, !firing, let itemID, contextID == itemID, let occurrence,
              let deck = deck(), var timeline = recordingTimeline,
              let anchor = PresentationTimelines.anchor(occurrence: occurrence, in: blocks(of: deck))
        else { return }
        let cue = PresentationTimelines.slideCue(
            id: UUID().uuidString, at: PresentationTimelines.snappedToFrame(lastPosition), anchor: anchor)
        timeline.cues = PresentationTimelines.recorded(cue, into: timeline.cues)
        recordingTimeline = timeline
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
        recordingTimeline?.cues ?? timeline(of: deck)?.cues
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
