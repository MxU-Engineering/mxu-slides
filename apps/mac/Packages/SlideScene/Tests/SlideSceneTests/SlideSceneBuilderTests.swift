import CoreGraphics
import Foundation
import PresenterCore
@testable import RenderEngine
import Testing
@testable import SlideScene

private let theme = Theme(
    id: "t", name: "Default", fontFamily: "Helvetica Neue",
    fontSize: 96, textColorHex: "#FFCC00", backgroundColorHex: "#101820"
)

@Test func effectiveAutoAdvancePrefersTheSlide() {

    let docLevel = AutoAdvance(delaySeconds: 5, loopToStart: true)
    let own = AutoAdvance(delaySeconds: 12)
    var presentation = Presentation(
        id: "p", name: "Deck", presentationKind: .deck, themeId: "",
        slides: [Slide(id: "s", name: "", objects: [])]
    )
    presentation.autoAdvance = docLevel
    var slide = presentation.slides[0]
    #expect(SlideSceneBuilder.effectiveAutoAdvance(slide: slide, presentation: presentation) == docLevel)
    slide.autoAdvance = own
    #expect(SlideSceneBuilder.effectiveAutoAdvance(slide: slide, presentation: presentation) == own)
    presentation.autoAdvance = nil
    slide.autoAdvance = nil
    #expect(SlideSceneBuilder.effectiveAutoAdvance(slide: slide, presentation: presentation) == nil)
}

@Test func autoAdvanceTargetWalksWrapsAndEnds() {

    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 0, count: 3, loopToStart: false) == 1)
    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 2, count: 3, loopToStart: false) == nil)
    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 2, count: 3, loopToStart: true) == 0)

    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 0, count: 1, loopToStart: true) == 0)
    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 0, count: 1, loopToStart: false) == nil)

    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 5, count: 3, loopToStart: true) == nil)
    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: -1, count: 3, loopToStart: true) == nil)
    #expect(SlideSceneBuilder.autoAdvanceTarget(occurrence: 0, count: 0, loopToStart: true) == nil)
}

@Test func colorHexRoundTrips() {
    #expect(ColorHex.color("#FFFFFF") == .white)
    #expect(ColorHex.color("#000000FF") == SceneColor(red: 0, green: 0, blue: 0, alpha: 1))
    let translucent = ColorHex.color("#FF000080")
    #expect(translucent?.red == 1)
    #expect(abs((translucent?.alpha ?? 0) - 128.0 / 255) < 0.001)
    #expect(ColorHex.hex(SceneColor(red: 1, green: 0, blue: 0, alpha: 1)) == "#FF0000FF")
    #expect(ColorHex.color("nonsense") == nil)
    #expect(ColorHex.color("#12345") == nil)
}

@Test func v3ObjectsGetThemeAndDefaultPlacement() {

    let slide = Slide(id: "s", name: "Verse", objects: [
        SlideObject(id: "text", objectKind: .text, name: "Lyrics", text: "Amazing grace"),
    ])
    let scene = SlideSceneBuilder.scene(for: slide, theme: theme)

    #expect(scene.background == ColorHex.color("#101820"))
    let textLayer = scene.layers.first { $0.kind == .slide }!
    #expect(textLayer.items.count == 1)
    let item = textLayer.items[0]
    #expect(item.frame == SlideSceneBuilder.defaultFrame(for: .text))
    guard case .text(let styled) = item.content else {
        Issue.record("expected text content")
        return
    }
    #expect(styled.fontName == "Helvetica Neue")
    #expect(styled.fontSize == 96)
    #expect(styled.color == ColorHex.color("#FFCC00"))
}

@Test func explicitStyleOverridesTheme() {
    var object = SlideObject(id: "text", objectKind: .text, name: "Lyrics", text: "Line")
    object.x = 100; object.y = 200; object.width = 800; object.height = 300
    object.rotationDegrees = -3
    object.opacity = 0.8
    object.blendMode = .screen
    object.textStyle = TextStyle(
        fontName: "HelveticaNeue-Bold", fontSize: 120, colorHex: "#FFFFFFFF",
        tracking: 2, lineHeightMultiple: 1.3,
        horizontalAlignment: .left, verticalAlignment: .bottom,
        textTransform: .uppercase, tabularFigures: true, autoShrink: true, minFontSize: 40,
        outline: ObjectStroke(colorHex: "#000000FF", width: 3),
        shadow: ObjectShadow(colorHex: "#00000080", blurRadius: 10, offsetX: 0, offsetY: 4),
        lineStyles: [LineStyleOverride(lineIndex: 1, fontSize: 60, leftIndent: 90)],
        insetTop: 12, insetLeft: 16, insetBottom: 8, insetRight: 20,
        firstLineIndent: -30, leftIndent: 60, rightIndent: 40, paragraphSpacing: 24
    )
    let item = SlideSceneBuilder.renderItem(for: object, theme: theme)

    #expect(item.frame == CGRect(x: 100, y: 200, width: 800, height: 300))
    #expect(item.rotationDegrees == -3)
    #expect(item.opacity == 0.8)
    #expect(item.blendMode == .screen)
    guard case .text(let styled) = item.content else {
        Issue.record("expected text content")
        return
    }
    #expect(styled.fontName == "HelveticaNeue-Bold")
    #expect(styled.fontSize == 120)
    #expect(styled.tracking == 2)
    #expect(styled.lineHeightMultiple == 1.3)
    #expect(styled.alignment == .left)
    #expect(styled.verticalAlignment == .bottom)
    #expect(styled.transform == .uppercase)
    #expect(styled.tabularFigures)
    #expect(styled.autoShrink)
    #expect(styled.minFontSize == 40)
    #expect(styled.outline == TextOutline(color: .black, width: 3))
    #expect(styled.shadow?.blurRadius == 10)
    #expect(styled.lineOverrides == [TextLineOverride(lineIndex: 1, fontSize: 60, leftIndent: 90)])
    #expect(styled.insetTop == 12)
    #expect(styled.insetLeft == 16)
    #expect(styled.insetBottom == 8)
    #expect(styled.insetRight == 20)
    #expect(styled.firstLineIndent == -30)
    #expect(styled.leftIndent == 60)
    #expect(styled.rightIndent == 40)
    #expect(styled.paragraphSpacing == 24)
}

@Test func textFillMapsThroughTheOneFillModel() {
    var object = SlideObject(id: "text", objectKind: .text, name: "Lyrics", text: "Line")
    object.textStyle = TextStyle(fill: ObjectFill(
        fillKind: .linearGradient,
        gradientAngleDegrees: 45,
        gradientStops: [
            GradientStop(colorHex: "#FF0000FF", position: 0),
            GradientStop(colorHex: "#0000FFFF", position: 1),
        ]
    ))
    guard case .text(let styled) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected text content")
        return
    }
    guard case .linearGradient(let angle, let stops)? = styled.fill else {
        Issue.record("expected gradient ink fill")
        return
    }
    #expect(angle == 45)
    #expect(stops.count == 2)

    object.textStyle = TextStyle(colorHex: "#FFFFFFFF", fill: ObjectFill(fillKind: .media, mediaId: "m1"))
    guard case .text(let degraded) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected text content")
        return
    }
    #expect(degraded.fill == nil)
    #expect(degraded.color == .white)
}

@Test func lineFillMapsWithDefaultsAndDegradesMedia() {
    var object = SlideObject(id: "text", objectKind: .text, name: "Lyrics", text: "Line")
    object.textStyle = TextStyle(lineFill: TextLineFill(
        fill: ObjectFill(fillKind: .solid, colorHex: "#000000FF"),
        horizontalPadding: 8, verticalOffset: -4, cornerRadius: 12
    ))
    guard case .text(let styled) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected text content")
        return
    }
    let lineFill = styled.lineFill
    #expect(lineFill?.fill == .solid(SceneColor(red: 0, green: 0, blue: 0, alpha: 1)))

    #expect(lineFill?.widthMode == .fullWidth)
    #expect(lineFill?.verticalPadding == 0)
    #expect(lineFill?.horizontalPadding == 8)
    #expect(lineFill?.verticalOffset == -4)
    #expect(lineFill?.horizontalOffset == 0)
    #expect(lineFill?.cornerRadius == 12)

    object.textStyle = TextStyle(lineFill: TextLineFill(fill: ObjectFill(fillKind: .media, mediaId: "m1")))
    guard case .text(let degraded) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected text content")
        return
    }
    #expect(degraded.lineFill == nil)
}

@Test func shapeObjectsResolveGeometryAndFill() {
    var object = SlideObject(id: "shape", objectKind: .shape, name: "Panel", text: "")
    object.shapeKind = .roundedRectangle
    object.cornerRadius = 24
    object.fill = ObjectFill(
        fillKind: .linearGradient,
        gradientAngleDegrees: 90,
        gradientStops: [
            GradientStop(colorHex: "#000000FF", position: 0),
            GradientStop(colorHex: "#FFFFFFFF", position: 1),
        ]
    )
    object.stroke = ObjectStroke(colorHex: "#FF0000FF", width: 2)
    let item = SlideSceneBuilder.renderItem(for: object, theme: nil)

    guard case .shape(let style) = item.content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.kind == .roundedRectangle(cornerRadius: 24))
    guard case .linearGradient(let angle, let stops) = style.fill else {
        Issue.record("expected gradient fill")
        return
    }
    #expect(angle == 90)
    #expect(stops.count == 2)
    #expect(style.stroke == SceneStroke(color: SceneColor(red: 1, green: 0, blue: 0), width: 2))
}

