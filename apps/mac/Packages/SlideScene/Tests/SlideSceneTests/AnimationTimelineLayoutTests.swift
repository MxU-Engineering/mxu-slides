import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func step(
    _ id: String, _ trigger: AnimationTrigger, _ kind: AnimationKind = .in,
    animation: StepAnimation = .fade, delay: Double? = nil, duration: Double = 1,
    ranges: [AnimationRange]? = nil, ramp: AnimationRamp? = nil
) -> AnimationStep {
    AnimationStep(
        id: id, kind: kind, animation: animation, trigger: trigger,
        delaySeconds: delay, durationSeconds: duration, ramp: ramp, ranges: ranges
    )
}

private func seededObjects() -> [SlideObject] {
    [
        SlideObject(
            id: "title", objectKind: .text, name: "Title", text: "Faith That Moves",
            animationSteps: [
                step("t-in", .withPrevious, .in, animation: .wipe, duration: 0.6),
                step("t-morph", .onClick, .morph, duration: 0.8),
                step("t-out", .onDismiss, .out, duration: 0.4),
            ]
        ),
        SlideObject(
            id: "rule", objectKind: .shape, name: "Accent Rule", text: "",
            animationSteps: [
                step("r-in", .afterPrevious, .in, animation: .draw, delay: 0.1, duration: 0.8),
            ]
        ),
        SlideObject(
            id: "p1", objectKind: .text, name: "Point 1", text: "one two three",
            animationSteps: [
                step("p1-in", .onClick, .in, animation: .move, duration: 0.5,
                     ranges: [AnimationRange(line: 0, column: 0, length: 3)]),
                step("p1-out", .onDismiss, .out, duration: 0.4),
            ]
        ),
        SlideObject(id: "plain", objectKind: .text, name: "No steps", text: "hi"),
        SlideObject(
            id: "ghosted", objectKind: .text, name: "Hidden", text: "x",
            hidden: true,
            animationSteps: [step("h-in", .onClick)]
        ),
    ]
}

@Test func timelineIsTheSentenceListDrawnAsGeometry() {
    let objects = seededObjects()
    let timeline = AnimationTimelineLayout.timeline(objects: objects, order: nil)

    let groups = AnimationSequence.groups(objects: objects, order: nil)
    #expect(timeline.columns.map(\.group) ==
            [.auto] + groups.click.indices.map { .click($0) } + [.exit])

    let preview = AnimationSequence.previewTimeline(objects: objects, order: nil)
    #expect(timeline.clickTimes == preview.clicks)
    #expect(timeline.dismissAt == preview.dismissAt)
    #expect(timeline.duration == preview.duration)
    for (index, click) in preview.clicks.enumerated() {
        #expect(timeline.columns[index + 1].start == click)
    }
    #expect(timeline.columns.last?.start == preview.dismissAt)

    #expect(timeline.rows.map(\.objectID) == ["title", "rule", "p1", "plain"])

    let blockIDs = Set(timeline.rows.flatMap(\.blocks).map(\.stepID))
    let entryIDs = Set(AnimationSequence.orderedEntries(objects: objects, order: nil).map(\.step.id))
    #expect(blockIDs == entryIDs)

    let scheduled = AnimationSequence.sceneSteps(objects: objects, order: nil)
    for row in timeline.rows {
        for block in row.blocks {
            let scene = scheduled[row.objectID]?.first { $0.id == block.stepID }
            #expect(scene?.group == block.group, "\(block.stepID)")
            #expect(scene?.startOffset == block.startOffset, "\(block.stepID)")
            #expect(scene?.duration == block.duration, "\(block.stepID)")
        }
    }

    #expect(timeline.rows[1].blocks[0].linked)
    #expect(timeline.rows[2].blocks[0].ranged)
    #expect(!timeline.rows[0].blocks[0].linked)
}

