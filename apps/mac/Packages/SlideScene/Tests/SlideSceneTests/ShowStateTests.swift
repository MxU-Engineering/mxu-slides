import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func slide(
    _ id: String, background: CueMedia? = nil, sectionId: String? = nil,
    actions: [SlideAction]? = nil
) -> Slide {
    Slide(
        id: id, name: id,
        objects: [SlideObject(id: "\(id)-text", objectKind: .text, name: "Text", text: "hi")],
        background: background, sectionId: sectionId, actions: actions
    )
}

private func presentation(_ slides: [Slide], background: CueMedia? = nil) -> Presentation {
    Presentation(
        id: "p", name: "Song", presentationKind: .deck, themeId: "",
        slides: slides, background: background
    )
}

private func cue(
    _ mediaId: String, mode: CueMediaMode? = nil, layer: CueMediaLayer? = nil,
    loops: Bool? = nil, classification: MediaClassification? = nil
) -> CueMedia {
    CueMedia(mediaId: mediaId, mode: mode, layer: layer, loops: loops, classification: classification)
}

@Test func sharedBackgroundNeverRestartsAcrossAdvance() {

    let a = slide("a", background: cue("ocean", loops: true))
    let b = slide("b", background: cue("ocean"))
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    let after = show.liveMedia[.loopingVideos]
    show.fire(slide: b, presentation: song)
    #expect(show.liveMedia[.loopingVideos] == after, "same media id = no-op, original kept")
}

@Test func slideWithoutBackgroundLeavesMediaAlone() {

    let a = slide("a", background: cue("ocean"))
    let b = slide("b")
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    show.fire(slide: b, presentation: song)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "ocean")
}

@Test func differentBackgroundReplacesOnItsLayer() {
    let a = slide("a", background: cue("ocean"))
    let b = slide("b", background: cue("fire"))
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    show.fire(slide: b, presentation: song)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "fire")
}

@Test func songScopedBackgroundFiresFromAnySlide() {

    let a = slide("a")
    let song = presentation([a], background: cue("ocean"))
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "ocean")
}

@Test func clearFunctionSlidesKeepsBackgroundLooping() {

    let a = slide("a", background: cue("ocean"))
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    show.clear(function: .slides)
    #expect(show.liveSlide == nil)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "ocean")
    let scene = show.scene()
    #expect(scene.layers.first { $0.kind == .slide }!.items.isEmpty)
    #expect(scene.layers.first { $0.kind == .loopingVideos }!.items.count == 1)
}

@Test func clearFunctionMediaDropsEveryMediaLayer() {
    let a = slide("a", background: cue("ocean"))
    let b = slide("b", background: cue("logo", layer: .stillGraphics))
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    show.fire(slide: b, presentation: song)
    show.clear(function: .media)
    #expect(show.liveMedia.isEmpty)
    #expect(show.liveSlide != nil, "slides function untouched")
}

@Test func clearLayerSweepsOnlyThatLayer() {
    let a = slide("a", background: cue("ocean"))
    let b = slide("b", background: cue("logo", layer: .stillGraphics))
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    show.fire(slide: b, presentation: song)
    show.clear(layer: .stillGraphics)
    #expect(show.liveMedia[.stillGraphics] == nil)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "ocean")
}

@Test func clearLayerSweepsAFiredVideoInput() {

    var show = ShowState()
    show.fire(
        media: CueMedia(mediaId: "camera::elgato", layer: .stillGraphics, loops: false),
        on: .videoInput)
    #expect(show.liveMedia[.videoInput] != nil)
    show.clear(layer: .videoInput)
    #expect(show.liveMedia[.videoInput] == nil)
}

@Test func overlayPersistsAcrossAdvancesAndClearsViaItsFunction() {

    let a = slide("a"), b = slide("b")
    let song = presentation([a, b])
    let third = Overlay(
        id: "l3", name: "Lower Third",
        objects: [SlideObject(id: "t", objectKind: .text, name: "Name", text: "Pastor")]
    )
    var show = ShowState()
    show.fire(slide: a, presentation: song)
    show.fire(overlay: third)
    show.fire(slide: b, presentation: song)
    #expect(show.liveOverlays.count == 1)
    #expect(show.scene().layers.first { $0.kind == .overlays }!.items.count == 1)
    show.clear(function: .overlays)
    #expect(show.liveOverlays.isEmpty)
    #expect(show.liveSlide?.slide.id == "b", "slide advance state untouched")
}

