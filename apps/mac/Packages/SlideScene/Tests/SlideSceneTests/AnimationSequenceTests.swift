import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func step(
    _ id: String, _ trigger: AnimationTrigger, _ kind: AnimationKind = .in, delay: Double? = nil,
    duration: Double = 1, ranges: [AnimationRange]? = nil, ramp: AnimationRamp? = nil
) -> AnimationStep {
    AnimationStep(id: id, kind: kind, animation: .fade, trigger: trigger, delaySeconds: delay,
              durationSeconds: duration, ramp: ramp, ranges: ranges)
}

private func object(_ id: String, _ animationSteps: [AnimationStep], hidden: Bool? = nil) -> SlideObject {
    SlideObject(id: id, objectKind: .text, name: id, text: "one two\nthree", hidden: hidden, animationSteps: animationSteps)
}

@Test func documentOrderThenBuildOrderWins() {
    let objects = [
        object("a", [step("a1", .onClick), step("a2", .withPrevious)]),
        object("b", [step("b1", .onClick)]),
    ]
    #expect(AnimationSequence.orderedEntries(objects: objects, order: nil).map(\.step.id) == ["a1", "a2", "b1"])
    #expect(AnimationSequence.orderedEntries(objects: objects, order: ["b1", "zzz", "b1"]).map(\.step.id)
            == ["b1", "a1", "a2"], "listed first, unknown/dupes ignored, rest in document order")
    let hiddenObjects = [object("h", [step("h1", .onClick)], hidden: true)] + objects
    #expect(!AnimationSequence.orderedEntries(objects: hiddenObjects, order: nil).contains { $0.objectID == "h" })
}

@Test func clickGroupsAutoAndExit() {
    let objects = [
        object("bar", [step("bar-in", .withPrevious), step("bar-out", .onDismiss, .out)]),
        object("p1", [step("p1", .onClick)]),
        object("p2", [step("p2", .onClick), step("p2b", .afterPrevious)]),
        object("p3", [step("p3", .onClick), step("p3-out", .onDismiss, .out), step("tail", .withPrevious)]),
    ]
    let g = AnimationSequence.groups(objects: objects, order: nil)
    #expect(g.auto.map(\.step.id) == ["bar-in"], "leading non-click steps run from the fire")
    #expect(g.click.map { $0.map(\.step.id) } == [["p1"], ["p2", "p2b"], ["p3"]])
    #expect(g.exit.map(\.step.id) == ["bar-out", "p3-out", "tail"], "chained-after-dismiss joins the exit group")
    #expect(AnimationSequence.clickCount(objects: objects, order: nil) == 3)
    #expect(AnimationSequence.hasAnimationSteps(objects))
    #expect(!AnimationSequence.hasAnimationSteps([object("x", [])]))
}

@Test func scheduleFoldsChainingIntoOffsets() {
    let objects = [
        object("a", [step("a1", .onClick, delay: 0.25, duration: 1)]),
        object("b", [step("b1", .withPrevious, delay: 0.1, duration: 2)]),
        object("c", [step("c1", .afterPrevious, delay: 0.5, duration: 1)]),
        object("d", [step("d1", .onClick, duration: 3), step("d2", .onDismiss, .out, delay: 1, duration: 0.4)]),
        object("e", [step("e1", .onDismiss, .out, duration: 2), step("e2", .afterPrevious, duration: 1)]),
    ]
    let steps = AnimationSequence.sceneSteps(objects: objects, order: nil)
    #expect(steps["a"]?.first?.group == .click(0))
    #expect(steps["a"]?.first?.startOffset == 0.25)
    #expect(steps["b"]?.first?.startOffset == 0.35, "with previous = previous start + delay")
    #expect(steps["c"]?.first?.startOffset == 2.85, "after previous = previous end + delay")
    #expect(steps["d"]?.map(\.group) == [.click(1), .exit])
    #expect(steps["d"]?[1].startOffset == 1, "each onDismiss keys off the dismiss instant")
    #expect(steps["e"]?[0].startOffset == 0)
    #expect(steps["e"]?[1].startOffset == 2)
    #expect(AnimationSequence.exitDuration(objects: objects, order: nil) == 3, "e1 (2s) then e2 (1s)")
    #expect(AnimationSequence.exitDuration(objects: [objects[0]], order: nil) == 0)
}

