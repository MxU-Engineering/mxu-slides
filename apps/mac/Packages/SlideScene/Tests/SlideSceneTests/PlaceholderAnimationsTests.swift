import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing

@testable import SlideScene

private func makeStep(
    _ id: String, _ trigger: AnimationTrigger = .withPrevious, _ kind: AnimationKind = .in,
    duration: Double = 0.5, ranges: [AnimationRange]? = nil
) -> AnimationStep {
    AnimationStep(
        id: id, kind: kind, animation: .move, trigger: trigger,
        durationSeconds: duration, ranges: ranges
    )
}

private func textObject(_ id: String, name: String = "Lyrics", animationSteps: [AnimationStep]? = nil) -> SlideObject {
    SlideObject(id: id, objectKind: .text, name: name, text: "Amazing grace", animationSteps: animationSteps)
}

private func sideThirdTheme(
    placeholderBuilds: [AnimationStep], decorBuilds: [AnimationStep] = [], animationOrder: [String]? = nil
) -> Theme {
    var placeholder = textObject("ph", animationSteps: placeholderBuilds.isEmpty ? nil : placeholderBuilds)
    placeholder.text = "Sample"
    placeholder.x = 20; placeholder.y = 200; placeholder.width = 560; placeholder.height = 500
    var plate = SlideObject(
        id: "plate", objectKind: .shape, name: "Plate", text: "",
        fill: ObjectFill(fillKind: .solid, colorHex: "#112233FF")
    )
    plate.animationSteps = decorBuilds.isEmpty ? nil : decorBuilds
    return Theme(
        id: "side", name: "Stream Side Third", fontFamily: "Arial", fontSize: 40,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
        slides: [Slide(id: "side-1", name: "Lyrics", objects: [plate, placeholder], animationOrder: animationOrder)]
    )
}

@Test func placeholderBuildsDonateNamespacedAndRangeStripped() {
    let theme = sideThirdTheme(placeholderBuilds: [
        makeStep("in", .withPrevious, ranges: [AnimationRange(line: 0, column: 0, length: 5)]),
        makeStep("out", .onDismiss, .out),
    ])
    let donated = PlaceholderAnimations.composition(
        objects: [textObject("lyrics")], template: theme.slides?.first, slideOrder: nil
    )
    let animationSteps = donated.objects[0].animationSteps ?? []
    #expect(animationSteps.map(\.id) == ["lyrics::in", "lyrics::out"])
    #expect(animationSteps[0].ranges == nil, "ranges anchor the placeholder's sample text — stripped")
    #expect(animationSteps[0].trigger == .withPrevious)
    #expect(animationSteps[1].kind == .out)
}

@Test func ownBuildsWinOverPlaceholder() {
    let theme = sideThirdTheme(placeholderBuilds: [makeStep("theme-in", .onClick)])
    let own = [makeStep("own-in", .withPrevious)]
    let donated = PlaceholderAnimations.composition(
        objects: [textObject("lyrics", animationSteps: own)], template: theme.slides?.first, slideOrder: nil
    )
    #expect(donated.objects[0].animationSteps == own, "never a merge — own steps take everything")
}

@Test func templateOrderExpandsDonatedIDsAndSlideOrderWinsVerbatim() {
    let theme = sideThirdTheme(
        placeholderBuilds: [makeStep("in", .onClick)],
        decorBuilds: [makeStep("plate-in", .withPrevious)],
        animationOrder: ["plate-in", "in"]
    )

    let objects = [textObject("a"), textObject("b", name: "Other")]
    let donated = PlaceholderAnimations.composition(
        objects: objects, template: theme.slides?.first, slideOrder: nil
    )
    #expect(donated.order == ["plate-in", "a::in", "b::in"])
    #expect(donated.objects.map { $0.animationSteps?.first?.id } == ["a::in", "b::in"])

    let ordered = PlaceholderAnimations.composition(
        objects: objects, template: theme.slides?.first, slideOrder: ["mine"]
    )
    #expect(ordered.order == ["mine"])

    let bare = PlaceholderAnimations.composition(objects: objects, template: nil, slideOrder: nil)
    #expect(bare.objects == objects)
}

private func plainSlide() -> Slide {
    Slide(id: "s1", name: "Verse 1", objects: [textObject("lyrics")])
}

@Test func overrideOnlyClickBuildConsumesAdvancesAndArmsTheClock() {
    var show = ShowState()
    show.slideThemeOverrides = [sideThirdTheme(placeholderBuilds: [makeStep("in", .onClick)])]
    show.fire(slide: plainSlide(), atHostTime: 100)

    #expect(show.slideClickCount == 1)
    #expect(show.slideAnimationContext == AnimationContext(anchorHostTime: 100))
    let first = show.advanceStep(atHostTime: 101)
    #expect(first)
    let second = show.advanceStep(atHostTime: 102)
    #expect(!second, "second advance = next slide")

    show.slideThemeOverrides = []
    show.fire(slide: plainSlide(), atHostTime: 200)
    #expect(show.slideClickCount == 0)
    #expect(show.slideAnimationContext == nil)
}