@Test func presenceBarsFollowTheDefaultVerbTargets() {
    let objects = seededObjects()
    let timeline = AnimationTimelineLayout.timeline(objects: objects, order: nil)
    let preview = AnimationSequence.previewTimeline(objects: objects, order: nil)

    let title = timeline.rows[0]
    #expect(title.presenceStart == 0)
    #expect(title.presenceEnd == preview.dismissAt + 0.4)

    let p1 = timeline.rows[2]
    #expect(p1.presenceStart == nil, "a ranged In never hides the object")
    #expect(p1.presenceEnd == preview.dismissAt + 0.4)

    let plain = timeline.rows[3]
    #expect(plain.presenceStart == nil && plain.presenceEnd == nil)

    #expect(title.blocks[0].rampOut && !title.blocks[0].rampIn)

    #expect(title.blocks[1].rampIn && title.blocks[1].rampOut)

    #expect(timeline.columns.allSatisfy {
        $0.duration > 0
            ? $0.displayDuration == $0.duration
            : $0.displayDuration >= AnimationTimelineLayout.minimumColumnSeconds
    })
}

@Test func morphLabelIsBehaviorDriven() {
    var object = SlideObject(id: "o", objectKind: .text, name: "T", text: "hi", x: 10, y: 10, width: 100, height: 50)
    var mover = step("m", .onClick, .morph)
    var end = object
    end.y = 200
    mover.toObject = end
    #expect(AnimationTimelineLayout.morphMoves(mover, object: object), "a moved end state reads Morph")

    var styler = step("s", .onClick, .morph)
    var recolored = object
    recolored.fill = ObjectFill(fillKind: .solid, colorHex: "#FF0000FF")
    styler.toObject = recolored
    #expect(!AnimationTimelineLayout.morphMoves(styler, object: object), "a style-only end state reads Change")

    var tilter = step("t", .onClick, .morph)
    var tilted = object
    tilted.tilt = 30
    tilter.toObject = tilted
    #expect(AnimationTimelineLayout.morphMoves(tilter, object: object))

    #expect(!AnimationTimelineLayout.morphMoves(step("x", .onClick, .morph), object: object))
    object.animationSteps = nil
    #expect(!AnimationTimelineLayout.morphMoves(step("y", .onClick, .in), object: object))
}

@Test func placementIsTheMinimalTriggerDelayDelta() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("head", .onClick, duration: 1),
                step("follow", .afterPrevious, delay: 0.1, duration: 0.5),
            ]
        ),
    ]

    let head = AnimationSequence.placement(of: "head", targetOffset: 0.75, objects: objects, order: nil)
    #expect(head?.trigger == .onClick)
    #expect(head?.delaySeconds == 0.75)

    let zero = AnimationSequence.placement(of: "head", targetOffset: 0, objects: objects, order: nil)
    #expect(zero?.trigger == .onClick && zero?.delaySeconds == nil)

    let follow = AnimationSequence.placement(of: "follow", targetOffset: 0.4, objects: objects, order: nil)
    #expect(follow?.trigger == .withPrevious)
    #expect(follow?.delaySeconds == 0.4)

    var moved = objects
    moved[0].animationSteps?[0].delaySeconds = 0.75
    let overlap = AnimationSequence.placement(of: "follow", targetOffset: 0.5, objects: moved, order: nil)
    #expect(overlap?.trigger == .withPrevious)
    #expect(overlap?.delaySeconds == -0.25)
}

@Test func linkToggleNeverMovesTheBlock() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("head", .onClick, duration: 1),
                step("follow", .afterPrevious, delay: 0.2, duration: 0.5),
            ]
        ),
    ]
    let before = AnimationSequence.schedule(objects: objects, order: nil)

    let unlink = AnimationSequence.linkToggle(of: "follow", objects: objects, order: nil)
    #expect(unlink?.trigger == .withPrevious)
    #expect(unlink?.delaySeconds == 1.2)
    var unlinked = objects
    unlinked[0].animationSteps?[1].trigger = unlink!.trigger
    unlinked[0].animationSteps?[1].delaySeconds = unlink!.delaySeconds
    let after = AnimationSequence.schedule(objects: unlinked, order: nil)
    #expect(after["follow"]?.start == before["follow"]?.start, "the block never visually moves")

    let relink = AnimationSequence.linkToggle(of: "follow", objects: unlinked, order: nil)
    #expect(relink?.trigger == .afterPrevious)
    #expect(relink?.delaySeconds.map { abs($0 - 0.2) < 1e-9 } == true)

    #expect(AnimationSequence.linkToggle(of: "head", objects: objects, order: nil) == nil)
}