@Test func schemaToEngineDefaults() {
    let ranges = [AnimationRange(line: 0, column: 4, length: 3)]
    let inStep = AnimationSequence.sceneStep(step("i", .onClick, .in, ranges: ranges), group: .click(0), startOffset: 0)
    #expect(inStep.kind == .enter)
    #expect(inStep.ramp == .easeOut, "In defaults to ease-out")
    #expect(inStep.ranges == [SceneAnimationRange(line: 0, column: 4, length: 3)])
    let outStep = AnimationSequence.sceneStep(step("o", .onDismiss, .out), group: .exit, startOffset: 0)
    #expect(outStep.kind == .exit)
    #expect(outStep.ramp == .easeIn, "Out defaults to ease-in")
    #expect(outStep.targetsWholeObject)
    let emph = AnimationSequence.sceneStep(step("e", .onClick, .emphasis, ramp: AnimationRamp.none), group: .click(0), startOffset: 0)
    #expect(emph.ramp == .none, "explicit ramp wins")
    var blur = step("b", .onClick, .in)
    blur.animation = .blur
    blur.colorHex = "#FF000080"
    let engineBlur = AnimationSequence.sceneStep(blur, group: .click(0), startOffset: 0)
    #expect(engineBlur.amount == 24, "blur radius default")
    #expect(engineBlur.color?.alpha == 128.0 / 255)

    var colorEmph = step("c", .onClick, .emphasis)
    colorEmph.animation = .color
    let engineColor = AnimationSequence.sceneStep(colorEmph, group: .click(0), startOffset: 0)
    #expect(engineColor.color == ColorHex.color("#FFD54FFF"))
    #expect(engineColor.amount == 0.6, "tint strength default")

    let empty = AnimationSequence.sceneStep(step("x", .onClick, .in, ranges: []), group: .auto, startOffset: 0)
    #expect(empty.ranges == nil)
}

@Test func endToEndThreePointsOnThreeClicks() {

    let lines = (0..<3).map { AnimationRange(line: $0, column: 0, length: 5) }
    let objects = [object("pts", lines.map { step("l\($0.line)", .onClick, .in, duration: 0.5, ranges: [$0]) })]
    let steps = AnimationSequence.sceneSteps(objects: objects, order: nil)["pts"] ?? []
    #expect(AnimationSequence.clickCount(objects: objects, order: nil) == 3)
    let fired = AnimationContext(anchorHostTime: 0)
    #expect(AnimationTimeline.visibility(of: steps, context: fired, now: 1).hiddenRanges.count == 3)
    let two = AnimationContext(anchorHostTime: 0, clickHostTimes: [1, 2])
    #expect(AnimationTimeline.visibility(of: steps, context: two, now: 3).hiddenRanges.map(\.line) == [2])
    let three = AnimationContext(anchorHostTime: 0, clickHostTimes: [1, 2, 3])
    #expect(AnimationTimeline.visibility(of: steps, context: three, now: 3.1).hiddenRanges.isEmpty)
}

@Test func unclickedOutPlaysAtDismissAndConsumedOutDoesNotReplay() {

    let objects = [object("t", [
        step("in", .withPrevious, duration: 0.3),
        step("out", .onClick, .out, duration: 0.4),
    ])]
    let steps = AnimationSequence.sceneSteps(objects: objects, order: nil).values.flatMap { $0 }
    let out = steps.first { $0.id == "out" }!

    let dismissed = AnimationContext(anchorHostTime: 0, dismissHostTime: 10)
    #expect(AnimationTimeline.phase(of: out, context: dismissed, now: 9).hasStarted == false)
    #expect(AnimationTimeline.phase(of: out, context: dismissed, now: 10.2).hasStarted)
    #expect(AnimationTimeline.visibility(of: steps, context: dismissed, now: 10.5).hidesWholeObject)

    let clicked = AnimationContext(anchorHostTime: 0, clickHostTimes: [5], dismissHostTime: 20)
    #expect(AnimationTimeline.visibility(of: steps, context: clicked, now: 5.5).hidesWholeObject)
    #expect(AnimationTimeline.phase(of: out, context: clicked, now: 20.2).isDone, "played once, at its click")

    let gated = [object("g", [
        step("g.in", .onClick),
        step("g.out", .onClick, .out, duration: 0.4),
    ])]
    let gatedSteps = AnimationSequence.sceneSteps(objects: gated, order: nil).values.flatMap { $0 }
    #expect(AnimationTimeline.visibility(of: gatedSteps, context: dismissed, now: 10.2).hidesWholeObject)
}