@Test func shapeMediaFillMapsToSceneMedia() {

    var object = SlideObject(id: "shape", objectKind: .shape, name: "Badge", text: "")
    object.shapeKind = .ellipse
    object.fill = ObjectFill(fillKind: .media, mediaId: "clip", mediaScaleMode: .fit)
    guard case .shape(let style) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.fill == .media(id: "clip", scaleMode: .fit))
    #expect(SlideSceneBuilder.fillMediaID(object) == "clip")

    object.fill?.mediaSourceRect = MediaSourceRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
    guard case .shape(let cropped) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(cropped.fill == .media(
        id: "clip", scaleMode: .fit,
        sourceRect: SceneSourceRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
    ))
    object.fill?.mediaSourceRect = MediaSourceRect(x: 0, y: 0, width: 1, height: 1)
    guard case .shape(let whole) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(whole.fill == .media(id: "clip", scaleMode: .fit))

    object.fill = ObjectFill(fillKind: .media)
    guard case .shape(let empty) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(empty.fill == SceneFill.none)
    #expect(SlideSceneBuilder.fillMediaID(object) == nil)
}

@Test func shapeLiveVideoFillMapsToInputEngineID(){

    var object = SlideObject(id: "shape", objectKind: .shape, name: "PIP", text: "")
    object.shapeKind = .roundedRectangle
    var fill = ObjectFill(fillKind: .media, mediaId: "clip")
    fill.captureSourceKind = .camera
    fill.captureSourceId = "cam-1"
    object.fill = fill
    guard case .shape(let style) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.fill == .media(id: "input::camera::cam-1", scaleMode: .fill))
    #expect(SlideSceneBuilder.fillLiveInputID(object) == "input::camera::cam-1")
    #expect(SlideSceneBuilder.fillMediaID(object) == nil, "the library want-list must not open input ids")
}

@Test func screenMirrorWinsOverCaptureOverMedia() {

    var shape = SlideObject(id: "shape", objectKind: .shape, name: "Mirror", text: "")
    shape.shapeKind = .rectangle
    var fill = ObjectFill(fillKind: .media, mediaId: "clip", mediaScaleMode: .fit)
    fill.captureSourceKind = .camera
    fill.captureSourceId = "cam-1"
    fill.screenSourceId = "screen-a"
    shape.fill = fill
    guard case .shape(let style) = SlideSceneBuilder.renderItem(for: shape, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.fill == .media(id: "screen::screen-a", scaleMode: .fit))
    #expect(SlideSceneBuilder.fillScreenMirrorID(shape) == "screen::screen-a")
    #expect(SlideSceneBuilder.fillLiveInputID(shape) == nil, "screen wins over capture")
    #expect(SlideSceneBuilder.fillMediaID(shape) == nil, "the library want-list must not open screen ids")

    var input = SlideObject(id: "live", objectKind: .liveInput, name: "Mon", text: "")
    input.captureSourceKind = .camera
    input.captureSourceId = "cam-1"
    input.screenSourceId = "screen-b"
    guard case .shape(let inputStyle) = SlideSceneBuilder.renderItem(for: input, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(inputStyle.fill == .media(id: "screen::screen-b", scaleMode: .fill))
    #expect(SlideSceneBuilder.fillScreenMirrorID(input) == "screen::screen-b")
}

@Test func mediaWantsCollectScreenMirrors() {

    var mirrorObject = SlideObject(id: "m", objectKind: .media, name: "Mon", text: "")
    mirrorObject.mediaId = "media-1"
    mirrorObject.screenSourceId = "screen-a"
    var mirrorFill = SlideObject(id: "s", objectKind: .shape, name: "Badge", text: "")
    var fill = ObjectFill(fillKind: .media, mediaId: "media-2")
    fill.screenSourceId = "screen-b"
    mirrorFill.fill = fill

    let wants = SlideSceneBuilder.mediaWants(for: [mirrorObject, mirrorFill])
    #expect(wants.keys.contains("screen::screen-a"))
    #expect(wants.keys.contains("screen::screen-b"))
    #expect(!wants.keys.contains("media-1"))
    #expect(!wants.keys.contains("media-2"))
}

@Test func maskWiringStampsMaskedAndMatteItems() {

    var subject = SlideObject(id: "subject", objectKind: .shape, name: "Panel", text: "hi")
    subject.shapeKind = .rectangle
    subject.maskObjectId = "matte"
    subject.maskMode = .out
    var matte = SlideObject(id: "matte", objectKind: .shape, name: "Circle", text: "")
    matte.shapeKind = .ellipse
    matte.maskObjectId = "subject" 
    var loner = SlideObject(id: "loner", objectKind: .text, name: "T", text: "x")
    loner.maskObjectId = "ghost" 

    let objects = [subject, matte, loner]
    let wiring = SlideSceneBuilder.maskWiring(for: objects)
    #expect(wiring.maskedBy["subject"]?.matte == "matte")
    #expect(wiring.maskedBy["subject"]?.out == true)
    #expect(wiring.mattes.contains("matte"))
    #expect(wiring.maskedBy["loner"] == nil)

    let items = SlideSceneBuilder.renderItems(
        for: subject, theme: nil,
        maskedBy: wiring.maskedBy["subject"],
        matteGroup: wiring.mattes.contains("subject") ? "subject" : nil
    )
    #expect(items.count == 2, "shape + its ::text pair")
    for item in items {
        #expect(item.maskedBy == "matte")
        #expect(item.maskOut == true)
    }
}

@Test func effectChainMapsInOrderAndAdjustmentStaysOnPrimary() {

    var object = SlideObject(id: "s", objectKind: .shape, name: "Panel", text: "hi")
    object.shapeKind = .rectangle
    object.effects = [
        Effect(effectKind: .colorAdjust, brightness: 0.1, contrast: 0, saturation: 0),
        Effect(effectKind: .blur, radius: 10),
        Effect(effectKind: .blur, radius: 0),
    ]
    let item = SlideSceneBuilder.renderItem(for: object, theme: nil)
    #expect(item.effects == [
        .colorAdjust(brightness: 0.1, contrast: 0, saturation: 0),
        .blur(radius: 10),
    ])

    object.effectsApplyBelow = true
    let items = SlideSceneBuilder.renderItems(for: object, theme: nil)
    #expect(items.count == 2)
    #expect(items[0].effectsApplyBelow)
    #expect(!items[1].effectsApplyBelow, "the region round-trip runs once")
    #expect(items[1].effects.isEmpty)
}

@Test func shapeDefaultsAreVisible() {

    let object = SlideObject(id: "shape", objectKind: .shape, name: "Panel", text: "")
    guard case .shape(let style) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.kind == .rectangle)
    #expect(style.fill == .solid(.white))
}

@Test func mediaObjectsCarryIdAndScaleMode() {

    var object = SlideObject(id: "img", objectKind: .media, name: "Background", text: "")
    object.mediaId = "media-42"
    object.mediaScaleMode = .fit
    let item = SlideSceneBuilder.renderItem(for: object, theme: nil)
    guard case .shape(let style) = item.content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.kind == .rectangle)
    #expect(style.fill == .media(id: "media-42", scaleMode: .fit))

    object.mediaSourceRect = MediaSourceRect(x: 0.25, y: 0, width: 0.5, height: 1)
    guard case .shape(let croppedStyle) = SlideSceneBuilder.renderItem(for: object, theme: nil).content,
          case .media(_, _, let cropped) = croppedStyle.fill else {
        Issue.record("expected media-filled shape content")
        return
    }
    #expect(cropped == SceneSourceRect(x: 0.25, y: 0, width: 0.5, height: 1))
}

@Test func quickEditTextRebuildLeavesMediaItemsIdentical() {

    var video = SlideObject(id: "bg", objectKind: .media, name: "Loop", text: "")
    video.mediaId = "media-7"
    var lyric = SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Amazig grace")
    var slide = Slide(id: "s", name: "Verse", objects: [video, lyric])

    let before = SlideSceneBuilder.scene(for: slide, theme: theme)
    lyric.text = "Amazing grace"
    slide.objects[1] = lyric
    let after = SlideSceneBuilder.scene(for: slide, theme: theme)

    func mediaItems(_ scene: RenderScene) -> [RenderItem] {

        scene.layers.flatMap(\.items).filter { $0.content.mediaID != nil }
    }
    #expect(mediaItems(before).count == 1)
    #expect(mediaItems(before) == mediaItems(after))
    #expect(
        before.layers.flatMap(\.items) != after.layers.flatMap(\.items),
        "the typo fix must actually reach the text item"
    )
}