@Test func refiringALiveOverlayUpdatesInPlace() {
    var edited = Overlay(id: "l3", name: "Lower Third", objects: [])
    var show = ShowState()
    show.fire(overlay: edited)
    let second = Overlay(id: "other", name: "Other", objects: [])
    show.fire(overlay: second)
    edited.name = "Edited"
    show.fire(overlay: edited)
    #expect(show.liveOverlays.map(\.id) == ["l3", "other"], "no re-stack on re-fire")
    #expect(show.liveOverlays.first?.name == "Edited")
}

@Test func clearAllSweepsEveryFunction() {
    let a = slide("a", background: cue("ocean"))
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    show.fire(overlay: Overlay(id: "o", name: "O", objects: []))
    show.clearAll()
    #expect(show.liveSlide == nil)
    #expect(show.liveMedia.isEmpty)
    #expect(show.liveOverlays.isEmpty)
}

@Test func signageFunctionNeverTouchesTheRoomShow() {

    let a = slide("a", background: cue("ocean"))
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    show.fire(overlay: Overlay(id: "o", name: "O", objects: []))
    show.clear(function: .signage)
    #expect(show.liveSlide != nil)
    #expect(!show.liveMedia.isEmpty)
    #expect(!show.liveOverlays.isEmpty)
}

@Test func wantedMediaCarriesLoopOverridesAndSlideObjects() {
    var mediaObject = SlideObject(id: "m", objectKind: .media, name: "Clip", text: "")
    mediaObject.mediaId = "clip"
    let a = Slide(id: "a", name: "a", objects: [mediaObject], background: cue("ocean", loops: false))
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    let wanted = show.wantedMedia()
    #expect(wanted["ocean"] == Bool??.some(false), "cue loop override rides along")
    #expect(wanted.keys.contains("clip"), "slide media objects are wanted too")
}

@Test func wantedMediaIncludesShapeMediaFills() {

    var badge = SlideObject(id: "b", objectKind: .shape, name: "Badge", text: "")
    badge.shapeKind = .ellipse
    badge.fill = ObjectFill(fillKind: .media, mediaId: "fill-clip")
    let a = Slide(id: "a", name: "a", objects: [badge])
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    #expect(show.wantedMedia().keys.contains("fill-clip"))
}

@Test func wantedMediaCarriesObjectAndFillLoopOverrides() {

    var clip = SlideObject(id: "m", objectKind: .media, name: "Clip", text: "")
    clip.mediaId = "obj-clip"
    clip.loops = true
    var badge = SlideObject(id: "b", objectKind: .shape, name: "Badge", text: "")
    badge.shapeKind = .ellipse
    var fill = ObjectFill(fillKind: .media, mediaId: "fill-clip")
    fill.loops = false
    badge.fill = fill
    let a = Slide(id: "a", name: "a", objects: [clip, badge])
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    let wanted = show.wantedMedia()
    #expect(wanted["obj-clip"] == Bool??.some(true))
    #expect(wanted["fill-clip"] == Bool??.some(false))
}

@Test func standaloneMediaFiresWithDedupe() {

    var show = ShowState()
    show.fire(media: cue("walkin", loops: true), on: .loopingVideos)
    let first = show.liveMedia[.loopingVideos]
    show.fire(media: cue("walkin"), on: .loopingVideos)
    #expect(show.liveMedia[.loopingVideos] == first, "same id = no-op")
    show.fire(media: cue("sermon-bumper"), on: .videos)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "walkin", "other layers untouched")
    #expect(show.liveMedia[.videos]?.mediaId == "sermon-bumper")
}

@Test func firedForegroundStillSweepsOnSlideFire() {
    var show = ShowState()
    show.fire(media: cue("logo"), on: .stillGraphics)
    #expect(show.liveMedia[.stillGraphics]?.mediaId == "logo")
    show.fire(slide: slide("verse1"), presentation: presentation([slide("verse1")]))
    #expect(show.liveMedia[.stillGraphics] == nil, "the next slide clears a fired foreground still")
    #expect(!show.directMediaFires.contains(.stillGraphics))
}

@Test func foregroundStillSurvivesWhenIncomingSlideRedeclaresIt() {

    var show = ShowState()
    show.fire(media: cue("logo"), on: .stillGraphics)
    let keeps = slide(
        "b", actions: [SlideAction(id: "a1", kind: .fireMedia, mediaId: "logo")]
    )
    show.fire(slide: keeps, presentation: presentation([keeps]))
    #expect(show.liveMedia[.stillGraphics]?.mediaId == "logo", "re-declared still never flashes out")
    let drops = slide(
        "c", actions: [SlideAction(id: "a2", kind: .fireMedia, mediaId: "other")]
    )
    show.fire(slide: drops, presentation: presentation([drops]))
    #expect(show.liveMedia[.stillGraphics] == nil, "a different declaration doesn't protect it")
}

