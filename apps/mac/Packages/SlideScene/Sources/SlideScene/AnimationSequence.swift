import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public enum AnimationSequence {

    public struct Entry: Equatable, Sendable {
        public var objectID: String
        public var step: AnimationStep

        public init(objectID: String, step: AnimationStep) {
            self.objectID = objectID
            self.step = step
        }
    }

    public struct Groups: Equatable, Sendable {

        public var auto: [Entry] = []

        public var click: [[Entry]] = []

        public var exit: [Entry] = []

        public init(auto: [Entry] = [], click: [[Entry]] = [], exit: [Entry] = []) {
            self.auto = auto
            self.click = click
            self.exit = exit
        }
    }

    public static func orderedEntries(objects: [SlideObject], order: [String]?) -> [Entry] {
        var all: [Entry] = []
        for object in objects where object.hidden != true {

            for step in SlideObjectNormalization.animationSteps(of: object) ?? [] {
                all.append(Entry(objectID: object.id, step: step))
            }
        }
        guard let order, !order.isEmpty else { return all }
        var byID: [String: Entry] = [:]
        for entry in all { byID[entry.step.id] = entry }
        var listed: [Entry] = []
        var seen: Set<String> = []
        for id in order {
            guard let entry = byID[id], !seen.contains(id) else { continue }
            listed.append(entry)
            seen.insert(id)
        }
        return listed + all.filter { !seen.contains($0.step.id) }
    }

    public static func groups(objects: [SlideObject], order: [String]?) -> Groups {
        var groups = Groups()
        enum Current { case auto, click(Int), exit }
        var current = Current.auto
        for entry in orderedEntries(objects: objects, order: order) {
            switch entry.step.trigger {
            case .onClick:
                groups.click.append([entry])
                current = .click(groups.click.count - 1)
            case .onDismiss:
                groups.exit.append(entry)
                current = .exit
            case .withPrevious, .afterPrevious:
                switch current {
                case .auto: groups.auto.append(entry)
                case .click(let n): groups.click[n].append(entry)
                case .exit: groups.exit.append(entry)
                }
            }
        }
        return groups
    }

    public static func clickCount(objects: [SlideObject], order: [String]?) -> Int {
        groups(objects: objects, order: order).click.count
    }

    public static func hasExitGroup(objects: [SlideObject], order: [String]?) -> Bool {
        !groups(objects: objects, order: order).exit.isEmpty
    }

    public static func advanceCount(objects: [SlideObject], order: [String]?) -> Int {
        let groups = groups(objects: objects, order: order)
        return groups.click.count + (groups.exit.isEmpty ? 0 : 1)
    }

    public static func exitDuration(objects: [SlideObject], order: [String]?, consumedClicks: Int = 0) -> Double {
        let steps = sceneSteps(objects: objects, order: order).values.flatMap { $0 }
        var duration = AnimationTimeline.groupDuration(.exit, in: steps)
        for step in steps where step.kind == .exit {
            if case .click(let n) = step.group, n >= consumedClicks {
                duration = max(duration, step.startOffset + step.duration)
            }
        }
        return duration
    }

    public static let previewClickGap = 0.4
    public static let previewExitHold = 0.8

    public static func previewTimeline(objects: [SlideObject], order: [String]?) -> (clicks: [Double], dismissAt: Double, duration: Double) {
        let steps = sceneSteps(objects: objects, order: order).values.flatMap { $0 }
        let groups = groups(objects: objects, order: order)
        var cursor = AnimationTimeline.groupDuration(.auto, in: steps)
        var clicks: [Double] = []
        for index in groups.click.indices {
            let start = cursor + (cursor > 0 || index > 0 ? previewClickGap : 0)
            clicks.append(start)
            cursor = start + AnimationTimeline.groupDuration(.click(index), in: steps)
        }
        let dismissAt = cursor + previewExitHold
        let duration = dismissAt + AnimationTimeline.groupDuration(.exit, in: steps)
        return (clicks, dismissAt, duration)
    }

    public static func previewContext(
        objects: [SlideObject], order: [String]?, time: Double?, startedAt: Double = 0
    ) -> AnimationContext {
        let timeline = previewTimeline(objects: objects, order: order)
        return AnimationContext(
            anchorHostTime: startedAt,
            clickHostTimes: timeline.clicks.map { startedAt + $0 },
            dismissHostTime: startedAt + timeline.dismissAt,
            frozenHostTime: time.map { startedAt + $0 }
        )
    }

    public static func warnings(objects: [SlideObject], order: [String]?) -> [String: String] {
        var warnings: [String: String] = [:]

        var hasIn: Set<String> = []
        for entry in orderedEntries(objects: objects, order: order) where entry.step.kind == .in {
            hasIn.insert(key(entry))
        }
        var shown: [String: Bool] = [:]
        func isShown(_ entry: Entry) -> Bool {
            let k = key(entry)
            if let state = shown[k] { return state }
            return !hasIn.contains(k)
        }
        for entry in orderedEntries(objects: objects, order: order) {
            let k = key(entry)
            switch entry.step.kind {
            case .in:
                if isShown(entry) {
                    warnings[entry.step.id] = "Already shown — nothing left to bring in"
                }
                shown[k] = true
            case .out:
                if !isShown(entry) {
                    warnings[entry.step.id] = "Plays before it's been brought in"
                }
                shown[k] = false
            case .emphasis:
                if !isShown(entry) {
                    warnings[entry.step.id] = "Plays before it's been brought in"
                }
            case .morph:
                if !isShown(entry) {
                    warnings[entry.step.id] = "Plays before it's been brought in"
                } else if entry.step.toObject == nil {
                    warnings[entry.step.id] = "No end state yet"
                }
            }
        }
        return warnings
    }

    private static func key(_ entry: Entry) -> String {
        guard let ranges = entry.step.ranges, !ranges.isEmpty else { return entry.objectID }
        return entry.objectID + "#" + ranges.map { "\($0.line):\($0.column):\($0.length)" }.sorted().joined(separator: ",")
    }

    public static func promotion(afterRemoving id: String, objects: [SlideObject], order: [String]?) -> (stepID: String, trigger: AnimationTrigger)? {
        let entries = orderedEntries(objects: objects, order: order)
        guard let index = entries.firstIndex(where: { $0.step.id == id }) else { return nil }
        let leaving = entries[index].step
        guard leaving.trigger == .onClick || leaving.trigger == .onDismiss,
              entries.indices.contains(index + 1) else { return nil }
        let next = entries[index + 1].step
        guard next.trigger == .withPrevious || next.trigger == .afterPrevious else { return nil }
        return (next.id, leaving.trigger)
    }

    public struct GroupedMove: Equatable, Sendable {
        public var order: [String]
        public var triggers: [String: AnimationTrigger]
    }

    public enum GroupSlot: Equatable, Sendable {
        case auto
        case click(Int)
        case exit

        case newClick(Int)
    }

    public static func groupedMove(
        objects: [SlideObject], order: [String]?, moving id: String,
        into slot: GroupSlot, position: Int
    ) -> GroupedMove? {
        let groups = groups(objects: objects, order: order)
        guard let moving = orderedEntries(objects: objects, order: order).first(where: { $0.step.id == id }) else { return nil }

        var auto = groups.auto.filter { $0.step.id != id }
        var clicks = groups.click.map { $0.filter { $0.step.id != id } }
        var exit = groups.exit.filter { $0.step.id != id }
        var triggers: [String: AnimationTrigger] = [:]
        func insert(_ list: inout [Entry], firstTrigger: AnimationTrigger) {
            let index = min(max(position, 0), list.count)
            list.insert(moving, at: index)
            if index == 0 {
                triggers[id] = firstTrigger
                if list.count > 1, list[1].step.trigger == firstTrigger, firstTrigger != .withPrevious {
                    triggers[list[1].step.id] = .withPrevious
                }
            } else {
                triggers[id] = moving.step.trigger == .afterPrevious ? .afterPrevious : .withPrevious
            }
        }
        switch slot {
        case .auto:
            insert(&auto, firstTrigger: .withPrevious)
        case .click(let n):
            guard clicks.indices.contains(n) else { return nil }
            insert(&clicks[n], firstTrigger: .onClick)
        case .newClick(let n):
            clicks.insert([moving], at: min(max(n, 0), clicks.count))
            triggers[id] = .onClick
        case .exit:
            insert(&exit, firstTrigger: .onDismiss)
        }

        clicks = clicks.filter { !$0.isEmpty }
        let flat = auto + clicks.flatMap { $0 } + exit
        return GroupedMove(order: flat.map(\.step.id), triggers: triggers)
    }

    public static func rehomeGroup(
        from source: GroupSlot, to slot: GroupSlot,
        objects: [SlideObject], order: [String]?
    ) -> (order: [String], deltas: [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)])? {
        guard source != slot else { return nil }
        let groups = groups(objects: objects, order: order)
        let starts = schedule(objects: objects, order: order)
        func members(_ slot: GroupSlot) -> [Entry]? {
            switch slot {
            case .auto: groups.auto
            case .click(let n): groups.click.indices.contains(n) ? groups.click[n] : nil
            case .newClick: []
            case .exit: groups.exit
            }
        }
        guard let moving = members(source), !moving.isEmpty else { return nil }
        let movingIDs = Set(moving.map(\.step.id))
        let target = members(slot) ?? []

        var auto = groups.auto.filter { !movingIDs.contains($0.step.id) }
        var clicks = groups.click.map { $0.filter { !movingIDs.contains($0.step.id) } }
        var exit = groups.exit.filter { !movingIDs.contains($0.step.id) }
        switch slot {
        case .auto: auto += moving
        case .click(let n) where clicks.indices.contains(n): clicks[n] += moving
        case .click: clicks.append(moving)
        case .newClick(let n): clicks.insert(moving, at: min(max(n, 0), clicks.count))
        case .exit: exit += moving
        }
        clicks = clicks.filter { !$0.isEmpty }
        let flat = auto + clicks.flatMap { $0 } + exit

        var deltas: [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)] = []
        let head = moving[0]
        if let last = target.last {
            let targetEnd = target
                .map { (starts[$0.step.id]?.start ?? 0) + (starts[$0.step.id]?.duration ?? 0) }
                .max() ?? 0
            let delay = targetEnd - (starts[last.step.id]?.start ?? 0)
            deltas.append((head.step.id, .withPrevious, delay == 0 ? nil : delay))
        } else {
            let trigger: AnimationTrigger = switch slot {
            case .auto: .withPrevious
            case .click, .newClick: .onClick
            case .exit: .onDismiss
            }
            deltas.append((head.step.id, trigger, nil))
        }
        for (index, entry) in moving.enumerated() where index > 0 {
            guard entry.step.trigger == .onClick || entry.step.trigger == .onDismiss else { continue }
            let previous = moving[index - 1]
            let delay = (starts[entry.step.id]?.start ?? 0) - (starts[previous.step.id]?.start ?? 0)
            deltas.append((entry.step.id, .withPrevious, delay == 0 ? nil : delay))
        }
        return (flat.map(\.step.id), deltas)
    }

    public static func rehomeSteps(
        _ ids: Set<String>, to slot: GroupSlot, firstOffset: Double,
        objects: [SlideObject], order: [String]?
    ) -> (order: [String], deltas: [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)])? {
        let entries = orderedEntries(objects: objects, order: order)
        let moving = entries.filter { ids.contains($0.step.id) }
        guard !moving.isEmpty else { return nil }
        let movingIDs = Set(moving.map(\.step.id))
        let starts = schedule(objects: objects, order: order)

        let previews: [String: Double] = movingIDs.reduce(into: [:]) {
            $0[$1] = previewStart(ofStep: $1, objects: objects, order: order) ?? 0
        }
        let base = previews[moving[0].step.id] ?? 0
        let landed = max(firstOffset, 0)
        var targets: [String: Double] = [:]
        for entry in entries {
            let id = entry.step.id
            targets[id] = movingIDs.contains(id)
                ? landed + ((previews[id] ?? 0) - base)
                : starts[id]?.start ?? 0
        }

        let groups = groups(objects: objects, order: order)
        var auto = groups.auto.filter { !movingIDs.contains($0.step.id) }
        var clicks = groups.click.map { $0.filter { !movingIDs.contains($0.step.id) } }
        var exit = groups.exit.filter { !movingIDs.contains($0.step.id) }
        func insert(_ list: inout [Entry], headTrigger: AnimationTrigger) -> [String: AnimationTrigger] {
            let position = list.filter { (starts[$0.step.id]?.start ?? 0) < landed }.count
            var conversions: [String: AnimationTrigger] = [:]
            if position == 0 {
                conversions[moving[0].step.id] = headTrigger

                if let old = list.first, old.step.trigger == headTrigger, headTrigger != .withPrevious {
                    conversions[old.step.id] = .withPrevious
                }
            } else {
                conversions[moving[0].step.id] = .withPrevious
            }
            list.insert(contentsOf: moving, at: position)
            return conversions
        }
        var conversions: [String: AnimationTrigger]
        switch slot {
        case .auto:
            conversions = insert(&auto, headTrigger: .withPrevious)
        case .click(let n) where clicks.indices.contains(n):
            conversions = insert(&clicks[n], headTrigger: .onClick)
        case .click:
            clicks.append(moving)
            conversions = [moving[0].step.id: .onClick]
        case .newClick(let n):
            clicks.insert(moving, at: min(max(n, 0), clicks.count))
            conversions = [moving[0].step.id: .onClick]
        case .exit:
            conversions = insert(&exit, headTrigger: .onDismiss)
        }

        for entry in moving.dropFirst()
        where entry.step.trigger == .onClick || entry.step.trigger == .onDismiss {
            conversions[entry.step.id] = .withPrevious
        }

        for list in clicks {
            guard let first = list.first else { continue }
            let effective = conversions[first.step.id] ?? first.step.trigger
            if effective != .onClick { conversions[first.step.id] = .onClick }
        }
        if let first = exit.first {
            let effective = conversions[first.step.id] ?? first.step.trigger
            if effective != .onDismiss { conversions[first.step.id] = .onDismiss }
        }
        clicks = clicks.filter { !$0.isEmpty }
        let flat = (auto + clicks.flatMap { $0 } + exit).map(\.step.id)

        var working = objects
        for index in working.indices {
            guard var steps = working[index].animationSteps else { continue }
            for s in steps.indices {
                if let trigger = conversions[steps[s].id] { steps[s].trigger = trigger }
            }
            working[index].animationSteps = steps
        }
        let forced = movingIDs.union(conversions.keys)
        var deltas: [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)] = []
        for entry in orderedEntries(objects: working, order: flat) {
            let id = entry.step.id
            guard let target = targets[id] else { continue }
            let current = schedule(objects: working, order: flat)[id]?.start
            guard let current, forced.contains(id) || abs(current - target) > 0.0001 else { continue }
            guard let delta = pin(of: id, targetOffset: target, objects: working, order: flat)
            else { continue }
            deltas.append((id, delta.trigger, delta.delaySeconds))
            for index in working.indices {
                guard var steps = working[index].animationSteps,
                      let s = steps.firstIndex(where: { $0.id == id }) else { continue }
                steps[s].trigger = delta.trigger
                steps[s].delaySeconds = delta.delaySeconds
                working[index].animationSteps = steps
            }
        }
        return (flat, deltas)
    }

    public static func previewStart(ofStep id: String, objects: [SlideObject], order: [String]?) -> Double? {
        let timeline = previewTimeline(objects: objects, order: order)
        for (_, steps) in sceneSteps(objects: objects, order: order) {
            guard let step = steps.first(where: { $0.id == id }) else { continue }
            switch step.group {
            case .auto: return step.startOffset
            case .click(let n): return timeline.clicks.indices.contains(n) ? timeline.clicks[n] + step.startOffset : nil
            case .exit: return timeline.dismissAt + step.startOffset
            }
        }
        return nil
    }

    public static func upcomingRevealText(objects: [SlideObject], order: [String]?, consumed: Int) -> String? {
        let groups = groups(objects: objects, order: order)
        guard consumed >= 0, consumed < groups.click.count else { return nil }
        let lines = groups.click[consumed].compactMap { entry -> String? in
            guard entry.step.kind == .in || entry.step.kind == .morph,
                  let object = objects.first(where: { $0.id == entry.objectID }) else { return nil }
            if let ranges = entry.step.ranges, !ranges.isEmpty {
                let text = ranges.map { AnimationRanges.text(of: $0, in: object.text) }.joined(separator: " ")
                return text.isEmpty ? nil : text
            }
            return object.text.isEmpty ? object.name : object.text
        }
        let body = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return body.isEmpty ? nil : body
    }

    public static func hasAnimationSteps(_ objects: [SlideObject]) -> Bool {
        objects.contains {
            $0.hidden != true && !(SlideObjectNormalization.animationSteps(of: $0) ?? []).isEmpty
        }
    }

    public static func schedule(
        objects: [SlideObject], order: [String]?
    ) -> [String: (start: Double, duration: Double)] {
        var result: [String: (start: Double, duration: Double)] = [:]
        for step in sceneSteps(objects: objects, order: order).values.flatMap({ $0 }) {
            result[step.id] = (step.startOffset, step.duration)
        }
        return result
    }

    public static func placement(
        of id: String, targetOffset: Double, objects: [SlideObject], order: [String]?
    ) -> (trigger: AnimationTrigger, delaySeconds: Double?)? {
        let groups = groups(objects: objects, order: order)
        let starts = schedule(objects: objects, order: order)
        func within(_ entries: [Entry], head: AnimationTrigger) -> (trigger: AnimationTrigger, delaySeconds: Double?)? {
            guard let index = entries.firstIndex(where: { $0.step.id == id }) else { return nil }
            if index == 0 {
                let delay = max(targetOffset, 0)
                return (head, delay == 0 ? nil : delay)
            }
            let previousStart = starts[entries[index - 1].step.id]?.start ?? 0
            let delay = targetOffset - previousStart
            return (.withPrevious, delay == 0 ? nil : delay)
        }
        if let result = within(groups.auto, head: .withPrevious) { return result }
        for entries in groups.click {
            if let result = within(entries, head: .onClick) { return result }
        }
        return within(groups.exit, head: .onDismiss)
    }

    public static func pin(
        of id: String, targetOffset: Double, objects: [SlideObject], order: [String]?
    ) -> (trigger: AnimationTrigger, delaySeconds: Double?)? {
        let groups = groups(objects: objects, order: order)
        let starts = schedule(objects: objects, order: order)
        func within(_ entries: [Entry]) -> (trigger: AnimationTrigger, delaySeconds: Double?)? {
            guard let index = entries.firstIndex(where: { $0.step.id == id }) else { return nil }
            let entry = entries[index]
            let delay: Double
            switch entry.step.trigger {
            case .withPrevious where index > 0:
                delay = targetOffset - (starts[entries[index - 1].step.id]?.start ?? 0)
            case .afterPrevious where index > 0:
                let previous = starts[entries[index - 1].step.id] ?? (0, 0)
                delay = targetOffset - (previous.start + previous.duration)
            default:

                delay = max(targetOffset, 0)
            }
            return (entry.step.trigger, delay == 0 ? nil : delay)
        }
        if let result = within(groups.auto) { return result }
        for entries in groups.click {
            if let result = within(entries) { return result }
        }
        return within(groups.exit)
    }

    public static func pins(
        objects: [SlideObject], order: [String]?,
        toPrevious old: [String: (start: Double, duration: Double)],
        excluding: Set<String>
    ) -> [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)] {
        var targets: [String: Double] = [:]
        for (id, value) in old where !excluding.contains(id) {
            targets[id] = value.start
        }
        return pins(objects: objects, order: order, targets: targets)
    }

    public static func pins(
        objects: [SlideObject], order: [String]?,
        targets: [String: Double]
    ) -> [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)] {
        var working = objects
        var result: [(stepID: String, trigger: AnimationTrigger, delaySeconds: Double?)] = []
        for entry in orderedEntries(objects: working, order: order) {
            let id = entry.step.id
            guard let target = targets[id] else { continue }
            let current = schedule(objects: working, order: order)[id]?.start

            guard let current, abs(current - target) > 0.0001 else { continue }
            guard let delta = pin(of: id, targetOffset: target, objects: working, order: order)
            else { continue }
            result.append((id, delta.trigger, delta.delaySeconds))
            for index in working.indices {
                guard var steps = working[index].animationSteps,
                      let s = steps.firstIndex(where: { $0.id == id }) else { continue }
                steps[s].trigger = delta.trigger
                steps[s].delaySeconds = delta.delaySeconds
                working[index].animationSteps = steps
            }
        }
        return result
    }

    public static func linkToggle(
        of id: String, objects: [SlideObject], order: [String]?
    ) -> (trigger: AnimationTrigger, delaySeconds: Double?)? {
        let groups = groups(objects: objects, order: order)
        let starts = schedule(objects: objects, order: order)
        func within(_ entries: [Entry]) -> (trigger: AnimationTrigger, delaySeconds: Double?)? {
            guard let index = entries.firstIndex(where: { $0.step.id == id }), index > 0,
                  let current = starts[id]?.start,
                  let previous = starts[entries[index - 1].step.id]
            else { return nil }
            let entry = entries[index]
            if entry.step.trigger == .afterPrevious {
                let delay = current - previous.start
                return (.withPrevious, delay == 0 ? nil : delay)
            }
            let delay = current - (previous.start + previous.duration)
            return (.afterPrevious, delay == 0 ? nil : delay)
        }
        if let result = within(groups.auto) { return result }
        for entries in groups.click {
            if let result = within(entries) { return result }
        }
        return within(groups.exit)
    }

    public static func sceneSteps(objects: [SlideObject], order: [String]?) -> [String: [SceneAnimationStep]] {
        let groups = groups(objects: objects, order: order)
        var result: [String: [SceneAnimationStep]] = [:]
        func schedule(_ entries: [Entry], group: SceneAnimationGroup) {
            var previous: (start: Double, end: Double)?
            for entry in entries {

                let delay = entry.step.delaySeconds ?? 0
                let start: Double
                switch entry.step.trigger {
                case .withPrevious: start = max((previous?.start ?? 0) + delay, 0)
                case .afterPrevious: start = max((previous?.end ?? 0) + delay, 0)
                case .onClick, .onDismiss: start = max(delay, 0)
                }
                let duration = max(entry.step.durationSeconds, 0)
                previous = (start, start + duration)
                result[entry.objectID, default: []].append(
                    sceneStep(entry.step, group: group, startOffset: start)
                )
            }
        }
        schedule(groups.auto, group: .auto)
        for (index, entries) in groups.click.enumerated() {
            schedule(entries, group: .click(index))
        }
        schedule(groups.exit, group: .exit)
        return result
    }

    public static func sceneStep(_ step: AnimationStep, group: SceneAnimationGroup, startOffset: Double) -> SceneAnimationStep {
        let kind: SceneAnimationKind = switch step.kind {
        case .in: .enter
        case .out: .exit
        case .emphasis: .emphasis
        case .morph: .morph
        }
        let ramp: SceneAnimationRamp = switch step.ramp {
        case .none?: .none
        case .in?: .easeIn
        case .out?: .easeOut
        case .both?: .easeInOut
        case nil:
            switch kind {
            case .enter: .easeOut
            case .exit: .easeIn
            case .emphasis, .morph: .easeInOut
            }
        }
        let animation: SceneStepAnimation = switch step.animation {
        case .fade: .fade
        case .move: .move
        case .scale: .scale
        case .wipe: .wipe
        case .blur: .blur
        case .burn: .burn
        case .glitch: .glitch
        case .draw: .draw
        case .type: .type
        case .pulse: .pulse
        case .color: .color
        }
        let edge: SceneAnimationEdge? = switch step.edge {
        case .left?: .left
        case .right?: .right
        case .top?: .top
        case .bottom?: .bottom
        case nil: nil
        }
        let ranges = step.ranges?.map { SceneAnimationRange(line: $0.line, column: $0.column, length: $0.length) }
        let defaultAmount: Double = switch animation {
        case .blur: 24
        case .pulse: 1.1
        default: 0.6
        }
        return SceneAnimationStep(
            id: step.id,
            kind: kind,
            animation: animation,
            group: group,
            startOffset: startOffset,
            duration: step.durationSeconds,
            ramp: ramp,
            withFade: step.withFade ?? false,
            ranges: (ranges?.isEmpty ?? true) ? nil : ranges,
            edge: edge,
            offset: CGVector(dx: step.offsetX ?? 0, dy: step.offsetY ?? 0),
            fromScale: step.fromScale ?? 0.95,
            amount: step.amount ?? defaultAmount,
            softEdge: step.softEdge ?? 0,
            cursor: step.cursor ?? true,

            color: step.colorHex.flatMap(ColorHex.color)
                ?? (animation == .color ? ColorHex.color("#FFD54FFF") : nil),
            placeholderUnderline: step.placeholderUnderline ?? false,
            drawStart: step.drawStart ?? 0,
            reverse: step.reverse ?? false,
            videoPush: step.videoPush.map(sceneVideoPush)
        )
    }

    static func sceneVideoPush(_ push: VideoPush) -> SceneVideoPush {
        let alignment: SceneVideoPush.Alignment = switch push.alignment ?? .center {
        case .center: .center
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
        let mode: SceneVideoPush.Mode = switch push.mode ?? .fill {
        case .fill: .fill
        case .fit: .fit
        case .blurBackground: .blurBackground
        }
        return SceneVideoPush(
            alignment: alignment, mode: mode,
            zoom: max(push.zoom ?? 1, 0.05), margin: max(push.margin ?? 0, 0),
            backdrop: push.backdrop ?? false, blurRadius: max(push.blurRadius ?? 36, 0)
        )
    }
}