@Test func cueBackgroundRendersOnItsMediaLayerBelowSlide() {
    var slide = Slide(id: "s", name: "Verse", objects: [
        SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Line"),
    ])
    slide.background = CueMedia(mediaId: "media-9", layer: .loopingVideos)
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil)

    let background = scene.layers.first { $0.kind == .loopingVideos }!.items
    #expect(background.count == 1)
    #expect(background[0].content == .media(id: "media-9", scaleMode: .fill))
    #expect(background[0].frame == CGRect(origin: .zero, size: SlideSceneBuilder.canvasSize))

    let layerOrder = scene.layers.map(\.kind)
    #expect(layerOrder.firstIndex(of: .loopingVideos)! < layerOrder.firstIndex(of: .slide)!)

    slide.background = CueMedia(mediaId: "media-9")
    #expect(SlideSceneBuilder.layerKind(slide.background?.layer) == .loopingVideos)
    slide.background = nil
    let bare = SlideSceneBuilder.scene(for: slide, theme: nil)
    #expect(bare.layers.first { $0.kind == .loopingVideos }!.items.isEmpty)
}

@Test func fireMediaPosterIDsSplitByGlassOrder() {

    var still = SlideAction(id: "a1", kind: .fireMedia); still.mediaId = "still"
    var bgVideo = SlideAction(id: "a2", kind: .fireMedia); bgVideo.mediaId = "bg-video"
    var fgVideo = SlideAction(id: "a3", kind: .fireMedia); fgVideo.mediaId = "fg-video"
    var gone = SlideAction(id: "a4", kind: .fireMedia); gone.mediaId = "gone"
    var dupe = SlideAction(id: "a5", kind: .fireMedia); dupe.mediaId = "still"
    let combo = SlideAction(id: "a6", kind: .fireCombo)
    let slide = Slide(
        id: "s", name: "", objects: [],
        actions: [still, bgVideo, fgVideo, gone, dupe, combo]
    )
    let facts: [String: (kind: MediaKind, classification: MediaClassification)] = [
        "still": (.image, .foreground),
        "bg-video": (.video, .background),
        "fg-video": (.video, .foreground),
    ]
    let posters = SlideSceneBuilder.fireMediaPosterIDs(slide: slide) { facts[$0] }
    #expect(posters.below == ["still", "bg-video", "gone"])
    #expect(posters.above == ["fg-video"])

    let bare = SlideSceneBuilder.fireMediaPosterIDs(slide: Slide(id: "b", name: "", objects: [])) { _ in nil }
    #expect(bare.below.isEmpty && bare.above.isEmpty)
}

@Test func effectiveBackgroundResolvesSlideThenSong() {
    var slide = Slide(id: "s", name: "Verse", objects: [])
    var song = Presentation(id: "p", name: "Song", presentationKind: .song, themeId: "", slides: [slide])
    #expect(SlideSceneBuilder.effectiveBackground(slide: slide, presentation: song) == nil)

    song.background = CueMedia(mediaId: "song-bg", layer: .loopingVideos)
    #expect(SlideSceneBuilder.effectiveBackground(slide: slide, presentation: song)?.mediaId == "song-bg")
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil, presentation: song)
    #expect(scene.layers.first { $0.kind == .loopingVideos }!.items.count == 1)

    slide.background = CueMedia(mediaId: "cue-bg", layer: .videos)
    #expect(SlideSceneBuilder.effectiveBackground(slide: slide, presentation: song)?.mediaId == "cue-bg")

    slide.background = CueMedia(mediaId: "")
    #expect(SlideSceneBuilder.effectiveBackground(slide: slide, presentation: song)?.mediaId == "song-bg")
}

@Test func untilReplacedCoversFollowingSlidesUntilTheNextDeclaration() {
    func slide(_ id: String, background: CueMedia? = nil) -> Slide {
        var s = Slide(id: id, name: id, objects: [])
        s.background = background
        return s
    }
    var song = Presentation(
        id: "p", name: "Song", presentationKind: .song, themeId: "",
        slides: [
            slide("s0", background: CueMedia(mediaId: "range-A", mode: .untilReplaced)),
            slide("s1"),
            slide("s2", background: CueMedia(mediaId: "own-B")), 
            slide("s3"),
        ]
    )
    func effective(_ index: Int) -> String? {
        SlideSceneBuilder.effectiveBackground(slide: song.slides[index], presentation: song)?.mediaId
    }
    #expect(effective(0) == "range-A")
    #expect(effective(1) == "range-A", "range covers following slides")
    #expect(effective(2) == "own-B", "a slide's own declaration wins")
    #expect(effective(3) == nil, "a slideOnly declaration ends the range; nothing is guaranteed after")

    song.background = CueMedia(mediaId: "song-bg")
    #expect(effective(3) == "song-bg")
    #expect(effective(1) == "range-A", "the range still beats the song scope")
}

@Test func backgroundSourceNamesTheDeclaringSlide() {
    func slide(_ id: String, background: CueMedia? = nil) -> Slide {
        var s = Slide(id: id, name: id, objects: [])
        s.background = background
        return s
    }
    var song = Presentation(
        id: "p", name: "Song", presentationKind: .song, themeId: "",
        slides: [
            slide("s0", background: CueMedia(mediaId: "range-A", mode: .untilReplaced)),
            slide("s1"),
        ]
    )
    func source(_ index: Int) -> SlideSceneBuilder.BackgroundSource? {
        SlideSceneBuilder.backgroundSource(slide: song.slides[index], presentation: song)?.source
    }
    #expect(source(0) == .slide("s0"), "the declaring slide names itself")
    #expect(source(1) == .slide("s0"), "a covered slide names the declarer, not itself")

    song.slides[0].background = nil
    song.background = CueMedia(mediaId: "song-bg")
    #expect(source(0) == .song)
    #expect(source(1) == .song)
}

private func slide(_ id: String, section: String? = nil, background: CueMedia? = nil) -> Slide {
    var s = Slide(id: id, name: id, objects: [])
    s.sectionId = section
    s.background = background
    return s
}

private func arrangedSong() -> Presentation {
    var song = Presentation(
        id: "p", name: "Song", presentationKind: .deck, themeId: "",
        slides: [
            slide("v1a", section: "v1"), slide("v1b", section: "v1"),
            slide("c1", section: "c"),
            slide("v2a", section: "v2"),
        ]
    )
    song.sections = [
        PresentationSection(id: "v1", name: "Verse 1"),
        PresentationSection(id: "c", name: "Chorus"),
        PresentationSection(id: "v2", name: "Verse 2"),
    ]
    song.arrangements = [
        Arrangement(id: "sunday", name: "Sunday", sectionIds: ["v1", "c", "v2", "c"]),
    ]
    return song
}

@Test func arrangementExpandsSectionsWithoutDuplicatingStorage() {
    let song = arrangedSong()

    #expect(SlideSceneBuilder.arrangedSlides(for: song).map(\.id) == ["v1a", "v1b", "c1", "v2a"])

    #expect(
        SlideSceneBuilder.arrangedSlides(for: song, arrangementId: "sunday").map(\.id)
            == ["v1a", "v1b", "c1", "v2a", "c1"]
    )

    var defaulted = song
    defaulted.defaultArrangementId = "sunday"
    #expect(SlideSceneBuilder.arrangedSlides(for: defaulted).count == 4)

    #expect(SlideSceneBuilder.arrangedSlides(for: song, arrangementId: "missing").count == 4)
}

@Test func arrangementBlockStartsAlignWithPills() {
    let song = arrangedSong()

    let arranged = SlideSceneBuilder.arrangementBlockStarts(for: song, arrangementId: "sunday")
    #expect(arranged == [0, 2, 3, 4])

    let slides = SlideSceneBuilder.arrangedSlides(for: song, arrangementId: "sunday")
    let sectionIds = song.arrangements![0].sectionIds
    for (pill, start) in arranged.enumerated() {
        #expect(slides[start].sectionId == sectionIds[pill])
    }

    #expect(SlideSceneBuilder.arrangementBlockStarts(for: song) == [0, 2, 3])

    var stray = song
    stray.slides.insert(slide("x", section: "ghost"), at: 2)
    #expect(SlideSceneBuilder.arrangementBlockStarts(for: stray) == [0, 3, 4])

    var withEmpty = song
    withEmpty.sections!.append(PresentationSection(id: "br", name: "Bridge"))
    withEmpty.arrangements = [
        Arrangement(id: "a", name: "A", sectionIds: ["v1", "br", "c"]),
    ]
    #expect(SlideSceneBuilder.arrangementBlockStarts(for: withEmpty, arrangementId: "a") == [0, 2, 2])
}

@Test func sectionBackgroundSitsBetweenSlideAndSongScopes() {
    var song = arrangedSong()
    song.sections![1].background = CueMedia(mediaId: "chorus-bg")
    song.background = CueMedia(mediaId: "song-bg")

    func effective(_ slideID: String) -> String? {
        let slide = song.slides.first { $0.id == slideID }!
        return SlideSceneBuilder.effectiveBackground(slide: slide, presentation: song)?.mediaId
    }
    #expect(effective("c1") == "chorus-bg", "section scope covers its slides")
    #expect(effective("v1a") == "song-bg", "other sections fall through to the song")

    song.slides[2].background = CueMedia(mediaId: "own")
    #expect(effective("c1") == "own")
}

