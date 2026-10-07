import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func step(
    _ id: String, _ trigger: AnimationTrigger, _ kind: AnimationKind = .in,
    duration: Double = 0.5
) -> AnimationStep {
    AnimationStep(id: id, kind: kind, animation: .fade, trigger: trigger, durationSeconds: duration)
}

private func exitSlide() -> Slide {
    let object = SlideObject(
        id: "o", objectKind: .text, name: "Points", text: "one\ntwo\nthree",
        animationSteps: [
            step("c1", .onClick), step("c2", .onClick), step("c3", .onClick),
            step("x1", .onDismiss, .out, duration: 0.4),
        ]
    )
    return Slide(id: "s1", name: "Points", objects: [object])
}

@Test func theExitGroupIsTheFinalClick() {
    var show = ShowState()
    show.fire(slide: exitSlide(), atHostTime: 100)
    #expect(show.slideClickCount == 3)
    #expect(show.slideHasExitGroup)
    #expect(show.slideAdvanceCount == 4, "clicks + the exit press")
    #expect(show.slideAnimationStep?.total == 4)
    let r1 = show.advanceStep(atHostTime: 101)
    #expect(r1)
    let r2 = show.advanceStep(atHostTime: 102)
    #expect(r2)
    let r3 = show.advanceStep(atHostTime: 103)
    #expect(r3)
    #expect(show.slideAnimationStep?.consumed == 3)

    let r4 = show.advanceStep(atHostTime: 104)
    #expect(r4)
    #expect(show.liveSlide != nil, "the exit press never removes the cue")
    #expect(show.slideExitAt == 104)
    #expect(show.slideAnimationStep?.consumed == 4)
    #expect(show.slideAnimationContext?.exitHostTime == 104)
    #expect(!show.hasPendingExits, "self-removal keys ONLY off dismiss")
    let r5 = show.sweepFinishedExits(now: 1_000)
    #expect(!r5, "a final-click exit never self-removes")
    #expect(show.liveSlide != nil)

    let r6 = show.advanceStep(atHostTime: 104.1)
    #expect(!r6, "second advance mid-exit falls through immediately")
}

@Test func backUnplaysTheExitBeforeUnconsumingClicks() {
    var show = ShowState()
    show.fire(slide: exitSlide(), atHostTime: 100)
    for t in [101.0, 102, 103, 104] { _ = show.advanceStep(atHostTime: t) }
    #expect(show.slideExitAt == 104)
    let r7 = show.unadvanceStep()
    #expect(r7)
    #expect(show.slideExitAt == nil, "back un-plays the exit; content returns")
    #expect(show.slideAdvanceClicks.count == 3, "the clicks are untouched")
    let r8 = show.unadvanceStep()
    #expect(r8)
    #expect(show.slideAdvanceClicks.count == 2)
}

@Test func clearAfterTheExitPlayedRemovesImmediately() {
    var show = ShowState()
    show.fire(slide: exitSlide(), atHostTime: 100)
    for t in [101.0, 102, 103, 104] { _ = show.advanceStep(atHostTime: t) }
    show.clear(function: .slides, atHostTime: 104.2)
    #expect(show.liveSlide == nil, "the leave already played; a clear cuts, never replays it")
    #expect(show.lastSlide?.slide.id == "s1")
}

@Test func directFiresAlwaysCut() {
    var show = ShowState()
    show.fire(slide: exitSlide(), atHostTime: 100)
    for t in [101.0, 102, 103, 104] { _ = show.advanceStep(atHostTime: t) }
    let next = Slide(id: "s2", name: "Next", objects: [])
    show.fire(slide: next, atHostTime: 104.1)
    #expect(show.liveSlide?.slide.id == "s2")
    #expect(show.slideExitAt == nil, "a fire clears the exit stamp")
    #expect(show.slideAdvanceClicks.isEmpty)
}

@Test func settledArrivalSkipsTheWithSlideCeremony() {
    let object = SlideObject(
        id: "o", objectKind: .text, name: "T", text: "hi",
        animationSteps: [step("auto-in", .withPrevious, duration: 2), step("c1", .onClick)]
    )
    let slide = Slide(id: "s", name: "S", objects: [object])
    var show = ShowState()
    show.fire(slide: slide, atHostTime: 100, arrivesSettled: true)
    let context = show.slideAnimationContext
    #expect(context?.autoSettled == true)
    let steps = AnimationSequence.sceneSteps(objects: slide.objects, order: nil)["o"] ?? []
    let autoStep = steps.first { $0.id == "auto-in" }!
    let clickStep = steps.first { $0.id == "c1" }!

    #expect(AnimationTimeline.phase(of: autoStep, context: context, now: 100.01) == .done)
    #expect(AnimationTimeline.phase(of: clickStep, context: context, now: 100.01) == .pending)

    show.fire(slide: slide, atHostTime: 200)
    #expect(show.slideAnimationContext?.autoSettled == false)
}

@Test func exitAnchorPrefersTheFinalClickOverDismiss() {
    let context = AnimationContext(
        anchorHostTime: 0, dismissHostTime: 50, exitHostTime: 10
    )
    #expect(context.start(of: .exit) == 10, "a played exit anchors the group")
    let dismissed = AnimationContext(anchorHostTime: 0, dismissHostTime: 50)
    #expect(dismissed.start(of: .exit) == 50, "no exit press = the dismiss anchors it")
}

@Test func stepsCompletedAtGatesOnEveryHumanPress() {
    var show = ShowState()
    show.fire(slide: exitSlide(), atHostTime: 100)
    #expect(show.slideStepsCompletedAt() == nil, "clicks pending — never auto-click")
    for t in [101.0, 102, 103] { _ = show.advanceStep(atHostTime: t) }
    #expect(show.slideStepsCompletedAt() == nil, "the exit press is a human step too")
    _ = show.advanceStep(atHostTime: 104)
    #expect(show.slideStepsCompletedAt() == 104.4, "exit press + the exit group's animations")

    _ = show.unadvanceStep()
    #expect(show.slideStepsCompletedAt() == nil)
}

@Test func stepsCompletedAtForClickOnlyAndPlainSlides() {

    let clickObject = SlideObject(
        id: "o", objectKind: .text, name: "T", text: "a\nb",
        animationSteps: [step("c1", .onClick, duration: 1), step("c2", .onClick, duration: 2)]
    )
    var show = ShowState()
    show.fire(slide: Slide(id: "s", name: "S", objects: [clickObject]), atHostTime: 10)
    _ = show.advanceStep(atHostTime: 11)
    #expect(show.slideStepsCompletedAt() == nil)
    _ = show.advanceStep(atHostTime: 12)
    #expect(show.slideStepsCompletedAt() == 14, "last click + that group's duration")

    show.fire(slide: Slide(id: "p", name: "P", objects: []), atHostTime: 20)
    #expect(show.slideStepsCompletedAt() == 20)
}