@Test func foregroundStampedStillAttachmentLeavesWithItsSlide() {

    let a = slide("a", background: cue("mountains", layer: .stillGraphics, classification: .foreground))
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    #expect(show.liveMedia[.stillGraphics]?.mediaId == "mountains")
    let other = slide("sermon1")
    show.fire(slide: other, presentation: Presentation(
        id: "p2", name: "Sermon", presentationKind: .deck, themeId: "", slides: [other]
    ))
    #expect(show.liveMedia[.stillGraphics] == nil, "a foreground still leaves with its slide")
}

@Test func backgroundStillOnStillGraphicsPersistsStampedOrNot() {

    for stamp in [MediaClassification.background, nil] {
        let a = slide("a", background: cue("mountains", layer: .stillGraphics, classification: stamp))
        var show = ShowState()
        show.fire(slide: a, presentation: presentation([a]))
        let other = slide("sermon1")
        show.fire(slide: other, presentation: Presentation(
            id: "p2", name: "Sermon", presentationKind: .deck, themeId: "", slides: [other]
        ))
        #expect(show.liveMedia[.stillGraphics]?.mediaId == "mountains", "background persists (stamp: \(String(describing: stamp)))")
    }
}

@Test func backgroundStampedVideoOnForegroundVideosPersists() {

    let a = slide("a", background: cue("bumper", layer: .videos, classification: .background))
    var show = ShowState()
    show.fire(slide: a, presentation: presentation([a]))
    show.fire(slide: slide("b"), presentation: presentation([a, slide("b")]))
    #expect(show.liveMedia[.videos]?.mediaId == "bumper")
    let unstamped = slide("c", background: cue("bumper2", layer: .videos))
    show.fire(slide: unstamped, presentation: presentation([unstamped]))
    show.fire(slide: slide("d"), presentation: presentation([slide("d")]))
    #expect(show.liveMedia[.videos] == nil, "unstamped on Foreground Videos still reads foreground")
}

@Test func firedBackgroundMediaStillPersistsAcrossSlideFires() {

    var show = ShowState()
    show.fire(media: cue("bg-still"), on: .loopingVideos)
    show.fire(slide: slide("verse1"), presentation: presentation([slide("verse1")]))
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "bg-still")
}

@Test func scopedClearAllKeepsTheFiredSlideAndItsBackground() {
    let verse = slide("verse1", background: cue("ocean"))
    var show = ShowState()
    show.fire(media: cue("old-bumper"), on: .videos)
    show.fire(overlay: Overlay(id: "o1", name: "Lower Third", objects: []))
    show.fire(audio: CueAudio(audioItemId: "walkin"))
    show.fire(slide: verse, presentation: presentation([verse]))
    show.clearAll(protecting: [.slide, .loopingVideos])
    #expect(show.liveSlide?.slide.id == "verse1", "the fire's own slide survives its clear")
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "ocean", "the fire's own background survives")
    #expect(show.liveMedia[.videos] == nil, "the stage being left sweeps")
    #expect(show.liveOverlays.isEmpty)
    #expect(show.liveAudio.isEmpty, "audio clears with the setting, exactly like the full form")
}

@Test func scopedClearAllHonorsTheAudioSetting() {
    var show = ShowState()
    show.fire(audio: CueAudio(audioItemId: "walkin"))
    show.clearAll(includingAudio: false, protecting: [.slide])
    #expect(!show.liveAudio.isEmpty, "walk-in music survives when the panic clear excludes audio")
}

@Test func emptyProtectionIsTheFullPanicClear() {
    let verse = slide("verse1", background: cue("ocean"))
    var show = ShowState()
    show.fire(slide: verse, presentation: presentation([verse]))
    show.clearAll(protecting: [])
    #expect(show.liveSlide == nil)
    #expect(show.liveMedia.isEmpty)
}

@Test func untilReplacedCoversFollowingSlidesOnFire() {

    let a = slide("a", background: cue("ocean", mode: .untilReplaced))
    let b = slide("b")
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(slide: b, presentation: song)
    #expect(show.liveMedia[.loopingVideos]?.mediaId == "ocean")
}