@Test func movingOneCardNeverShovesTheRest() {

    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("head", .onClick, duration: 1),
                step("follow", .afterPrevious, delay: 0.1, duration: 0.5),
                step("tail", .withPrevious, delay: 2, duration: 0.3),
            ]
        ),
    ]
    let before = AnimationSequence.schedule(objects: objects, order: nil)
    #expect(before["follow"]?.start == 1.1)

    var moved = objects
    let head = AnimationSequence.placement(of: "head", targetOffset: 0.75, objects: objects, order: nil)!
    moved[0].animationSteps?[0].trigger = head.trigger
    moved[0].animationSteps?[0].delaySeconds = head.delaySeconds
    let pins = AnimationSequence.pins(objects: moved, order: nil, toPrevious: before, excluding: ["head"])
    for pin in pins {
        let index = moved[0].animationSteps!.firstIndex { $0.id == pin.stepID }!
        moved[0].animationSteps?[index].trigger = pin.trigger
        moved[0].animationSteps?[index].delaySeconds = pin.delaySeconds
    }
    let after = AnimationSequence.schedule(objects: moved, order: nil)
    #expect(after["head"]?.start == 0.75)
    #expect(after["follow"]?.start == before["follow"]?.start, "the chained follower stays put")
    #expect(after["tail"]?.start == before["tail"]?.start)

    #expect(moved[0].animationSteps?[1].trigger == .afterPrevious)
    #expect(moved[0].animationSteps?[2].trigger == .withPrevious)
}

@Test func groupMoveStaysRigidAcrossUnselectedAnchors() {

    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("head", .onClick, delay: 0.35, duration: 0.3),
                step("b", .withPrevious, delay: -0.2, duration: 0.3),
                step("c", .afterPrevious, delay: -0.2, duration: 0.35),
                step("d", .withPrevious, delay: -0.05, duration: 0.3),
            ]
        ),
    ]
    let before = AnimationSequence.schedule(objects: objects, order: nil)
    let selected: Set<String> = ["head", "b", "d"]
    let delta = 0.3

    var targets: [String: Double] = [:]
    for (id, value) in before {
        targets[id] = selected.contains(id) ? value.start + delta : value.start
    }
    var moved = objects
    for pin in AnimationSequence.pins(objects: moved, order: nil, targets: targets) {
        let index = moved[0].animationSteps!.firstIndex { $0.id == pin.stepID }!
        moved[0].animationSteps?[index].trigger = pin.trigger
        moved[0].animationSteps?[index].delaySeconds = pin.delaySeconds
    }
    let after = AnimationSequence.schedule(objects: moved, order: nil)
    for id in selected {
        let shift = after[id]!.start - before[id]!.start
        #expect(abs(shift - delta) < 1e-9, "\(id) shifts by exactly the drag delta")
    }
    #expect(abs(after["c"]!.start - before["c"]!.start) < 1e-9, "the unselected step plants")

    #expect(moved[0].animationSteps?.map(\.trigger) == [.onClick, .withPrevious, .afterPrevious, .withPrevious])
}

@Test func rehomedClickLandsAfterTheTargetsContentAndDisappears() {

    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("a1", .withPrevious, duration: 0.45),
                step("a2", .withPrevious, delay: 0.4, duration: 0.4),
                step("head", .onClick, delay: 0.35, duration: 0.3),
                step("follow", .withPrevious, delay: -0.2, duration: 0.3),
            ]
        ),
    ]
    let move = AnimationSequence.rehomeGroup(
        from: .click(0), to: .auto, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    moved[0].animationSteps = {
        var steps = moved[0].animationSteps!
        for delta in move!.deltas {
            let index = steps.firstIndex { $0.id == delta.stepID }!
            steps[index].trigger = delta.trigger
            steps[index].delaySeconds = delta.delaySeconds
        }
        return steps
    }()
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.isEmpty, "the vacated click disappears")
    #expect(groups.auto.map(\.step.id) == ["a1", "a2", "head", "follow"])
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)

    #expect(abs(after["head"]!.start - 0.8) < 1e-9)
    #expect(abs(after["follow"]!.start - 0.6) < 1e-9)
    #expect(moved[0].animationSteps?.first { $0.id == "head" }?.trigger == .withPrevious)
    #expect(moved[0].animationSteps?.first { $0.id == "follow" }?.trigger == .withPrevious)
}