@Test func exitDurationCountsUnconsumedClickOuts() {
    let objects = [object("t", [
        step("in", .withPrevious, duration: 0.3),
        step("out", .onClick, .out, duration: 0.4),
        step("tail", .onDismiss, .out, duration: 0.2),
    ])]
    #expect(AnimationSequence.exitDuration(objects: objects, order: nil, consumedClicks: 0) == 0.4,
            "the un-clicked out extends the leave past the exit group")
    #expect(AnimationSequence.exitDuration(objects: objects, order: nil, consumedClicks: 1) == 0.2,
            "consumed = already played; only the exit group remains")
}

private func pointsSlide() -> Slide {
    let lines = (0..<3).map { AnimationRange(line: $0, column: 0, length: 5) }
    let object = SlideObject(
        id: "pts", objectKind: .text, name: "Points", text: "one\ntwo\nthree",
        animationSteps: lines.map { step("l\($0.line)", .onClick, duration: 0.5, ranges: [$0]) }
    )
    return Slide(id: "s1", name: "Points", objects: [object])
}

@Test func threeClicksRevealThreePointsThenTheFourthIsFree() {
    var show = ShowState()
    show.fire(slide: pointsSlide(), atHostTime: 100)
    #expect(show.slideClickCount == 3)
    #expect(show.slideAnimationStep?.consumed == 0)
    let r1 = show.advanceStep(atHostTime: 101)
    #expect(r1)
    let r2 = show.advanceStep(atHostTime: 102)
    #expect(r2)
    let r3 = show.advanceStep(atHostTime: 103)
    #expect(r3)
    #expect(show.slideAnimationStep?.consumed == 3)
    let r4 = show.advanceStep(atHostTime: 104)
    #expect(!r4, "4th advance = next slide")
    #expect(show.slideAnimationContext == AnimationContext(anchorHostTime: 100, clickHostTimes: [101, 102, 103]))

    let items = show.scene().layers.first { $0.kind == .slide }?.items ?? []
    #expect(items.contains { $0.animationContext?.clickHostTimes == [101, 102, 103] && $0.animationSteps.count == 3 })

    let r5 = show.unadvanceStep()
    #expect(r5)
    #expect(show.slideAnimationStep?.consumed == 2)

    show.fire(slide: pointsSlide(), atHostTime: 200)
    #expect(show.slideAdvanceClicks.isEmpty)

    show.fire(slide: Slide(id: "plain", name: "Plain", objects: [object("t", [])]), atHostTime: 300)
    let r6 = show.advanceStep(atHostTime: 301)
    #expect(!r6)
    let r7 = show.unadvanceStep()
    #expect(!r7)
    #expect(show.slideAnimationContext == nil)
    #expect(show.slideAnimationStep == nil)
}

private func lowerThird() -> Overlay {
    Overlay(id: "lt", name: "Lower Third", objects: [
        SlideObject(id: "plate", objectKind: .shape, name: "Plate", text: "", animationSteps: [
            step("in", .withPrevious, duration: 0.6),
            step("out", .onDismiss, .out, duration: 0.4),
        ]),
    ])
}