@Test func audioPersistsAcrossSlideAdvancesAndClears() {
    let a = slide("a"), b = slide("b")
    let song = presentation([a, b])
    var show = ShowState()
    show.fire(audio: CueAudio(playlistId: "walkin"))
    show.fire(slide: a, presentation: song)
    show.fire(slide: b, presentation: song)
    #expect(show.liveAudio == [CueAudio(playlistId: "walkin")], "advances never touch audio")
    show.clear(function: .slides)
    #expect(!show.liveAudio.isEmpty, "clearing slides keeps the music playing")
    show.clear(function: .audio)
    #expect(show.liveAudio.isEmpty)
}

@Test func refiringSameAudioIsANoOpAndBusesCoexist() {

    var show = ShowState()
    show.fire(audio: CueAudio(playlistId: "walkin"))
    let first = show.liveAudio
    show.fire(audio: CueAudio(playlistId: "walkin"))
    #expect(show.liveAudio == first, "double-tap never restarts walk-in music")
    show.fire(audio: CueAudio(playlistId: "broadcast"))
    #expect(show.liveAudio.count == 2, "different targets play simultaneously")
    show.dismissAudio(CueAudio(playlistId: "walkin"))
    #expect(show.liveAudio == [CueAudio(playlistId: "broadcast")], "replacement dismisses one cue")
}

@Test func clearLayerNeverReachesAudio() {
    var show = ShowState()
    show.fire(audio: CueAudio(playlistId: "walkin"))
    for layer in LayerKind.allCases { show.clear(layer: layer) }
    #expect(!show.liveAudio.isEmpty, "audio is layerless — only its function sweeps it")
}

@Test func clearAllRespectsTheAudioSettingAndSweepsEveryBus() {
    var show = ShowState()
    show.fire(audio: CueAudio(playlistId: "walkin"))
    show.fire(audio: CueAudio(playlistId: "broadcast"))
    show.clearAll(includingAudio: false)
    #expect(show.liveAudio.count == 2, "panic clear can spare the walk-in music")
    show.clearAll()
    #expect(show.liveAudio.isEmpty, "default Clear All sweeps every audio bus")
}

@Test func fireStampsTickerAnchorsIntoTheScene() {
    var state = ShowState()
    state.fire(slide: slide("a"), atHostTime: 1234.5)
    let items = state.scene().layers.first { $0.kind == .slide }!.items
    #expect(!items.isEmpty)
    #expect(items.allSatisfy { $0.tickerAnchorHostTime == 1234.5 })

    state.fire(slide: slide("a"), atHostTime: 2000)
    let restamped = state.scene().layers.first { $0.kind == .slide }!.items
    #expect(restamped.allSatisfy { $0.tickerAnchorHostTime == 2000 })
}

@Test func overlayAnchorsStampPruneAndSurviveReSnapshot() {
    var state = ShowState()
    let overlay = Overlay(id: "ov", name: "Badge", objects: [
        SlideObject(id: "o1", objectKind: .text, name: "t", text: "LIVE"),
    ])
    state.fire(overlay: overlay, atHostTime: 77)

    let first = state.scene().layers.first { $0.kind == .overlays }!.items
    let second = state.scene().layers.first { $0.kind == .overlays }!.items
    #expect(first == second)
    #expect(first.allSatisfy { $0.tickerAnchorHostTime == 77 })

    state.dismissOverlay(id: "ov")
    #expect(state.overlayFiredAt.isEmpty, "dismiss prunes the anchor map")

    state.fire(overlay: overlay, atHostTime: 88)
    state.clear(function: .overlays)
    #expect(state.overlayFiredAt.isEmpty, "clear-function prunes the anchor map")

    state.fire(overlay: overlay, atHostTime: 99)
    state.clear(layer: .overlays)
    #expect(state.overlayFiredAt.isEmpty, "clear-layer sweep prunes the anchor map")
}

@Test func alertAnchorRidesItsItems() {
    var state = ShowState()
    state.fire(alert: CueAlert(
        id: "al", message: "Car lights on", behavior: .persist, target: .audience,
        theme: nil, layer: nil
    ), atHostTime: 55)
    let items = state.scene().layers.first { $0.kind == .alerts }!.items
    #expect(!items.isEmpty)
    #expect(items.allSatisfy { $0.tickerAnchorHostTime == 55 })
}

@Test func lastSlideTracksFiredHistoryNotOrder() {
    var show = ShowState()
    show.fire(slide: slide("chorus"), presentation: nil)
    show.fire(slide: slide("verse3"), presentation: nil)
    #expect(show.lastSlide?.slide.id == "chorus",
            "last = what was actually live before this, jumps included")
}