@Test func clickOffPlaysTheThirdOutWhileTheSlideStaysLive() {

    var show = ShowState()
    show.slideThemeOverrides = [sideThirdTheme(placeholderBuilds: [
        makeStep("in", .withPrevious),
        makeStep("out", .onClick, .out, duration: 0.4),
    ])]
    show.fire(slide: plainSlide(), atHostTime: 10)
    #expect(show.slideClickCount == 1)
    let off = show.advanceStep(atHostTime: 15)
    #expect(off)
    #expect(show.liveSlide != nil, "the click-off never removes the slide")
    let advance = show.advanceStep(atHostTime: 16)
    #expect(!advance, "next advance = next slide")
    show.clear(layer: .slide, atHostTime: 20)
    #expect(show.liveSlide == nil, "clear after the click-off cuts — the leave already played")

    show.slideThemeOverrides = [sideThirdTheme(placeholderBuilds: [
        makeStep("in", .withPrevious),
        makeStep("out", .onClick, .out, duration: 0.4),
    ])]
    show.fire(slide: plainSlide(), atHostTime: 30)
    show.clear(layer: .slide, atHostTime: 40)
    #expect(show.liveSlide != nil)
    let early = show.sweepFinishedExits(now: 40.3)
    #expect(!early)
    let done = show.sweepFinishedExits(now: 40.5)
    #expect(done)
    #expect(show.liveSlide == nil)
}

@Test func overrideOnlyOutDefersTheClear() {
    var show = ShowState()
    show.slideThemeOverrides = [sideThirdTheme(placeholderBuilds: [
        makeStep("in", .withPrevious),
        makeStep("out", .onDismiss, .out, duration: 0.4),
    ])]
    show.fire(slide: plainSlide(), atHostTime: 10)
    show.clear(layer: .slide, atHostTime: 20)
    #expect(show.liveSlide != nil, "the stream-side Out plays before removal")
    let early = show.sweepFinishedExits(now: 20.3)
    #expect(!early)
    let done = show.sweepFinishedExits(now: 20.5)
    #expect(done)
    #expect(show.liveSlide == nil)
}

@Test func sceneDonatesOnlyThroughTheThemeThatOwnsTheBuilds() {
    let override = sideThirdTheme(placeholderBuilds: [makeStep("in", .withPrevious)])
    var show = ShowState()
    show.slideThemeOverrides = [override]
    show.fire(slide: plainSlide(), atHostTime: 5)
    func slideItems(_ scene: RenderScene) -> [RenderItem] {
        scene.layers.first { $0.kind == .slide }?.items ?? []
    }
    let base = slideItems(show.scene())
    #expect(base.contains { $0.id.hasPrefix("lyrics") })
    #expect(base.allSatisfy { $0.animationSteps.isEmpty }, "the projector theme renders static")
    let variant = slideItems(show.scene(slideThemeOverride: override))
    let built = variant.filter { !$0.animationSteps.isEmpty }
    #expect(built.contains { $0.id.hasPrefix("lyrics") }, "the override output animationSteps the side third")
    #expect(built.allSatisfy { $0.animationSteps.map(\.id) == ["lyrics::in"] })
    #expect(built.allSatisfy { $0.animationContext == AnimationContext(anchorHostTime: 5) },
            "override-only animationSteps still ride the shared clock")
}

@Test func chipClickCountPredictsAcrossThemes() {

    let side = sideThirdTheme(placeholderBuilds: [makeStep("in", .onClick)])
    let bare = plainSlide()
    #expect(PlaceholderAnimations.clickCount(slide: bare, themes: [nil]) == 0)
    #expect(PlaceholderAnimations.clickCount(slide: bare, themes: [nil, side]) == 1)

    let own = Slide(id: "s2", name: "Verse 2", objects: [
        textObject("t", animationSteps: [makeStep("a", .onClick), makeStep("b", .onClick)])
    ])
    #expect(PlaceholderAnimations.clickCount(slide: own, themes: [nil, side]) == 2)

    let auto = sideThirdTheme(placeholderBuilds: [makeStep("in", .withPrevious)])
    #expect(PlaceholderAnimations.clickCount(slide: bare, themes: [nil, auto]) == 0)
    #expect(PlaceholderAnimations.hasAnimationSteps(slide: bare, themes: [nil, auto]))
    #expect(!PlaceholderAnimations.hasAnimationSteps(slide: bare, themes: [nil]))
}