@Test func untilReplacedIsArrangementAware() {
    var song = arrangedSong()

    song.slides[2].background = CueMedia(mediaId: "range", mode: .untilReplaced)

    let verse2 = song.slides[3]
    #expect(
        SlideSceneBuilder.effectiveBackground(
            slide: verse2, presentation: song, arrangementId: "sunday"
        )?.mediaId == "range",
        "jumping mid-range fires the range's media"
    )

    song.arrangements = [Arrangement(id: "sunday", name: "Sunday", sectionIds: ["v2", "c", "v1"])]
    #expect(
        SlideSceneBuilder.effectiveBackground(
            slide: verse2, presentation: song, arrangementId: "sunday"
        ) == nil,
        "coverage reads on the active sequence, not storage order"
    )

    song.arrangements = [Arrangement(id: "sunday", name: "Sunday", sectionIds: ["c", "v2"])]
    song.sections![2].background = CueMedia(mediaId: "v2-section-bg")
    #expect(
        SlideSceneBuilder.effectiveBackground(
            slide: verse2, presentation: song, arrangementId: "sunday"
        )?.mediaId == "range",
        "slide-level declarations (even ranged) sit above section scope in the chain"
    )
}

private func themedTheme() -> Theme {
    var placeholder = SlideObject(
        id: "ph", objectKind: .text, name: "Text", text: "Sample lyrics",
        x: 200, y: 700, width: 1520, height: 300
    )
    placeholder.textStyle = TextStyle(
        fontName: "Georgia-Bold", fontSize: 110, colorHex: "#EEDDFFFF", tracking: 1.5
    )
    var bar = SlideObject(
        id: "bar", objectKind: .shape, name: "Bar", text: "",
        x: 0, y: 660, width: 1920, height: 380
    )
    bar.fill = ObjectFill(fillKind: .solid, colorHex: "#00000080")
    var theme = Theme(
        id: "t2", name: "Modern", fontFamily: "Helvetica Neue",
        fontSize: 96, textColorHex: "#FFCC00", backgroundColorHex: "#101820"
    )
    theme.slides = [
        Slide(id: "ts-lyrics", name: "Lyrics", objects: [bar, placeholder]),
        Slide(id: "ts-bible", name: "Bible", objects: []),
    ]
    return theme
}

@Test func themeSlideResolvesByCategoryNameElseFirst() {
    let theme = themedTheme()
    var slide = Slide(id: "s", name: "Verse", objects: [])
    #expect(SlideSceneBuilder.themeSlide(for: slide, theme: theme)?.id == "ts-lyrics", "absent category → first")
    slide.themeSlideName = "bible"
    #expect(SlideSceneBuilder.themeSlide(for: slide, theme: theme)?.id == "ts-bible", "case-insensitive match")
    slide.themeSlideName = "Sermon Points"
    #expect(SlideSceneBuilder.themeSlide(for: slide, theme: theme)?.id == "ts-lyrics", "unmatched → first")
    #expect(SlideSceneBuilder.themeSlide(for: slide, theme: nil) == nil)
}

@Test func placeholderDonatesFrameAndStyleButNeverRenders() {
    let theme = themedTheme()

    let slide = Slide(id: "s", name: "Verse", objects: [
        SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Amazing grace"),
    ])
    let scene = SlideSceneBuilder.scene(for: slide, theme: theme)
    let items = scene.layers.first { $0.kind == .slide }!.items

    #expect(items.map(\.id) == ["theme-bar", "lyric"])
    guard case .text(let styled) = items[1].content else {
        Issue.record("expected text content")
        return
    }
    #expect(items[1].frame == CGRect(x: 200, y: 700, width: 1520, height: 300), "theme placement")
    #expect(styled.fontName == "Georgia-Bold")
    #expect(styled.fontSize == 110)
    #expect(styled.tracking == 1.5)
    #expect(styled.string == "Amazing grace", "content is the slide's, never the sample")

    var overridden = slide
    overridden.objects[0].textStyle = TextStyle(fontSize: 60)
    overridden.objects[0].x = 0
    let item = SlideSceneBuilder.renderItem(
        for: overridden.objects[0], theme: theme,
        placeholder: SlideSceneBuilder.placeholder(in: theme.slides![0])
    )
    guard case .text(let restyled) = item.content else {
        Issue.record("expected text content")
        return
    }
    #expect(restyled.fontSize == 60)
    #expect(restyled.fontName == "Georgia-Bold", "unset fields still inherit")
    #expect(item.frame.origin.x == 0)
    #expect(item.frame.width == 1520, "unset frame components still inherit")
}

@Test func placeholderChainFallsThroughToThemeBase() {

    var theme = themedTheme()
    theme.slides![0].objects[1].textStyle = TextStyle(fontSize: 110)
    let object = SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Line")
    guard case .text(let styled) = SlideSceneBuilder.renderItem(
        for: object, theme: theme,
        placeholder: SlideSceneBuilder.placeholder(in: theme.slides![0])
    ).content else {
        Issue.record("expected text content")
        return
    }
    #expect(styled.fontSize == 110, "placeholder rung")
    #expect(styled.fontName == "Helvetica Neue", "theme base rung")
    #expect(styled.color == ColorHex.color("#FFCC00"), "theme base rung")
}

@Test func reThemeReachesEveryUnoverriddenSlide() {

    let slide = Slide(id: "s", name: "Verse", objects: [
        SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Line"),
    ])
    func lookup(_ theme: Theme) -> (String, Double) {
        let items = SlideSceneBuilder.scene(for: slide, theme: theme)
            .layers.first { $0.kind == .slide }!.items
        guard case .text(let styled) = items.last!.content else { return ("", 0) }
        return (styled.fontName, styled.fontSize)
    }
    let classic = theme 
    #expect(lookup(classic) == ("Helvetica Neue", 96))
    #expect(lookup(themedTheme()) == ("Georgia-Bold", 110))
}

@Test func placeholdersMatchSlideObjectsByName() {

    var theme = themedTheme()
    var topLine = SlideObject(
        id: "ph-top", objectKind: .text, name: "Top Line", text: "Sample top line",
        x: 200, y: 80, width: 1520, height: 160
    )
    topLine.textStyle = TextStyle(fontName: "Futura-Bold", fontSize: 72, colorHex: "#FFD700FF")
    theme.slides![0].objects.append(topLine)

    let slide = Slide(id: "s", name: "Chorus", objects: [
        SlideObject(id: "top", objectKind: .text, name: "top line", text: "My chains are gone"),
        SlideObject(id: "body", objectKind: .text, name: "Lyrics", text: "I've been set free"),
        SlideObject(id: "other", objectKind: .text, name: "Tag", text: "unmatched"),
    ])
    let items = SlideSceneBuilder.scene(for: slide, theme: theme)
        .layers.first { $0.kind == .slide }!.items

    #expect(items.map(\.id) == ["theme-bar", "body", "other", "top"])

    func styled(_ id: String) -> StyledText? {
        guard case .text(let styled)? = items.first(where: { $0.id == id })?.content else { return nil }
        return styled
    }
    #expect(styled("top")?.fontName == "Futura-Bold", "case-insensitive name match")
    #expect(items.first { $0.id == "top" }?.frame.origin.y == 80, "matched placement donates too")
    #expect(styled("body")?.fontName == "Georgia-Bold", "unmatched pairs with the unclaimed placeholder in z-order")
    #expect(styled("other")?.fontName == "Georgia-Bold", "placeholders exhausted → first placeholder")
    #expect(styled("top")?.string == "My chains are gone", "content is always the slide's")
}

@Test func unmatchedTextObjectsPairWithPlaceholdersInZOrder() {

    var header = SlideObject(id: "ph-a", objectKind: .text, name: "Header", text: "H")
    header.textStyle = TextStyle(fontName: "Futura-Bold", fontSize: 60)
    var body = SlideObject(id: "ph-b", objectKind: .text, name: "Body", text: "B")
    body.textStyle = TextStyle(fontName: "Georgia", fontSize: 90)
    var theme = Theme(
        id: "t3", name: "Ordered", fontFamily: "Helvetica Neue",
        fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000"
    )
    theme.slides = [Slide(id: "ts", name: "Lyrics", objects: [header, body])]

    let slide = Slide(id: "s", name: "Point", objects: [
        SlideObject(id: "one", objectKind: .text, name: "One", text: "first"),
        SlideObject(id: "two", objectKind: .text, name: "Two", text: "second"),
        SlideObject(id: "three", objectKind: .text, name: "Three", text: "third"),
    ])
    let assignments = SlideSceneBuilder.placeholderAssignments(
        for: slide.objects, in: theme.slides![0]
    )
    #expect(assignments["one"]?.id == "ph-a")
    #expect(assignments["two"]?.id == "ph-b")
    #expect(assignments["three"]?.id == "ph-a", "exhausted → first placeholder, never unstyled")

    var claimed = slide
    claimed.objects[2].name = "Header"
    let reclaimed = SlideSceneBuilder.placeholderAssignments(
        for: claimed.objects, in: theme.slides![0]
    )
    #expect(reclaimed["three"]?.id == "ph-a", "name match wins")
    #expect(reclaimed["one"]?.id == "ph-b", "z-order pairing uses only unclaimed placeholders")
}