@Test func rehomedClickBecomesTheExitGroup() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("head", .onClick, delay: 0.35, duration: 0.3),
                step("follow", .withPrevious, delay: 0.15, duration: 0.3),
            ]
        ),
    ]
    let move = AnimationSequence.rehomeGroup(
        from: .click(0), to: .exit, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    for delta in move!.deltas {
        let index = moved[0].animationSteps!.firstIndex { $0.id == delta.stepID }!
        moved[0].animationSteps?[index].trigger = delta.trigger
        moved[0].animationSteps?[index].delaySeconds = delta.delaySeconds
    }
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.isEmpty)
    #expect(groups.exit.map(\.step.id) == ["head", "follow"])

    #expect(moved[0].animationSteps?.first { $0.id == "head" }?.trigger == .onDismiss)
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)
    #expect(abs(after["follow"]!.start - 0.15) < 1e-9, "internal timing survives")
}

@Test func rehomeRefusesEmptyOrSameColumn() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [step("head", .onClick, duration: 0.3)]
        ),
    ]
    #expect(AnimationSequence.rehomeGroup(from: .click(0), to: .click(0), objects: objects, order: nil) == nil)
    #expect(AnimationSequence.rehomeGroup(from: .auto, to: .exit, objects: objects, order: nil) == nil)
    #expect(AnimationSequence.rehomeGroup(from: .click(3), to: .auto, objects: objects, order: nil) == nil)
}

@Test func setMovesToAnotherClickKeepingItsSpacing() {

    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("h1", .onClick, delay: 0.3, duration: 0.3),
                step("f1", .withPrevious, delay: 0.1, duration: 0.3),
                step("g1", .withPrevious, delay: 0.1, duration: 0.3),
                step("h2", .onClick, delay: 0.2, duration: 0.3),
            ]
        ),
    ]
    let move = AnimationSequence.rehomeSteps(
        ["f1", "g1"], to: .click(1), firstOffset: 0.5, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    for delta in move!.deltas {
        let index = moved[0].animationSteps!.firstIndex { $0.id == delta.stepID }!
        moved[0].animationSteps?[index].trigger = delta.trigger
        moved[0].animationSteps?[index].delaySeconds = delta.delaySeconds
    }
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.count == 2)
    #expect(groups.click[0].map(\.step.id) == ["h1"])
    #expect(groups.click[1].map(\.step.id) == ["h2", "f1", "g1"])
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)
    #expect(abs(after["f1"]!.start - 0.5) < 1e-9, "the packet's first lands at the drop")
    #expect(abs(after["g1"]!.start - 0.6) < 1e-9, "internal spacing survives")
    #expect(abs(after["h1"]!.start - 0.3) < 1e-9, "the vacated column stays planted")
    #expect(abs(after["h2"]!.start - 0.2) < 1e-9)
}

@Test func setPastTheEdgeBecomesANewFinalClick() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("h1", .onClick, delay: 0.35, duration: 0.3),
                step("f1", .withPrevious, delay: 0.15, duration: 0.3),
                step("h2", .onClick, duration: 0.3),
            ]
        ),
    ]

    let move = AnimationSequence.rehomeSteps(
        ["h1", "f1"], to: .click(2), firstOffset: 0, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    for delta in move!.deltas {
        let index = moved[0].animationSteps!.firstIndex { $0.id == delta.stepID }!
        moved[0].animationSteps?[index].trigger = delta.trigger
        moved[0].animationSteps?[index].delaySeconds = delta.delaySeconds
    }
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.count == 2, "the vacated click disappears; the packet is the new final click")
    #expect(groups.click[0].map(\.step.id) == ["h2"])
    #expect(groups.click[1].map(\.step.id) == ["h1", "f1"])
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)
    #expect(abs(after["h1"]!.start - 0) < 1e-9)
    #expect(abs(after["f1"]!.start - 0.15) < 1e-9, "internal spacing survives")
    #expect(moved[0].animationSteps?.first { $0.id == "h1" }?.trigger == .onClick)
}

@Test func displacedHeadDemotesWhenTheSetLandsFirst() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("x", .withPrevious, duration: 0.3),
                step("h1", .onClick, delay: 0.5, duration: 0.3),
            ]
        ),
    ]
    let move = AnimationSequence.rehomeSteps(
        ["x"], to: .click(0), firstOffset: 0, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    for delta in move!.deltas {
        let index = moved[0].animationSteps!.firstIndex { $0.id == delta.stepID }!
        moved[0].animationSteps?[index].trigger = delta.trigger
        moved[0].animationSteps?[index].delaySeconds = delta.delaySeconds
    }
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.count == 1, "landing first hands the group trigger over, never splits the click")
    #expect(groups.click[0].map(\.step.id) == ["x", "h1"])
    #expect(moved[0].animationSteps?.first { $0.id == "x" }?.trigger == .onClick)
    #expect(moved[0].animationSteps?.first { $0.id == "h1" }?.trigger == .withPrevious)
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)
    #expect(abs(after["x"]!.start - 0) < 1e-9)
    #expect(abs(after["h1"]!.start - 0.5) < 1e-9, "the displaced head keeps its spot")
}