@Test func overlayWithTimedOutDisappearsUnaidedAndClearAllCuts() {
    var show = ShowState()
    show.fire(overlay: lowerThird(), atHostTime: 10)

    show.dismissOverlay(id: "lt", atHostTime: 20)
    #expect(show.liveOverlays.count == 1)
    #expect(show.overlayDismissAt["lt"] == 20)
    #expect(show.hasPendingExits)
    let items = show.scene().layers.first { $0.kind == .overlays }?.items ?? []
    #expect(items.first?.animationContext == AnimationContext(anchorHostTime: 10, dismissHostTime: 20))

    let r8 = show.sweepFinishedExits(now: 20.3)
    #expect(!r8)
    #expect(show.liveOverlays.count == 1)
    let r9 = show.sweepFinishedExits(now: 20.4)
    #expect(r9)
    #expect(show.liveOverlays.isEmpty)
    #expect(!show.hasPendingExits)
    #expect(show.overlayFiredAt["lt"] == nil)

    show.fire(overlay: lowerThird(), atHostTime: 30)
    show.clear(function: .overlays, atHostTime: 31)
    #expect(show.liveOverlays.count == 1, "Clear Function plays the Out first")
    show.fire(overlay: lowerThird(), atHostTime: 32)
    #expect(show.overlayDismissAt["lt"] == nil)

    show.clear(layer: .overlays, atHostTime: 40)
    #expect(show.liveOverlays.count == 1)
    show.clearAll()
    #expect(show.liveOverlays.isEmpty)
    #expect(!show.hasPendingExits)

    show.fire(overlay: lowerThird(), atHostTime: 50)
    show.dismissOverlay(id: "lt")
    #expect(show.liveOverlays.isEmpty)
    show.fire(overlay: Overlay(id: "plain", name: "Plain", objects: [object("x", [])]), atHostTime: 60)
    show.dismissOverlay(id: "plain", atHostTime: 61)
    #expect(show.liveOverlays.isEmpty)
}

@Test func slideClearDefersWhileItsOutPlaysAndClicksFreezeMeanwhile() {
    var slide = pointsSlide()
    slide.objects[0].animationSteps?.append(step("out", .onDismiss, .out, duration: 1))
    var show = ShowState()
    show.fire(slide: slide, atHostTime: 0)
    _ = show.advanceStep(atHostTime: 1)
    show.clear(function: .slides, atHostTime: 5)
    #expect(show.liveSlide != nil, "still on glass, playing its Out")
    #expect(show.slideDismissAt == 5)
    let r10 = show.advanceStep(atHostTime: 5.5)
    #expect(!r10, "no clicks while leaving")
    #expect(show.slideAnimationContext?.dismissHostTime == 5)
    let r11 = show.sweepFinishedExits(now: 5.9)
    #expect(!r11)
    let r12 = show.sweepFinishedExits(now: 6)
    #expect(r12)
    #expect(show.liveSlide == nil)
    #expect(show.lastSlide?.slide.id == "s1", "fired history still records it")

    show.fire(slide: slide, atHostTime: 10)
    show.clear(layer: .slide, atHostTime: 11)
    #expect(show.liveSlide != nil)
    show.fire(slide: pointsSlide(), atHostTime: 12)
    #expect(show.slideDismissAt == nil)
}

@Test func previewTimelineWalksEveryGroupAndFreezesOnScrub() {
    var slide = pointsSlide() 
    slide.objects[0].animationSteps?.append(step("out", .onDismiss, .out, duration: 1))
    let timeline = AnimationSequence.previewTimeline(objects: slide.objects, order: slide.animationOrder)

    #expect(zip(timeline.clicks, [0, 0.9, 1.8]).allSatisfy { abs($0 - $1) < 1e-9 })
    #expect(abs(timeline.dismissAt - (2.3 + AnimationSequence.previewExitHold)) < 1e-9)
    #expect(abs(timeline.duration - (timeline.dismissAt + 1)) < 1e-9)

    let frozen = AnimationSequence.previewContext(objects: slide.objects, order: nil, time: 1.0)
    #expect(frozen.frozenHostTime == 1.0)
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil, animationContext: frozen)
    let item = scene.layers.first { $0.kind == .slide }?.items.first { $0.id == "pts" }
    #expect(item?.animationContext == frozen)
    #expect(item?.animationSteps.count == 4)
    let steps = item?.animationSteps ?? []
    let vis = AnimationTimeline.visibility(of: steps, context: frozen, now: 999)
    #expect(vis.hiddenRanges.map(\.line) == [2], "frozen clock ignores the render clock")

    let plain = SlideSceneBuilder.scene(for: slide, theme: nil)
    #expect(plain.layers.first { $0.kind == .slide }?.items.first { $0.id == "pts" }?.animationContext == nil)
}