@Test func upcomingRevealReadsTheOverrideComposition() {
    var show = ShowState()
    show.slideThemeOverrides = [sideThirdTheme(placeholderBuilds: [makeStep("in", .onClick)])]
    show.fire(slide: plainSlide(), atHostTime: 1)
    #expect(show.upcomingRevealText() == "Amazing grace")
    let consumed = show.advanceStep(atHostTime: 2)
    #expect(consumed)
    #expect(show.upcomingRevealText() == nil)
}

private func slideLayerItems(_ scene: RenderScene) -> [RenderItem] {
    scene.layers.first { $0.kind == .slide }?.items ?? []
}

@Test func aSameLookSlideHoldsTheStreamsBuild() {
    let override = sideThirdTheme(
        placeholderBuilds: [makeStep("in", .withPrevious), makeStep("out", .onDismiss, .out, duration: 0.4)],
        decorBuilds: [makeStep("plate-in", .withPrevious)])
    var show = ShowState()
    show.slideThemeOverrides = [override]
    show.fire(slide: plainSlide(), atHostTime: 5)
    #expect(!show.holdsLook(through: override), "the first slide builds in")
    var second = plainSlide()
    second.id = "s2"
    show.fire(slide: second, atHostTime: 9)
    #expect(show.holdsLook(through: override))
    let built = slideLayerItems(show.scene(slideThemeOverride: override)).filter { !$0.animationSteps.isEmpty }
    #expect(built.count == 2, "the words and the plate")
    let plate = built.first { !$0.id.hasPrefix("lyrics") }
    let words = built.first { $0.id.hasPrefix("lyrics") }
    #expect(plate?.animationContext?.autoSettled == true, "the plate stays put")
    #expect(words?.animationContext?.autoSettled != true && words?.animationContext?.anchorHostTime == 9)
    #expect(words?.animationSteps.map { "\($0.animation) \($0.duration)" } == ["fade 0.3", "move 0.4"], "the words fade in over the plate; the Out stays the design's")
    #expect(slideLayerItems(show.scene()).allSatisfy { $0.animationContext?.autoSettled != true }, "the projector restarts as before")

    show.fire(slide: second, atHostTime: 10)
    #expect(!show.holdsLook(through: override))
    show.fire(slide: plainSlide(), atHostTime: 11)
    show.fire(slide: Slide(id: "blank", name: "", objects: []), atHostTime: 12)
    #expect(!show.holdsLook(through: override))
    show.fire(slide: plainSlide(), atHostTime: 13)
    show.clear(layer: .slide, atHostTime: 14)
    show.fire(slide: second, atHostTime: 14.1)
    #expect(!show.holdsLook(through: override), "a slide already leaving hands nothing over")
}

@Test func theHandOffWaitsForTheOldLooksOutOnlyWhenTheLookChanges() {
    let side = sideThirdTheme(placeholderBuilds: [makeStep("in", .withPrevious), makeStep("out", .onDismiss, .out, duration: 0.4)])
    var show = ShowState()
    show.slideThemeOverrides = [side]
    var second = plainSlide()
    second.id = "s2"
    #expect(show.handoffWait(to: second, incomingOverrides: [side]) == 0, "nothing live")
    show.fire(slide: plainSlide(), atHostTime: 5)
    #expect(show.handoffWait(to: second, incomingOverrides: [side]) == 0, "the same look holds")
    #expect(show.handoffWait(to: second, incomingOverrides: []) == 0.4, "the look leaves with the preset switch")
    #expect(show.handoffWait(to: Slide(id: "b", name: "", objects: []), incomingOverrides: [side]) == 0.4, "a blank takes the look down")
    #expect(show.handoffWait(to: plainSlide(), incomingOverrides: []) == 0, "a re-fire never waits")

    var twoDesigns = side
    twoDesigns.slides?.append(Slide(id: "side-2", name: "Points", objects: [textObject("ph2", name: "Points")]))
    show.slideThemeOverrides = [twoDesigns]
    var points = second
    points.themeSlideName = "Points"
    #expect(show.handoffWait(to: points, incomingOverrides: [twoDesigns]) == 0.4)
    #expect(show.handoffWait(to: second, incomingOverrides: [twoDesigns]) == 0)
    show.clear(layer: .slide, atHostTime: 6)
    #expect(show.handoffWait(to: second, incomingOverrides: []) == 0, "already leaving")
}