@Test func themeZOrderIsHonoredInTheComposition() {

    var bar = SlideObject(id: "bar", objectKind: .shape, name: "Bar", text: "")
    bar.fill = ObjectFill(fillKind: .solid, colorHex: "#000000AA")
    let placeholder = SlideObject(id: "ph", objectKind: .text, name: "Text", text: "Sample")
    var gloss = SlideObject(id: "gloss", objectKind: .shape, name: "Gloss", text: "")
    gloss.fill = ObjectFill(fillKind: .solid, colorHex: "#FFFFFF22")
    var theme = Theme(
        id: "t4", name: "Lower Third", fontFamily: "Helvetica Neue",
        fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000"
    )
    theme.slides = [Slide(id: "ts", name: "Lyrics", objects: [bar, placeholder, gloss])]

    let slide = Slide(id: "s", name: "Verse", objects: [
        SlideObject(id: "extra", objectKind: .shape, name: "Slide Shape", text: ""),
        SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Line"),
    ])
    let items = SlideSceneBuilder.scene(for: slide, theme: theme)
        .layers.first { $0.kind == .slide }!.items
    #expect(
        items.map(\.id) == ["theme-bar", "lyric", "theme-gloss", "extra"],
        "text at its placeholder's position, under the gloss; slide-only objects on top"
    )

    let bare = SlideSceneBuilder.scene(for: slide, theme: theme, showThemeDecor: false)
        .layers.first { $0.kind == .slide }!.items
    #expect(bare.map(\.id) == ["lyric", "extra"])

    let composed = SlideSceneBuilder.composedOrder(for: slide.objects, in: theme.slides![0])
    #expect(composed.map(\.id) == ["lyric", "extra"])
    let baked = SlideSceneBuilder.bakedSlide(slide, theme: theme)
    #expect(baked.objects.map(\.name) == ["Bar", "Lyrics", "Gloss", "Slide Shape"])
}

@Test func resetThemeOverridesUnpinsTextObjectsOnly() {
    var text = SlideObject(id: "t", objectKind: .text, name: "Lyrics", text: "Line")
    text.textStyle = TextStyle(fontSize: 60)
    text.x = 10; text.y = 20; text.width = 300; text.height = 100
    var shape = SlideObject(id: "sh", objectKind: .shape, name: "Panel", text: "")
    shape.x = 5
    var slide = Slide(id: "s", name: "Verse", objects: [text, shape])

    #expect(SlideSceneBuilder.hasThemeOverrides(slide))
    SlideSceneBuilder.resetThemeOverrides(&slide)
    #expect(!SlideSceneBuilder.hasThemeOverrides(slide))
    #expect(slide.objects[0].textStyle == nil)
    #expect(slide.objects[0].x == nil)
    #expect(slide.objects[1].x == 5, "the theme never controlled non-text objects")
}

@Test func bakedSlideKeepsTheLookAndStopsFollowing() {

    let theme = themedTheme()
    var text = SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Line")
    text.textStyle = TextStyle(colorHex: "#FF0000FF") 
    let slide = Slide(id: "s", name: "Verse", objects: [text])

    let baked = SlideSceneBuilder.bakedSlide(slide, theme: theme)
    let bakedText = baked.objects.first { $0.id == "lyric" }!
    #expect(bakedText.textStyle?.colorHex == "#FF0000FF", "own overrides win")
    #expect(bakedText.textStyle?.fontName == "Georgia-Bold", "placeholder rung baked in")
    #expect(bakedText.textStyle?.fontSize == 110)
    #expect(bakedText.x == 200, "theme placement baked in")
    #expect(bakedText.width == 1520)

    #expect(baked.objects.first?.objectKind == .shape)
    #expect(baked.objects.first?.id != "bar")
    #expect(baked.themeSlideName == nil)

    guard case .text(let themed) = SlideSceneBuilder
        .scene(for: slide, theme: theme).layers.first(where: { $0.kind == .slide })!
        .items.last!.content,
        case .text(let detached) = SlideSceneBuilder
        .scene(for: baked, theme: nil).layers.first(where: { $0.kind == .slide })!
        .items.last!.content
    else {
        Issue.record("expected text content")
        return
    }
    #expect(themed.fontName == detached.fontName)
    #expect(themed.fontSize == detached.fontSize)
    #expect(themed.color == detached.color)
}

@Test func themeEditorRendersPlaceholderAsItself() {

    let theme = themedTheme()
    var base = theme
    base.slides = nil
    let scene = SlideSceneBuilder.scene(for: theme.slides![0], theme: base)
    let items = scene.layers.first { $0.kind == .slide }!.items
    #expect(items.map(\.id) == ["bar", "ph"])
    guard case .text(let styled) = items[1].content else {
        Issue.record("expected text content")
        return
    }
    #expect(styled.string == "Sample lyrics")
    #expect(styled.fontName == "Georgia-Bold", "its own style, no self-donation")
}

@Test func documentOrderIsZOrderAcrossAllObjectKinds() {

    let slide = Slide(id: "s", name: "n", objects: [
        SlideObject(id: "a", objectKind: .shape, name: "under", text: ""),
        SlideObject(id: "b", objectKind: .text, name: "middle", text: "hi"),
        SlideObject(id: "c", objectKind: .media, name: "over", text: ""),
    ])
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil)
    let items = scene.layers.first { $0.kind == .slide }!.items
    #expect(items.map(\.id) == ["a", "b", "c"])
}

@Test func shapeWithTextEmitsShapeThenTextItem() {
    let slide = Slide(id: "s", name: "n", objects: [
        SlideObject(
            id: "badge", objectKind: .shape, name: "Badge", text: "WELCOME",
            shapeKind: .ellipse
        ),
    ])
    let scene = SlideSceneBuilder.scene(for: slide, theme: theme)
    let items = scene.layers.first { $0.kind == .slide }!.items

    #expect(items.map(\.id) == ["badge", "badge::text"])
    guard case .shape = items[0].content, case .text(let styled) = items[1].content else {
        Issue.record("expected shape + text pair")
        return
    }

    #expect(styled.pathData == nil)
    #expect(styled.string == "WELCOME")
    #expect(items[1].frame == items[0].frame)
}

@Test func blankShapeTextEmitsNoTextItem() {

    let slide = Slide(id: "s", name: "n", objects: [
        SlideObject(
            id: "a", objectKind: .shape, name: "empty", text: "",
            shapeKind: .ellipse, shapeTextPlacement: .edgeOutside
        ),
        SlideObject(
            id: "b", objectKind: .shape, name: "spaces", text: "  \n ",
            shapeKind: .ellipse, shapeTextPlacement: .edgeOutside
        ),
    ])
    let scene = SlideSceneBuilder.scene(for: slide, theme: theme)
    let items = scene.layers.first { $0.kind == .slide }!.items
    #expect(items.map(\.id) == ["a", "b"])
}

@Test func edgePlacementCarriesLiveOutlineAndReversalFlag() {
    let outside = SlideObject(
        id: "o", objectKind: .shape, name: "ring", text: "AROUND",
        width: 300, height: 300, shapeKind: .ellipse, shapeTextPlacement: .edgeOutside
    )
    let inside = SlideObject(
        id: "i", objectKind: .shape, name: "badge", text: "WITHIN",
        width: 300, height: 300, shapeKind: .ellipse, shapeTextPlacement: .edgeInside
    )
    let scene = SlideSceneBuilder.scene(
        for: Slide(id: "s", name: "n", objects: [outside, inside]), theme: theme
    )
    let items = scene.layers.first { $0.kind == .slide }!.items
    guard case .text(let outText) = items[1].content,
          case .text(let inText) = items[3].content else {
        Issue.record("expected text items")
        return
    }

    #expect(outText.pathData?.hasPrefix("M 0.5 0 ") == true)
    #expect(outText.pathReversed == false)
    #expect(inText.pathData?.hasPrefix("M 0.5 1 ") == true)
    #expect(inText.pathReversed == true)
}

@Test func roundedRectOutlineUsesPerAxisRadiiAndRasterizerClamp() {

    let data = ShapeOutlineSVG.pathData(
        shapeKind: .roundedRectangle, frame: CGSize(width: 400, height: 100),
        cornerRadius: 30, customPathData: nil, placement: .edgeOutside
    )!
    #expect(data.contains("L 0.925000 0"))   
    #expect(data.contains("1.000000 0.300000")) 
    #expect(data.hasSuffix("Z"))

    let clamped = ShapeOutlineSVG.pathData(
        shapeKind: .roundedRectangle, frame: CGSize(width: 400, height: 100),
        cornerRadius: 500, customPathData: nil, placement: .edgeOutside
    )!
    #expect(clamped.contains("L 0.875000 0")) 
}