@Test func authoringWarningsFlagImpossibleOrder() {
    let objects = [
        object("a", [step("a-out", .onDismiss, .out), step("a-in", .onClick, .in), step("a-in2", .onClick, .in)]),
        object("b", [step("b-emph", .onClick, .emphasis)]),                          
        object("c", [step("c-emph", .onClick, .emphasis), step("c-in", .withPrevious, .in)]),
    ]
    let warnings = AnimationSequence.warnings(objects: objects, order: nil)
    #expect(warnings["a-out"] != nil, "Out before its In")
    #expect(warnings["a-in"] == nil)
    #expect(warnings["a-in2"] != nil, "second In while shown")
    #expect(warnings["b-emph"] == nil)
    #expect(warnings["c-emph"] != nil, "emphasis before the In")

    let ordered = AnimationSequence.warnings(objects: objects, order: ["a-in", "a-out"])
    #expect(ordered["a-out"] == nil)
    #expect(ordered["a-in"] == nil)
}

@Test func negativeDelayOverlapsThePreviousStep() {
    let objects = [
        object("frame", [step("draw", .onClick, duration: 1.2)]),
        object("title", [step("type", .afterPrevious, delay: -0.3, duration: 0.8)]),
        object("z", [step("early", .withPrevious, delay: -5, duration: 0.5)]),
    ]
    let steps = AnimationSequence.sceneSteps(objects: objects, order: nil)
    #expect(abs((steps["title"]?[0].startOffset ?? 0) - 0.9) < 1e-9, "starts 0.3s before the draw ends")
    #expect(steps["z"]?[0].startOffset == 0, "never before the group instant")
}

@Test func morphStepsRenderTheirEndStateOntoEveryItemOfTheObject() {
    var object = SlideObject(
        id: "box", objectKind: .shape, name: "Box", text: "Hi",
        x: 100, y: 100, width: 200, height: 100,
        fill: ObjectFill(fillKind: .solid, colorHex: "#FF0000FF")
    )
    var end = object
    end.x = 600; end.width = 300; end.shapeKind = .ellipse
    end.fill = ObjectFill(fillKind: .solid, colorHex: "#0000FFFF")
    end.animationSteps = [AnimationStep(id: "junk", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 1)]
    var morph = AnimationStep(id: "m", kind: .morph, animation: .fade, trigger: .onClick, durationSeconds: 1)
    morph.toObject = end
    var from = object
    from.x = -400
    var enter = AnimationStep(id: "in", kind: .in, animation: .move, trigger: .onClick, durationSeconds: 1)
    enter.fromObject = from
    object.animationSteps = [enter, morph]
    let slide = Slide(id: "s", name: "s", objects: [object])
    let steps = AnimationSequence.sceneSteps(objects: slide.objects, order: nil)["box"] ?? []
    let items = SlideSceneBuilder.renderItems(for: object, theme: nil, animationSteps: steps)
    #expect(items.count == 2, "shape + its ::text")
    for item in items {
        let inStep = item.animationSteps.first { $0.id == "in" }
        let mStep = item.animationSteps.first { $0.id == "m" }
        #expect(inStep?.fromItem?.frame.minX == -400)
        #expect(mStep?.toItem?.frame.minX == 600)
        #expect(mStep?.toItem?.id.hasSuffix("::text") == item.id.hasSuffix("::text"), "matched by suffix")
        #expect(mStep?.toItem?.animationSteps.isEmpty == true, "the end state's own animationSteps are ignored")
    }

    var bare = AnimationStep(id: "m2", kind: .morph, animation: .fade, trigger: .onClick, durationSeconds: 1)
    bare.toObject = nil
    let objs = [SlideObject(id: "o", objectKind: .text, name: "o", text: "x", animationSteps: [bare])]
    #expect(AnimationSequence.warnings(objects: objs, order: nil)["m2"] == "No end state yet")
}

@Test func groupedMoveTakesTheTriggerOfItsNewNeighbourhood() {
    let objects = [
        object("a", [step("a1", .onClick)]),
        object("b", [step("b1", .onClick)]),
        object("c", [step("c1", .onClick), step("c-out", .onDismiss, .out)]),
    ]

    let into = AnimationSequence.groupedMove(objects: objects, order: nil, moving: "b1", into: .click(0), position: 1)
    #expect(into?.order == ["a1", "b1", "c1", "c-out"])
    #expect(into?.triggers["b1"] == .withPrevious)

    let first = AnimationSequence.groupedMove(objects: objects, order: nil, moving: "c1", into: .click(0), position: 0)
    #expect(first?.order == ["c1", "a1", "b1", "c-out"])
    #expect(first?.triggers["c1"] == .onClick)
    #expect(first?.triggers["a1"] == .withPrevious)

    let exit = AnimationSequence.groupedMove(objects: objects, order: nil, moving: "a1", into: .exit, position: 0)
    #expect(exit?.order == ["b1", "c1", "a1", "c-out"])
    #expect(exit?.triggers["a1"] == .onDismiss)
    #expect(exit?.triggers["c-out"] == .withPrevious)

    let auto = AnimationSequence.groupedMove(objects: objects, order: nil, moving: "b1", into: .auto, position: 0)
    #expect(auto?.order.first == "b1")
    #expect(auto?.triggers["b1"] == .withPrevious)

    #expect(AnimationSequence.previewStart(ofStep: "b1", objects: objects, order: nil) == AnimationSequence.previewTimeline(objects: objects, order: nil).clicks[1])
}

