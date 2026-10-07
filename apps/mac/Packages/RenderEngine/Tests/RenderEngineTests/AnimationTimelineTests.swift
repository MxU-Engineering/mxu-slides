import Foundation
import Testing
@testable import RenderEngine

private func step(
    _ id: String, _ kind: SceneAnimationKind, group: SceneAnimationGroup, start: Double = 0,
    duration: Double = 1, ramp: SceneAnimationRamp = .none, ranges: [SceneAnimationRange]? = nil,
    placeholder: Bool = false
) -> SceneAnimationStep {
    SceneAnimationStep(
        id: id, kind: kind, animation: .fade, group: group, startOffset: start,
        duration: duration, ramp: ramp, ranges: ranges, placeholderUnderline: placeholder
    )
}

@Test func phaseFollowsGroupStartAndOffset() {
    let s = step("a", .enter, group: .click(0), start: 0.5, duration: 2)
    let ctx = AnimationContext(anchorHostTime: 100, clickHostTimes: [110])
    #expect(AnimationTimeline.phase(of: s, context: ctx, now: 105) == .pending, "click not consumed")
    #expect(AnimationTimeline.phase(of: s, context: AnimationContext(anchorHostTime: 100), now: 200) == .pending)
    #expect(AnimationTimeline.phase(of: s, context: ctx, now: 110.4) == .pending, "offset not elapsed")
    #expect(AnimationTimeline.phase(of: s, context: ctx, now: 111.5) == .running(0.5))
    #expect(AnimationTimeline.phase(of: s, context: ctx, now: 112.5) == .done)
    #expect(AnimationTimeline.phase(of: s, context: nil, now: 0) == .done, "no context = settled")
}

@Test func rampsEaseWithoutOvershoot() {
    #expect(SceneAnimationRamp.none.apply(0.25) == 0.25)
    #expect(SceneAnimationRamp.easeIn.apply(0.5) == 0.25)
    #expect(SceneAnimationRamp.easeOut.apply(0.5) == 0.75)
    #expect(SceneAnimationRamp.easeInOut.apply(0.5) == 0.5)
    #expect(SceneAnimationRamp.easeInOut.apply(1.5) == 1)
    #expect(SceneAnimationRamp.easeIn.apply(-1) == 0)
    let s = step("a", .enter, group: .auto, duration: 2, ramp: .easeOut)
    #expect(AnimationTimeline.phase(of: s, context: AnimationContext(anchorHostTime: 0), now: 1) == .running(0.75))
}

@Test func wholeObjectVisibilityGates() {
    let enter = step("in", .enter, group: .click(0), duration: 1)
    let exit = step("out", .exit, group: .click(1), duration: 1)
    let steps = [enter, exit]
    let ctx0 = AnimationContext(anchorHostTime: 0)
    #expect(AnimationTimeline.visibility(of: steps, context: ctx0, now: 5).hidesWholeObject, "In pending = hidden")
    let ctx1 = AnimationContext(anchorHostTime: 0, clickHostTimes: [10])
    #expect(!AnimationTimeline.visibility(of: steps, context: ctx1, now: 10.2).hidesWholeObject, "In running = shown")
    #expect(!AnimationTimeline.visibility(of: steps, context: ctx1, now: 20).hidesWholeObject, "settled between")
    let ctx2 = AnimationContext(anchorHostTime: 0, clickHostTimes: [10, 30])
    #expect(!AnimationTimeline.visibility(of: steps, context: ctx2, now: 30.5).hidesWholeObject, "Out running = still shown")
    #expect(AnimationTimeline.visibility(of: steps, context: ctx2, now: 31.5).hidesWholeObject, "Out done = hidden")
    #expect(!AnimationTimeline.visibility(of: steps, context: nil, now: 0).hidesWholeObject, "editor: settled shows")

    #expect(!AnimationTimeline.visibility(of: [exit], context: ctx0, now: 5).hidesWholeObject)

    let pulse = step("p", .emphasis, group: .click(0))
    #expect(!AnimationTimeline.visibility(of: [pulse], context: ctx0, now: 5).hidesWholeObject)
}

@Test func rangeVisibilityAndPlaceholders() {
    let r1 = SceneAnimationRange(line: 0, column: 0, length: 4)
    let r2 = SceneAnimationRange(line: 1, column: 2, length: 3)
    let s1 = step("a", .enter, group: .click(0), ranges: [r1], placeholder: true)
    let s2 = step("b", .enter, group: .click(1), ranges: [r2])
    let ctx = AnimationContext(anchorHostTime: 0, clickHostTimes: [10])
    let v = AnimationTimeline.visibility(of: [s1, s2], context: ctx, now: 10.5)
    #expect(!v.hidesWholeObject)
    #expect(v.hiddenRanges == [r2])
    #expect(v.placeholderRanges.isEmpty)
    let before = AnimationTimeline.visibility(of: [s1, s2], context: AnimationContext(anchorHostTime: 0), now: 1)
    #expect(before.hiddenRanges == [r1, r2])
    #expect(before.placeholderRanges == [r1], "fill-in-the-blank keeps its underline while hidden")
}

@Test func groupCompletionAndDuration() {
    let a = step("a", .exit, group: .exit, start: 0, duration: 1)
    let b = step("b", .exit, group: .exit, start: 0.5, duration: 1)
    let steps = [a, b, step("c", .enter, group: .auto)]
    #expect(AnimationTimeline.groupDuration(.exit, in: steps) == 1.5)
    #expect(AnimationTimeline.groupDuration(.click(0), in: steps) == 0)
    #expect(AnimationTimeline.groupCompleted(.click(0), in: steps, context: nil, now: 0), "empty group = complete")
    let notDismissed = AnimationContext(anchorHostTime: 0)
    #expect(!AnimationTimeline.groupCompleted(.exit, in: steps, context: notDismissed, now: 100))
    let dismissed = AnimationContext(anchorHostTime: 0, dismissHostTime: 50)
    #expect(!AnimationTimeline.groupCompleted(.exit, in: steps, context: dismissed, now: 51.2))
    #expect(AnimationTimeline.groupCompleted(.exit, in: steps, context: dismissed, now: 51.5))
}