@Test func generatedOutlineParsesFlattensClosedAndMatchesCornerRadius() {

    let frame = CGSize(width: 400, height: 100)
    let data = ShapeOutlineSVG.pathData(
        shapeKind: .roundedRectangle, frame: frame, cornerRadius: 30,
        customPathData: nil, placement: .edgeOutside
    )!
    let rect = CGRect(origin: .zero, size: frame)
    let path = SVGPathParser.path(from: data, in: rect)!
    let flat = PathTextLayout.flatten(path)!
    #expect(flat.isClosed)

    let center = CGPoint(x: 370, y: 30)
    for point in flat.points where point.x > 370 && point.y < 30 {
        let radial = hypot(point.x - center.x, point.y - center.y)
        #expect(abs(radial - 30) < 0.35, "corner point must ride the r=30 circle")
    }
}

@Test func overlayShapeTextReachesTheProgramScene() {

    let overlay = Overlay(
        id: "ov", name: "Badge", objects: [
            SlideObject(
                id: "ring", objectKind: .shape, name: "ring", text: "LIVE",
                shapeKind: .ellipse, shapeTextPlacement: .edgeOutside
            ),
        ]
    )
    var state = ShowState()
    state.fire(overlay: overlay)
    let scene = state.scene()
    let layer = scene.layers.first { $0.kind == .overlays }!
    #expect(layer.items.map(\.id) == ["overlay-ov-ring", "overlay-ov-ring::text"])
}

@Test func namedInputWinsOverLegacyDeviceReference() {

    var object = SlideObject(id: "live", objectKind: .liveInput, name: "Cam", text: "")
    object.captureSourceKind = .camera
    object.captureSourceId = "cam-1"
    #expect(SlideSceneBuilder.liveInputEngineID(object) == "input::camera::cam-1")
    object.liveInputId = "item-1"
    #expect(SlideSceneBuilder.liveInputEngineID(object) == "input::item::item-1")

    let wants = SlideSceneBuilder.mediaWants(for: [object])
    #expect(wants.keys.contains("input::item::item-1"))
    #expect(!wants.keys.contains("input::camera::cam-1"))
}

@Test func namedInputFillResolvesAndSuppressesLibraryWant() {
    var shape = SlideObject(id: "shape", objectKind: .shape, name: "Fill", text: "")
    shape.shapeKind = .rectangle
    var fill = ObjectFill(fillKind: .media, mediaId: "clip")
    fill.liveInputId = "item-2"
    shape.fill = fill
    guard case .shape(let style) = SlideSceneBuilder.renderItem(for: shape, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.fill == .media(id: "input::item::item-2", scaleMode: .fill))
    #expect(SlideSceneBuilder.fillLiveInputID(shape) == "input::item::item-2")
    #expect(SlideSceneBuilder.fillMediaID(shape) == nil, "the library want-list must not open input ids")

    var mirrored = fill
    mirrored.screenSourceId = "screen-a"
    shape.fill = mirrored
    #expect(SlideSceneBuilder.fillLiveInputID(shape) == nil, "screen wins over named input")
}

@Test func unassignedLiveInputObjectStillWantsItsItemID() {

    var object = SlideObject(id: "live", objectKind: .liveInput, name: "Cam", text: "")
    object.liveInputId = "item-3"
    let wants = SlideSceneBuilder.mediaWants(for: [object])
    #expect(wants.keys.contains("input::item::item-3"))
}

@Test func fullyUnassignedLiveInputRendersPlaceholderButWantsNothing() {

    let object = SlideObject(id: "live", objectKind: .liveInput, name: "Live Input", text: "")
    guard case .shape(let style) = SlideSceneBuilder.renderItem(for: object, theme: nil).content else {
        Issue.record("expected shape content")
        return
    }
    #expect(style.fill == .media(id: "input::camera::", scaleMode: .fill))
    #expect(SlideSceneBuilder.mediaWants(for: [object]).isEmpty)
}

@Test func legacyMediaObjectAndNormalizedTwinBuildIdenticalScenes() {

    var legacy = SlideObject(id: "img", objectKind: .media, name: "Pic", text: "")
    legacy.x = 100; legacy.y = 50; legacy.width = 800; legacy.height = 600
    legacy.mediaId = "media-9"
    legacy.mediaScaleMode = .fit
    legacy.mediaSourceRect = MediaSourceRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    legacy.loops = true
    legacy.rotationDegrees = 30
    legacy.opacity = 0.8

    let normalized = SlideObjectNormalization.normalized(legacy)
    #expect(normalized.objectKind == .shape)
    #expect(SlideSceneBuilder.renderItems(for: legacy, theme: nil)
        == SlideSceneBuilder.renderItems(for: normalized, theme: nil))
    #expect(SlideSceneBuilder.mediaWants(for: [legacy]) == SlideSceneBuilder.mediaWants(for: [normalized]))
    #expect(SlideSceneBuilder.fillMediaID(legacy) == "media-9")
    #expect(SlideSceneBuilder.fillMediaID(normalized) == "media-9")

    var liveLegacy = SlideObject(id: "cam", objectKind: .liveInput, name: "Cam", text: "")
    liveLegacy.captureSourceKind = .ndi
    liveLegacy.captureSourceId = "ndi-1"
    let liveNormalized = SlideObjectNormalization.normalized(liveLegacy)
    #expect(SlideSceneBuilder.renderItems(for: liveLegacy, theme: nil)
        == SlideSceneBuilder.renderItems(for: liveNormalized, theme: nil))
    #expect(SlideSceneBuilder.mediaWants(for: [liveLegacy])
        == SlideSceneBuilder.mediaWants(for: [liveNormalized]))
}

@Test func sceneEffectsHonorBypassAndStrength() {

    let chain: [Effect] = [
        Effect(effectKind: .blur, radius: 10),
        Effect(effectKind: .blur, enabled: false, radius: 20),
        Effect(effectKind: .colorAdjust, opacity: 0, brightness: 1),
        Effect(effectKind: .colorAdjust, opacity: 0.5, saturation: 0),
    ]
    let scene = SlideSceneBuilder.sceneEffects(chain)
    #expect(scene.count == 2)
    #expect(scene[0] == SceneEffect(kind: .blur(radius: 10), opacity: 1))
    #expect(scene[1] == SceneEffect(
        kind: .colorAdjust(brightness: 0, contrast: 0, saturation: 0, hue: 0), opacity: 0.5
    ))
}

@Test func mediaEffectsPrependWhereverTheItemRenders() {

    var scene = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))
    var item = RenderItem(
        id: "o1", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        content: .media(id: "m1")
    )
    item.effects = [.blur(radius: 4)]
    scene.addItem(item, to: .videos)
    scene.addItem(
        RenderItem(
            id: "o2", frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            content: .media(id: "m2")
        ),
        to: .videos
    )
    let itemChain = [SceneEffect(
        kind: .colorAdjust(brightness: 0, contrast: 0, saturation: 0, hue: 0), opacity: 1
    )]
    let out = scene.applyingMediaEffects { $0 == "m1" ? itemChain : [] }
    let items = out.layers.flatMap(\.items)
    let first = items.first { $0.id == "o1" }
    let second = items.first { $0.id == "o2" }
    #expect(first?.effects == itemChain + [.blur(radius: 4)])
    #expect(second?.effects.isEmpty == true)
}

@Test func v48KindsMapWithDefaultsClampsAndNoOpDrops() {
    let chain: [Effect] = [
        Effect(effectKind: .hueRotate),                    
        Effect(effectKind: .hueRotate, amount: 0),         
        Effect(effectKind: .invert),
        Effect(effectKind: .posterize, amount: 99),        
        Effect(effectKind: .pixelate, amount: 0.2),        
        Effect(effectKind: .pixelate, amount: 24),
        Effect(effectKind: .vignette, amount: 2.4),        
    ]
    let scene = SlideSceneBuilder.sceneEffects(chain)
    #expect(scene.map(\.kind) == [
        .hueRotate(degrees: 90),
        .invert,
        .posterize(levels: 32),
        .pixelate(size: 24),
        .vignette(strength: 1.5),
    ])
}

@Test func decorationsAndFlipsMapOntoSceneValues() {
    var style = TextStyle()
    style.underline = true
    style.strikethrough = true
    var object = SlideObject(
        id: "o", objectKind: .text, name: "Text", text: "Gracious words heal",
        flipHorizontal: true, flipVertical: true, textStyle: style
    )
    object.styleRuns = [TextStyleRun(
        line: 0, column: 9, length: 5, underline: true,
        fontName: "HelveticaNeue-Bold", fontSize: 88,
        colorHex: "#FF0000FF", highlightColorHex: "#00FF00FF", tracking: 4
    )]

    let item = SlideSceneBuilder.renderItem(for: object, theme: theme)
    #expect(item.flipHorizontal == true)
    #expect(item.flipVertical == true)
    guard case .text(let text) = item.content else {
        Issue.record("expected text content")
        return
    }
    #expect(text.underline == true)
    #expect(text.strikethrough == true)

    #expect(text.styleRuns == [StyleRun(
        line: 0, column: 9, length: 5, underline: true,
        fontName: "HelveticaNeue-Bold", fontSize: 88,
        color: SceneColor(red: 1, green: 0, blue: 0),
        highlightColor: SceneColor(red: 0, green: 1, blue: 0),
        tracking: 4
    )])
}