@Test func removingAGroupsFirstStepPromotesItsFollower() {
    let objects = [
        object("a", [step("a1", .onClick), step("a2", .withPrevious)]),
        object("b", [step("b1", .onClick), step("b2", .afterPrevious)]),
        object("c", [step("c1", .onDismiss, .out), step("c2", .withPrevious, .out)]),
    ]
    #expect(AnimationSequence.promotion(afterRemoving: "a1", objects: objects, order: nil)?.stepID == "a2")
    #expect(AnimationSequence.promotion(afterRemoving: "a1", objects: objects, order: nil)?.trigger == .onClick)
    #expect(AnimationSequence.promotion(afterRemoving: "a2", objects: objects, order: nil) == nil, "not a first step")
    #expect(AnimationSequence.promotion(afterRemoving: "b1", objects: objects, order: nil)?.stepID == "b2")
    #expect(AnimationSequence.promotion(afterRemoving: "c1", objects: objects, order: nil)?.trigger == .onDismiss)
    #expect(AnimationSequence.promotion(afterRemoving: "b2", objects: objects, order: nil) == nil, "next is a click already")
}

@Test func upcomingRevealTextReadsTheComingClickGroup() {
    var points = SlideObject(id: "p", objectKind: .text, name: "Points", text: "One\nTwo\nThree")
    points.animationSteps = (0..<3).map { line in
        AnimationStep(id: "s\(line)", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5,
                  ranges: [AnimationRange(line: line, column: 0, length: 3 + (line == 2 ? 2 : 0))])
    }
    var shape = SlideObject(id: "sh", objectKind: .shape, name: "Accent Rule", text: "")
    shape.animationSteps = [AnimationStep(id: "shape-in", kind: .in, animation: .wipe, trigger: .onClick, durationSeconds: 0.5),
                    AnimationStep(id: "shape-out", kind: .out, animation: .wipe, trigger: .onClick, durationSeconds: 0.3)]
    let objects = [points, shape]
    let order = ["s0", "s1", "s2", "shape-in", "shape-out"]
    #expect(AnimationSequence.upcomingRevealText(objects: objects, order: order, consumed: 0) == "One")
    #expect(AnimationSequence.upcomingRevealText(objects: objects, order: order, consumed: 2) == "Three")
    #expect(AnimationSequence.upcomingRevealText(objects: objects, order: order, consumed: 3) == "Accent Rule",
            "a textless shape reads by name")
    #expect(AnimationSequence.upcomingRevealText(objects: objects, order: order, consumed: 4) == nil,
            "an Out-only click reveals nothing")
    #expect(AnimationSequence.upcomingRevealText(objects: objects, order: order, consumed: 5) == nil)
    #expect(AnimationSequence.upcomingRevealText(objects: [], order: nil, consumed: 0) == nil)
}

@Test func nextLinkPrefersTheComingStepOnlyWhenAsked() {
    var info = ConfidenceInfo()
    info.next = ConfidenceInfo.SlideText(body: "Whole next slide")
    info.nextStep = ConfidenceInfo.SlideText(body: "The coming step")
    let plain = TextLink(source: .nextSlide)
    var aware = plain
    aware.includeSteps = true
    #expect(LinkedText.resolve(plain, info: info, at: Date()) == "Whole next slide")
    #expect(LinkedText.resolve(aware, info: info, at: Date()) == "The coming step")

    info.nextStep = nil
    #expect(LinkedText.resolve(aware, info: info, at: Date()) == "Whole next slide")
}
