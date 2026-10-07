import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let fixedDate = Date(timeIntervalSince1970: 1_784_800_000)

private func fixtureInfo(alert: CueAlert? = nil) -> ConfidenceInfo {
    ConfidenceInfo(
        current: .init(body: "current line"),
        next: .init(body: "next line"),
        last: .init(body: "last line"),
        alert: alert,
        timers: [TimerSnapshot(id: "t", name: "Sermon", mode: .countdown, banked: 754, durationSeconds: 1800)],
        videoCountdown: VideoCountdown(
            name: "Bumper", duration: 300, position: 180,
            anchoredAt: fixedDate, isPlaying: false
        )
    )
}

private func linkedObject(_ id: String, _ source: TextSourceKind) -> SlideObject {
    var object = SlideObject(id: id, objectKind: .text, name: id, text: "")
    object.x = 0
    object.y = 0
    object.width = 800
    object.height = 200
    object.textLink = TextLink(source: source)
    return object
}

private func layout(_ objects: [SlideObject], width: Int? = nil, height: Int? = nil) -> ConfidenceLayout {
    ConfidenceLayout(
        id: "layout-1", name: "Band", objects: objects,
        canvasWidth: width, canvasHeight: height
    )
}

private func strings(in scene: RenderScene, layer: LayerKind = .slide) -> [String] {
    (scene.layers.first { $0.kind == layer }?.items ?? []).compactMap {
        if case .text(let styled) = $0.content { return styled.string }
        return nil
    }
}

@Test func layoutSceneResolvesLinkedText() {
    let scene = ConfidenceSceneBuilder.scene(
        layout: layout([linkedObject("a", .currentSlide), linkedObject("b", .lastSlide)]),
        info: fixtureInfo(), at: fixedDate
    )
    #expect(strings(in: scene).contains("current line"))
    #expect(strings(in: scene).contains("last line"))
}

@Test func layoutSceneHonorsItsCanvas() {
    let scene = ConfidenceSceneBuilder.scene(
        layout: layout([], width: 1280, height: 720),
        info: fixtureInfo(), at: fixedDate
    )
    #expect(scene.canvasSize == CGSize(width: 1280, height: 720))
    let defaulted = ConfidenceSceneBuilder.scene(
        layout: layout([]), info: fixtureInfo(), at: fixedDate
    )
    #expect(defaulted.canvasSize == SlideSceneBuilder.canvasSize)
}

@Test func bannerAppendsWhenTheLayoutHasNoStageMessageObject() {
    let alert = CueAlert(message: "Mics hot", behavior: .persist, target: .confidence)
    let scene = ConfidenceSceneBuilder.scene(
        layout: layout([linkedObject("a", .currentSlide)]),
        info: fixtureInfo(alert: alert), at: fixedDate
    )
    #expect(!strings(in: scene, layer: .alerts).isEmpty,
            "the message must still reach the glass without a stage-message box")
}

@Test func stageMessageObjectSuppressesTheBanner() {
    let alert = CueAlert(message: "Mics hot", behavior: .persist, target: .confidence)
    let scene = ConfidenceSceneBuilder.scene(
        layout: layout([linkedObject("m", .stageMessage)]),
        info: fixtureInfo(alert: alert), at: fixedDate
    )
    #expect(strings(in: scene, layer: .alerts).isEmpty,
            "a layout with its own stage-message box owns the presentation")
    #expect(strings(in: scene).contains("Mics hot"))
}

@Test func audienceOnlyAlertNeverReachesALayoutScene() {
    let alert = CueAlert(message: "Nursery", behavior: .persist, target: .audience)
    let scene = ConfidenceSceneBuilder.scene(
        layout: layout([linkedObject("a", .currentSlide)]),
        info: fixtureInfo(alert: alert), at: fixedDate
    )
    #expect(strings(in: scene, layer: .alerts).isEmpty)
}