@Test func shapeTextItemInheritsFlips() {
    var object = SlideObject(
        id: "s", objectKind: .shape, name: "Band", text: "TITLE",
        flipHorizontal: true,
        fill: ObjectFill(fillKind: .solid, colorHex: "#112233FF")
    )
    object.styleRuns = [TextStyleRun(line: 0, column: 0, length: 2, strikethrough: true)]
    let items = SlideSceneBuilder.renderItems(for: object, theme: theme)
    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.flipHorizontal })
    guard case .text(let text) = items[1].content else {
        Issue.record("expected shape text item")
        return
    }
    #expect(text.styleRuns.count == 1)
    #expect(text.styleRuns[0].strikethrough == true)
}

@Test func tiltAndBuildsRideEveryItemOfTheObject() {
    var object = SlideObject(
        id: "s", objectKind: .shape, name: "Band", text: "TITLE",
        fill: ObjectFill(fillKind: .solid, colorHex: "#112233FF")
    )
    object.tilt = 25
    object.swing = -15
    object.tiltPivot = .bottom
    object.keystoneTop = 60 
    let step = SceneAnimationStep(id: "in", kind: .enter, animation: .fade, group: .click(0), duration: 0.5)
    let items = SlideSceneBuilder.renderItems(for: object, theme: theme, animationSteps: [step])
    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.tilt == 25 })
    #expect(items.allSatisfy { $0.swing == -15 && $0.tiltPivot == .bottom })
    #expect(items.allSatisfy { $0.keystoneTop == 0.6 && $0.keystoneBottom == 1 }, "…fraction on the item")
    #expect(items.allSatisfy { $0.animationSteps == [step] }, "the ::text pair animates as one")
    #expect(items.allSatisfy { $0.animationContext == nil }, "context is the caller's stamp")
    #expect(SlideSceneBuilder.renderItem(for: object, theme: theme).tilt == 25)
}

@Test func clippedTextObjectIDsFlagOverflowingBoxes() {
    var style = TextStyle()
    style.fontSize = 96
    var big = SlideObject(id: "big", objectKind: .text, name: "T", text:
        Array(repeating: "Amazing grace how sweet the sound", count: 12).joined(separator: "\n"))
    big.x = 0; big.y = 0; big.width = 400; big.height = 100
    big.textStyle = style
    var fits = SlideObject(id: "fits", objectKind: .text, name: "T", text: "Hi")
    fits.x = 0; fits.y = 300; fits.width = 800; fits.height = 400
    fits.textStyle = style
    let slide = Slide(id: "s", name: "1", objects: [big, fits])

    #expect(SlideSceneBuilder.clippedTextObjectIDs(for: slide, theme: nil) == ["big"])
}

@Test func backgroundFillDrawsUnderSlideObjects() {
    var object = SlideObject(id: "text", objectKind: .text, name: "Lyrics", text: "Line")
    object.x = 0; object.y = 0; object.width = 800; object.height = 300
    let slide = Slide(id: "s1", name: "1", objects: [object])
    var presentation = Presentation(
        id: "p", name: "Deck", presentationKind: .deck, themeId: "", slides: [slide]
    )
    presentation.backgroundFill = ObjectFill(fillKind: .solid, colorHex: "#FFFFFFFF")

    let scene = SlideSceneBuilder.scene(for: slide, theme: nil, presentation: presentation)
    let layer = scene.layers.first { $0.kind == .slide }!
    #expect(layer.items.count == 2)
    #expect(layer.items[0].id == "s1-backdrop")
    guard case .shape(let shape) = layer.items[0].content else {
        Issue.record("expected shape backdrop")
        return
    }
    #expect(shape.fill == .solid(ColorHex.color("#FFFFFFFF")!))

    var overridden = slide
    overridden.backgroundFill = ObjectFill(fillKind: .solid, colorHex: "#000000FF")
    let overriddenScene = SlideSceneBuilder.scene(
        for: overridden, theme: nil, presentation: presentation
    )
    let overriddenLayer = overriddenScene.layers.first { $0.kind == .slide }!
    guard case .shape(let overriddenShape) = overriddenLayer.items[0].content else {
        Issue.record("expected shape backdrop")
        return
    }
    #expect(overriddenShape.fill == .solid(ColorHex.color("#000000FF")!))
}

@Test func hiddenObjectsEmitNoItemsAnywhere() {
    var object = SlideObject(id: "h", objectKind: .text, name: "Text", text: "Hello")
    object.hidden = true
    #expect(SlideSceneBuilder.renderItems(for: object, theme: theme).isEmpty)
    object.hidden = false
    #expect(!SlideSceneBuilder.renderItems(for: object, theme: theme).isEmpty)
}

private func timerCondition(_ state: VisibilityConditionState, timerId: String? = "T1") -> VisibilityCondition {
    VisibilityCondition(conditionKind: .timer, state: state, timerId: timerId)
}

private func conditioned(_ conditions: [VisibilityCondition], match: VisibilityMatch? = nil) -> SlideObject {
    var object = SlideObject(id: "c", objectKind: .text, name: "Timer Box", text: "0:00")
    object.visibilityMatch = match
    object.visibilityConditions = conditions
    return object
}

@Test func timerConditionsFollowRunningState() {
    let now = Date()
    let running = TimerSnapshot(
        id: "T1", name: "Worship", mode: .countdown,
        isRunning: true, runningSince: now, durationSeconds: 300
    )
    let parked = TimerSnapshot(id: "T2", name: "Video", mode: .countdown, durationSeconds: 60)
    let info = ConfidenceInfo(timers: [running, parked])

    let worshipBox = conditioned([timerCondition(.isRunning, timerId: "T1")])
    let videoBox = conditioned([timerCondition(.isRunning, timerId: "T2")])
    #expect(VisibilityRules.isShown(worshipBox, among: [], info: info, at: now))
    #expect(!VisibilityRules.isShown(videoBox, among: [], info: info, at: now))

    let expired = TimerSnapshot(
        id: "T1", name: "Worship", mode: .countdown,
        isRunning: true, runningSince: now.addingTimeInterval(-400), durationSeconds: 300
    )
    let late = ConfidenceInfo(timers: [expired])
    #expect(!VisibilityRules.isShown(conditioned([timerCondition(.hasTimeRemaining)]), among: [], info: late, at: now))
    #expect(VisibilityRules.isShown(conditioned([timerCondition(.hasExpired)]), among: [], info: late, at: now))
}

@Test func matchModesCombineAndNoneInverts() {
    let now = Date()
    let running = TimerSnapshot(
        id: "T1", name: "A", mode: .countdown, isRunning: true,
        runningSince: now, durationSeconds: 300
    )
    let info = ConfidenceInfo(timers: [running])
    let met = timerCondition(.isRunning)
    let unmet = timerCondition(.isNotRunning)

    #expect(!VisibilityRules.isShown(conditioned([met, unmet]), among: [], info: info, at: now))
    #expect(VisibilityRules.isShown(conditioned([met, unmet], match: .any), among: [], info: info, at: now))
    #expect(!VisibilityRules.isShown(conditioned([met], match: VisibilityMatch.none), among: [], info: info, at: now))
    #expect(VisibilityRules.isShown(conditioned([unmet], match: VisibilityMatch.none), among: [], info: info, at: now))
}

@Test func unevaluableConditionsFailVisible() {
    let now = Date()
    let info = ConfidenceInfo()
    let dangling = timerCondition(.isRunning, timerId: "missing")

    let future = VisibilityCondition(conditionKind: .liveInput, state: .isActive)

    #expect(VisibilityRules.isShown(conditioned([dangling]), among: [], info: info, at: now))
    #expect(VisibilityRules.isShown(conditioned([future]), among: [], info: info, at: now))
    #expect(VisibilityRules.isShown(conditioned([dangling], match: .any), among: [], info: info, at: now))
    #expect(VisibilityRules.isShown(conditioned([future], match: VisibilityMatch.none), among: [], info: info, at: now))
}

@Test func videoCountdownAbsenceIsAStateNotAnUnknown() {
    let now = Date()
    let noVideo = ConfidenceInfo()
    let videoBox = conditioned([VisibilityCondition(conditionKind: .videoCountdown, state: .hasTimeRemaining)])
    #expect(!VisibilityRules.isShown(videoBox, among: [], info: noVideo, at: now))

    let playing = ConfidenceInfo(videoCountdown: VideoCountdown(
        name: "Bumper", duration: 120, position: 10, anchoredAt: now, isPlaying: true
    ))
    #expect(VisibilityRules.isShown(videoBox, among: [], info: playing, at: now))
}