@Test func refiringTheLiveSlideNeverEntersHistory() {
    var show = ShowState()
    show.fire(slide: slide("a"), presentation: nil)
    show.fire(slide: slide("b"), presentation: nil)
    show.fire(slide: slide("b"), presentation: nil)
    #expect(show.lastSlide?.slide.id == "a",
            "a re-fire must not read itself as last")
}

@Test func lastSlideSurvivesAClear() {
    var show = ShowState()
    show.fire(slide: slide("a"), presentation: nil)
    show.clear(function: .slides)
    show.fire(slide: slide("b"), presentation: nil)
    #expect(show.lastSlide?.slide.id == "a",
            "fire A, clear, fire B — the room last saw A")
}

@Test func firstFireHasNoHistory() {
    var show = ShowState()
    show.fire(slide: slide("a"), presentation: nil)
    #expect(show.lastSlide == nil)
}

private func linkedSlide(_ id: String, source: TextSourceKind, timerPattern: String? = nil) -> Slide {
    var object = SlideObject(id: "\(id)-linked", objectKind: .text, name: "Linked", text: "stored text")
    object.x = 0; object.y = 0; object.width = 800; object.height = 200
    object.textLink = TextLink(source: source, timerPattern: timerPattern)
    return Slide(id: id, name: id, objects: [object])
}

private func slideLayerStrings(_ scene: RenderScene) -> [String] {
    (scene.layers.first { $0.kind == .slide }?.items ?? []).compactMap {
        if case .text(let styled) = $0.content { return styled.string }
        return nil
    }
}

@Test func programSceneResolvesLinkedTextAgainstSuppliedInfo() {
    var show = ShowState()
    show.fire(slide: linkedSlide("a", source: .currentSlide), presentation: nil)
    let info = ConfidenceInfo(current: .init(body: "resolved line"))
    let scene = show.scene(linkedText: info, at: Date(timeIntervalSince1970: 1_784_800_000))
    #expect(slideLayerStrings(scene).contains("resolved line"))
    #expect(!slideLayerStrings(scene).contains("stored text"),
            "resolution replaces the stored string, never shows it")
}

@Test func programSceneWithoutInfoKeepsStoredTextVerbatim() {
    var show = ShowState()
    show.fire(slide: linkedSlide("a", source: .currentSlide), presentation: nil)
    #expect(slideLayerStrings(show.scene()).contains("stored text"),
            "nil info = the pre-M3.5 behavior, byte for byte")
}

@Test func overlayLinkedTextResolvesToo() {
    var show = ShowState()
    var object = SlideObject(id: "o-linked", objectKind: .text, name: "Msg", text: "")
    object.textLink = TextLink(source: .stageMessage)
    show.fire(overlay: Overlay(id: "o", name: "Lower Third", objects: [object]))
    let info = ConfidenceInfo(
        alert: CueAlert(message: "Mics hot", behavior: .persist, target: .confidence)
    )
    let scene = show.scene(linkedText: info, at: Date(timeIntervalSince1970: 1_784_800_000))
    let overlayItems = scene.layers.first { $0.kind == LayerKind.overlays }?.items ?? []
    let overlayStrings: [String] = overlayItems.compactMap { item in
        if case .text(let styled) = item.content { return styled.string }
        return nil
    }
    #expect(overlayStrings.contains("Mics hot"))
}

@Test func linkedTextTickIntervalFollowsThePattern() {
    var show = ShowState()
    #expect(show.linkedTextTickInterval(slideThemeOverrides: []) == nil)
    show.fire(slide: linkedSlide("a", source: .clock), presentation: nil)
    #expect(show.linkedTextTickInterval(slideThemeOverrides: []) == 1.0)
    show.fire(slide: linkedSlide("b", source: .timer, timerPattern: "s.ff"), presentation: nil)
    #expect(show.linkedTextTickInterval(slideThemeOverrides: []) == LinkedText.subSecondTickInterval,
            "hundredths need more than the 1 Hz nudge")
    show.clear(function: .slides)
    #expect(show.linkedTextTickInterval(slideThemeOverrides: []) == nil)
}

@Test func timeVarianceFollowsTheLiveComposition() {
    var show = ShowState()
    #expect(!show.hasTimeVaryingLinkedText)
    show.fire(slide: linkedSlide("a", source: .clock), presentation: nil)
    #expect(show.hasTimeVaryingLinkedText)
    #expect(show.hasLinkedText)
    show.clear(function: .slides)
    #expect(!show.hasTimeVaryingLinkedText)
    show.fire(slide: linkedSlide("b", source: .nextSlide), presentation: nil)
    #expect(show.hasLinkedText)
    #expect(!show.hasTimeVaryingLinkedText, "next-slide text changes on fire, not per second")
}