@Test func setLeavingItsHeadPromotesTheSurvivors() {

    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("h", .onClick, delay: 0.3, duration: 0.3),
                step("f", .withPrevious, delay: 0.1, duration: 0.3),
                step("g", .withPrevious, delay: 0.1, duration: 0.3),
            ]
        ),
    ]
    let move = AnimationSequence.rehomeSteps(
        ["h", "f"], to: .exit, firstOffset: 0.2, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    for delta in move!.deltas {
        let index = moved[0].animationSteps!.firstIndex { $0.id == delta.stepID }!
        moved[0].animationSteps?[index].trigger = delta.trigger
        moved[0].animationSteps?[index].delaySeconds = delta.delaySeconds
    }
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.count == 1, "the survivor keeps the click alive")
    #expect(groups.click[0].map(\.step.id) == ["g"])
    #expect(groups.exit.map(\.step.id) == ["h", "f"])
    #expect(moved[0].animationSteps?.first { $0.id == "g" }?.trigger == .onClick)
    #expect(moved[0].animationSteps?.first { $0.id == "h" }?.trigger == .onDismiss)
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)
    #expect(abs(after["g"]!.start - 0.5) < 1e-9, "the survivor keeps its spot")
    #expect(abs(after["h"]!.start - 0.2) < 1e-9)
    #expect(abs(after["f"]!.start - 0.3) < 1e-9, "packet spacing survives")
}

@Test func setDroppedOnADividerBirthsAClickBetween() {

    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("h1", .onClick, delay: 0.3, duration: 0.3),
                step("f1", .withPrevious, delay: 0.1, duration: 0.3),
                step("h2", .onClick, delay: 0.2, duration: 0.3),
            ]
        ),
    ]
    let move = AnimationSequence.rehomeSteps(
        ["f1"], to: .newClick(1), firstOffset: 0, objects: objects, order: nil
    )
    #expect(move != nil)
    var moved = objects
    for delta in move!.deltas {
        let index = moved[0].animationSteps!.firstIndex { $0.id == delta.stepID }!
        moved[0].animationSteps?[index].trigger = delta.trigger
        moved[0].animationSteps?[index].delaySeconds = delta.delaySeconds
    }
    let groups = AnimationSequence.groups(objects: moved, order: move!.order)
    #expect(groups.click.count == 3, "a brand-new click lands between the neighbors")
    #expect(groups.click[0].map(\.step.id) == ["h1"])
    #expect(groups.click[1].map(\.step.id) == ["f1"])
    #expect(groups.click[2].map(\.step.id) == ["h2"])
    #expect(moved[0].animationSteps?.first { $0.id == "f1" }?.trigger == .onClick)
    let after = AnimationSequence.schedule(objects: moved, order: move!.order)
    #expect(abs(after["f1"]!.start - 0) < 1e-9, "the new click's head starts at its instant")
    #expect(abs(after["h1"]!.start - 0.3) < 1e-9, "the neighbors keep their spots")
    #expect(abs(after["h2"]!.start - 0.2) < 1e-9)
}

@Test func pinPreservesTheTriggerItRexpresses() {
    let objects = [
        SlideObject(
            id: "a", objectKind: .text, name: "A", text: "hi",
            animationSteps: [
                step("head", .onClick, duration: 1),
                step("after", .afterPrevious, duration: 0.5),
            ]
        ),
    ]

    let pinned = AnimationSequence.pin(of: "after", targetOffset: 1.4, objects: objects, order: nil)
    #expect(pinned?.trigger == .afterPrevious)
    #expect(pinned?.delaySeconds.map { abs($0 - 0.4) < 1e-9 } == true)

    let headPin = AnimationSequence.pin(of: "head", targetOffset: -0.5, objects: objects, order: nil)
    #expect(headPin?.trigger == .onClick)
    #expect(headPin?.delaySeconds == nil, "clamped to 0 = the absent default")
}