@Test func theExitPressBreaksTheHoldAndOnlyTheChangingLookGoesDown() {
    let side = sideThirdTheme(placeholderBuilds: [makeStep("in", .withPrevious), makeStep("out", .onDismiss, .out, duration: 0.4)])
    var lower = sideThirdTheme(placeholderBuilds: [makeStep("in", .withPrevious), makeStep("out", .onDismiss, .out, duration: 0.2)])
    lower.id = "lower"
    var show = ShowState()
    show.slideThemeOverrides = [side, lower]
    var second = plainSlide()
    second.id = "s2"
    show.fire(slide: plainSlide(), atHostTime: 1)

    let pressed = show.advanceStep(atHostTime: 2)
    #expect(pressed)
    #expect(show.handoffWait(to: second, incomingOverrides: []) == 0, "the Out already played")
    show.fire(slide: second, atHostTime: 3)
    #expect(!show.holdsLook(through: side) && !show.holdsLook(through: lower))

    let change = show.handoff(to: plainSlide(), incomingOverrides: [lower])
    #expect(change.wait == 0.4 && change.leaving.map(\.id) == ["side"])
    show.dismissLooks(change.leaving, atHostTime: 5)
    func context(_ theme: Theme?) -> AnimationContext? {
        slideLayerItems(theme.map { show.scene(slideThemeOverride: $0) } ?? show.scene()).first { !$0.animationSteps.isEmpty }?.animationContext
    }
    #expect(context(side)?.dismissHostTime == 5, "the side third plays its Out")
    #expect(context(lower)?.dismissHostTime == nil && context(nil)?.dismissHostTime == nil, "the lower third and the projector run on")
    #expect(show.liveSlide != nil && show.slideDismissAt == nil)
    #expect(show.handoff(to: plainSlide(), incomingOverrides: [lower]).wait == 0, "taken down already")
    show.fire(slide: plainSlide(), atHostTime: 5.4)
    #expect(show.lookDismissAt.isEmpty && show.holdsLook(through: lower))

    show.slideThemeOverrides = [side, lower]
    let mid = show.lookSwitch(to: [lower])
    #expect(mid.wait == 0.4 && mid.leaving.map(\.id) == ["side"])
    #expect(show.lookSwitch(to: [side, lower]).wait == 0)
    show.dismissLooks(mid.leaving, atHostTime: 6)
    #expect(context(side)?.dismissHostTime == 6 && context(lower)?.dismissHostTime == nil)
}

@Test func aClickedOffLookBuildsInAgainOnTheNextSlide() {

    let side = sideThirdTheme(
        placeholderBuilds: [makeStep("in", .withPrevious), makeStep("out", .onClick, .out, duration: 0.4)],
        decorBuilds: [makeStep("plate-in", .withPrevious), makeStep("plate-out", .withPrevious, .out, duration: 0.4)],
        animationOrder: ["plate-in", "in", "out", "plate-out"])
    var show = ShowState()
    show.slideThemeOverrides = [side]
    var second = plainSlide()
    second.id = "s2"
    show.fire(slide: plainSlide(), atHostTime: 1)
    #expect(show.slideAnimationStep.map { "\($0.consumed)/\($0.total)" } == "0/1")

    show.fire(slide: second, atHostTime: 2)
    #expect(show.holdsLook(through: side))

    show.fire(slide: plainSlide(), atHostTime: 3)
    let clickedOff = show.advanceStep(atHostTime: 4)
    #expect(clickedOff && show.slideExitAt == nil, "a click-off is a click, not the exit press")
    #expect(show.handoffWait(to: second, incomingOverrides: [side]) == 0, "nothing left to wait for")
    show.fire(slide: second, atHostTime: 5)
    #expect(!show.holdsLook(through: side))
    let built = slideLayerItems(show.scene(slideThemeOverride: side)).filter { !$0.animationSteps.isEmpty }
    #expect(built.allSatisfy { $0.animationContext?.autoSettled != true && $0.animationContext?.anchorHostTime == 5 }, "the plate and the words build in from the fire")
    let words = built.first { $0.id.hasPrefix("lyrics") }
    #expect(words?.animationSteps.map { "\($0.animation)" } == ["move", "move"], "the design's In, not the hold's fade")

    var points = plainSlide()
    points.id = "points"
    points.objects = [textObject("lyrics", animationSteps: [
        makeStep("p1-in", .withPrevious), makeStep("p1-out", .onClick, .out), makeStep("all-out", .onClick, .out, duration: 0.4)])]
    show.fire(slide: points, atHostTime: 6)
    let firstOut = show.advanceStep(atHostTime: 7)
    #expect(firstOut)
    show.fire(slide: second, atHostTime: 8)
    #expect(show.holdsLook(through: side), "one Out clicked, the leave still has the rest to play")

    show.fire(slide: plainSlide(), atHostTime: 9)
    show.dismissLooks([side], atHostTime: 10)
    show.fire(slide: second, atHostTime: 10.5)
    #expect(!show.holdsLook(through: side))
}