@Test func objectTextConditionsReadResolvedSiblings() {
    let now = Date()
    let sibling = SlideObject(id: "s", objectKind: .text, name: "Next", text: "Amazing grace")
    let empty = SlideObject(id: "e", objectKind: .text, name: "Next", text: "  ")
    let box = conditioned([VisibilityCondition(conditionKind: .objectText, state: .hasText, objectId: "s")])
    #expect(VisibilityRules.isShown(box, among: [sibling], info: ConfidenceInfo(), at: now))
    let boxOnEmpty = conditioned([VisibilityCondition(conditionKind: .objectText, state: .hasNoText, objectId: "e")])
    #expect(VisibilityRules.isShown(boxOnEmpty, among: [empty], info: ConfidenceInfo(), at: now))
}

@Test func confidenceSceneFiltersConditionedObjects() {
    var layout = ConfidenceLayout(id: "L", name: "Stage", objects: [])
    var box = conditioned([timerCondition(.isRunning, timerId: "T9")])
    box.x = 0; box.y = 0; box.width = 400; box.height = 200
    layout.objects = [box]

    let parked = ConfidenceInfo(timers: [TimerSnapshot(id: "T9", name: "X", mode: .countdown, durationSeconds: 60)])
    let hidden = ConfidenceSceneBuilder.scene(layout: layout, info: parked, at: Date())
    #expect(hidden.layers.flatMap(\.items).allSatisfy { !$0.id.contains("-c") })

    let running = ConfidenceInfo(timers: [TimerSnapshot(
        id: "T9", name: "X", mode: .countdown, isRunning: true,
        runningSince: Date(), durationSeconds: 60
    )])
    let shown = ConfidenceSceneBuilder.scene(layout: layout, info: running, at: Date())
    #expect(shown.layers.flatMap(\.items).contains { $0.id.contains("-c") })
}

@Test func filteredSceneDropsItemsWhoseConditionsFail() {
    let now = Date()
    var timerBox = SlideObject(id: "tb", objectKind: .text, name: "Timer Box", text: "0:00")
    timerBox.visibilityConditions = [
        VisibilityCondition(conditionKind: .timer, state: .isRunning, timerId: "T1")
    ]
    var scene = RenderScene()
    for item in SlideSceneBuilder.renderItems(for: timerBox, theme: theme) {
        scene.addItem(item, to: .slide)
    }
    #expect(scene.layers.flatMap(\.items).first?.visibility != nil)

    let parked = ConfidenceInfo(timers: [TimerSnapshot(id: "T1", name: "W", mode: .countdown, durationSeconds: 60)])
    let hidden = VisibilityRules.filteredScene(scene, info: parked, at: now)
    #expect(hidden.layers.flatMap(\.items).isEmpty)

    let running = ConfidenceInfo(timers: [TimerSnapshot(
        id: "T1", name: "W", mode: .countdown, isRunning: true, runningSince: now, durationSeconds: 60
    )])
    let shown = VisibilityRules.filteredScene(scene, info: running, at: now)
    #expect(!shown.layers.flatMap(\.items).isEmpty)
}

@Test func filteredSceneResolvesObjectTextAgainstSceneItems() {
    let now = Date()
    let lyric = SlideObject(id: "lyric", objectKind: .text, name: "Lyrics", text: "Amazing grace")
    var label = SlideObject(id: "label", objectKind: .text, name: "Label", text: "NOW SINGING")
    label.visibilityConditions = [
        VisibilityCondition(conditionKind: .objectText, state: .hasNoText, objectId: "lyric")
    ]
    var scene = RenderScene()
    for object in [lyric, label] {
        for item in SlideSceneBuilder.renderItems(for: object, theme: theme) {
            scene.addItem(item, to: .slide)
        }
    }
    let filtered = VisibilityRules.filteredScene(scene, info: ConfidenceInfo(), at: now)

    #expect(filtered.layers.flatMap(\.items).contains { $0.id == "lyric" })
    #expect(!filtered.layers.flatMap(\.items).contains { $0.id == "label" })
}

@Test func audioInputAndCaptureConditionsEvaluate() {
    let now = Date()

    var audioBox = SlideObject(id: "a", objectKind: .text, name: "Audio", text: "♪")
    audioBox.visibilityConditions = [
        VisibilityCondition(conditionKind: .audioPlayback, state: .isRunning)
    ]
    #expect(!VisibilityRules.isShown(audioBox, among: [], info: ConfidenceInfo(), at: now))
    let playing = ConfidenceInfo(audioCountdown: VideoCountdown(
        name: "Walk-in", duration: 180, position: 30, anchoredAt: now, isPlaying: true
    ))
    #expect(VisibilityRules.isShown(audioBox, among: [], info: playing, at: now))

    var inputBox = SlideObject(id: "i", objectKind: .text, name: "CAM", text: "LIVE")
    inputBox.visibilityConditions = [
        VisibilityCondition(conditionKind: .liveInput, state: .isActive, liveInputId: "in1")
    ]
    #expect(!VisibilityRules.isShown(inputBox, among: [], info: ConfidenceInfo(), at: now))
    let inputLive = ConfidenceInfo(activeLiveInputIds: ["in1"])
    #expect(VisibilityRules.isShown(inputBox, among: [], info: inputLive, at: now))

    var unpicked = inputBox
    unpicked.visibilityConditions = [
        VisibilityCondition(conditionKind: .liveInput, state: .isActive)
    ]
    #expect(VisibilityRules.isShown(unpicked, among: [], info: ConfidenceInfo(), at: now))

    var recBox = SlideObject(id: "r", objectKind: .text, name: "REC", text: "●")
    recBox.visibilityConditions = [
        VisibilityCondition(conditionKind: .capture, state: .isActive)
    ]
    #expect(!VisibilityRules.isShown(recBox, among: [], info: ConfidenceInfo(), at: now))
    #expect(VisibilityRules.isShown(recBox, among: [], info: ConfidenceInfo(captureActive: true), at: now))
}

@Test func connectedInputConditionsEvaluateIndependentlyOfActive() {
    let now = Date()
    var badge = SlideObject(id: "b", objectKind: .text, name: "CAM OK", text: "●")
    badge.visibilityConditions = [
        VisibilityCondition(conditionKind: .liveInput, state: .isConnected, liveInputId: "in1")
    ]
    let disconnected = ConfidenceInfo(activeLiveInputIds: ["in1"])
    #expect(!VisibilityRules.isShown(badge, among: [], info: disconnected, at: now))
    let connected = ConfidenceInfo(connectedLiveInputIds: ["in1"])
    #expect(VisibilityRules.isShown(badge, among: [], info: connected, at: now))

    var warning = badge
    warning.visibilityConditions = [
        VisibilityCondition(conditionKind: .liveInput, state: .isDisconnected, liveInputId: "in1")
    ]
    #expect(VisibilityRules.isShown(warning, among: [], info: disconnected, at: now))
    #expect(!VisibilityRules.isShown(warning, among: [], info: connected, at: now))
}

@Test func v79AnimatedKindsMapWithDefaultsClampsAndNoOpDrops() {
    let chain: [Effect] = [
        Effect(effectKind: .warp),                                    
        Effect(effectKind: .warp, amount: 0),                         
        Effect(effectKind: .warp, amount: 10, scale: 0.1, speed: -3), 
        Effect(effectKind: .echo),                                    
        Effect(effectKind: .echo, amount: 99),                        
        Effect(effectKind: .echo, amount: 0),                         
        Effect(effectKind: .scatter),                                 
        Effect(effectKind: .scatter, amount: 20, scale: 0.2, speed: 5, smooth: 3), 
        Effect(effectKind: .scatter, amount: 0.2),                    
        Effect(effectKind: .stainedGlass),                            
        Effect(effectKind: .stainedGlass, radius: -1, amount: 3, scale: 1), 
        Effect(effectKind: .grain),                                   
        Effect(effectKind: .grain, amount: 0),                        
        Effect(effectKind: .ghostTrails),                             
        Effect(effectKind: .ghostTrails, fade: 0),                    
    ]
    let scene = SlideSceneBuilder.sceneEffects(chain)

    let expected: [SceneEffect.Kind] = [
        .warp(amount: 40, scale: 240, speed: 0.5),
        .warp(amount: 10, scale: 1, speed: 0),
        .echo(fade: 1),
        .echo(fade: 20),
        .scatter(amount: 8, size: 1, speed: 1, smooth: 0),
        .scatter(amount: 20, size: 1, speed: 1, smooth: 1),
        .stainedGlass(cellSize: 80, leading: 3, jitter: 0.8, speed: 0),
        .stainedGlass(cellSize: 4, leading: 0, jitter: 1, speed: 0),
        .grain(amount: 0.3, size: 1, speed: 1),
        .ghostTrails(fade: 1.5, drift: 6, scale: 160, speed: 0.5),
    ]
    #expect(scene.map(\.kind) == expected)
}

@Test func recommendedEffectPresetsAllRenderSomething() {

    for preset in EffectPreset.recommended {
        #expect(!SlideSceneBuilder.sceneEffects(preset.effects).isEmpty, "\(preset.name)")
        #expect(preset.id.hasPrefix("builtin."), "\(preset.name)")
    }
    #expect(Set(EffectPreset.recommended.map(\.id)).count == EffectPreset.recommended.count)
}