@Test func defaultTemplateRendersTheClassicDashboardBoxed() {

    let scene = ConfidenceSceneBuilder.scene(
        layout: .defaultTemplate(name: "New Layout"), info: fixtureInfo(), at: fixedDate
    )
    let reads = strings(in: scene)
    for expected in ["17:26", "Bumper  2:00", "current line", "next line",
                     "TIME REMAINING", "VIDEO COUNTDOWN", "CLOCK",
                     "CURRENT SLIDE", "NEXT SLIDE"] {
        #expect(reads.contains(expected), "missing read '\(expected)'")
    }
    let shapes = (scene.layers.first { $0.kind == .slide }?.items ?? []).filter {
        if case .shape = $0.content { return true }
        return false
    }
    #expect(shapes.count == 5, "five module boxes: timer, video, clock, current, next")
}

private func templateScene(_ template: ConfidenceLayoutTemplate) -> RenderScene {
    ConfidenceSceneBuilder.scene(
        layout: template.make(name: template.title), info: fixtureInfo(), at: fixedDate
    )
}

private func shapeCount(in scene: RenderScene) -> Int {
    (scene.layers.first { $0.kind == .slide }?.items ?? []).filter {
        if case .shape = $0.content { return true }
        return false
    }.count
}

@Test func currentAndNextTemplateRendersItsModules() {
    let reads = strings(in: templateScene(.currentAndNext))
    for expected in ["current line", "next line", "17:26",
                     "CURRENT SLIDE", "NEXT SLIDE", "TIME REMAINING", "CLOCK"] {
        #expect(reads.contains(expected), "missing read '\(expected)'")
    }
    #expect(shapeCount(in: templateScene(.currentAndNext)) == 4,
            "four module boxes: current, next, timer, clock")
}

@Test func timersTemplateRendersTimingOnly() {
    let scene = templateScene(.timers)
    let reads = strings(in: scene)
    for expected in ["17:26", "Bumper  2:00",
                     "TIME REMAINING", "VIDEO COUNTDOWN", "CLOCK"] {
        #expect(reads.contains(expected), "missing read '\(expected)'")
    }
    #expect(!reads.contains("current line"), "a timers room never shows lyrics")
    #expect(shapeCount(in: scene) == 3)
}

@Test func currentOverNextTemplateStacksWithClockOnTop() {
    let scene = templateScene(.currentOverNext)
    let reads = strings(in: scene)
    for expected in ["current line", "next line", "CURRENT SLIDE", "NEXT SLIDE"] {
        #expect(reads.contains(expected), "missing read '\(expected)'")
    }

    let items = scene.layers.first { $0.kind == .slide }?.items ?? []
    func top(_ string: String) -> CGFloat? {
        items.first {
            if case .text(let styled) = $0.content { return styled.string == string }
            return false
        }?.frame.minY
    }
    let clockTop = items.compactMap { item -> CGFloat? in
        guard case .text(let styled) = item.content,
              styled.tabularFigures, styled.string != "17:26" else { return nil }
        return item.frame.minY
    }.min()
    if let clockTop, let currentTop = top("current line"), let nextTop = top("next line") {
        #expect(clockTop < currentTop && currentTop < nextTop)
    } else {
        Issue.record("expected clock, current, and next reads in the scene")
    }
}

@Test func mediaWantsCollectsObjectsFillsAndLiveInputs() {
    var media = SlideObject(id: "m", objectKind: .media, name: "BG", text: "")
    media.mediaId = "media-1"
    media.loops = true
    var filled = SlideObject(id: "s", objectKind: .shape, name: "Badge", text: "")
    filled.fill = ObjectFill(fillKind: .media, mediaId: "media-2")
    var input = SlideObject(id: "i", objectKind: .liveInput, name: "Cam", text: "")
    input.captureSourceKind = .camera
    input.captureSourceId = "cam-uid"

    let wants = SlideSceneBuilder.mediaWants(for: [media, filled, input])
    #expect(wants["media-1"] == .some(true))
    #expect(wants.keys.contains("media-2"))
    #expect(wants.keys.contains("input::camera::cam-uid"))
}
