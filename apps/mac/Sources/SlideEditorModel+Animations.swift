import Foundation
import PresenterCore
import QuartzCore
import RenderEngine
import SlideScene

extension SlideEditorModel {

    var stepEntries: [AnimationSequence.Entry] {
        guard let slide = currentSlide else { return [] }
        return AnimationSequence.orderedEntries(objects: slide.objects, order: slide.animationOrder)
    }

    var stepGroups: AnimationSequence.Groups {
        guard let slide = currentSlide else { return AnimationSequence.Groups() }
        return AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
    }

    var stepWarnings: [String: String] {
        guard let slide = currentSlide else { return [:] }
        return AnimationSequence.warnings(objects: slide.objects, order: slide.animationOrder)
    }

    var timelineLayout: AnimationTimelineLayout.Timeline {
        guard let slide = currentSlide else {
            return AnimationTimelineLayout.Timeline(
                columns: [], rows: [], clickTimes: [], dismissAt: 0, duration: 0
            )
        }
        return AnimationTimelineLayout.timeline(objects: slide.objects, order: slide.animationOrder)
    }

    var compositionHasAnimationSteps: Bool {
        currentSlide.map { AnimationSequence.hasAnimationSteps($0.objects) } ?? false
    }

    func animationStep(id: String) -> (objectID: String, step: AnimationStep)? {
        stepEntries.first { $0.step.id == id }.map { ($0.objectID, $0.step) }
    }

    func stepTargetLabel(_ entry: AnimationSequence.Entry) -> String {
        guard let object = object(id: entry.objectID) else { return "—" }
        let name = object.name.isEmpty ? object.objectKind.rawValue.capitalized : object.name
        guard let ranges = entry.step.ranges, !ranges.isEmpty else { return name }
        let text = ranges.map { AnimationRanges.text(of: $0, in: object.text) }.joined(separator: " … ")
        let clipped = text.count > 24 ? String(text.prefix(24)) + "…" : text
        return "\(name) · “\(clipped)”"
    }

    var stepTarget: StepTarget? {
        if let id = canvasTextEditID, let selection = canvasTextSelection, selection.length > 0,
           let object = object(id: id) {
            let range = TextStyleRuns.characterRange(
                fromUTF16: selection.location, length: selection.length, in: object.text
            )
            let ranges = AnimationRanges.ranges(forSelection: range, in: object.text)
            guard !ranges.isEmpty else { return nil }
            return .ranges(objectID: id, ranges: ranges)
        }
        let ids = (currentSlide?.objects ?? []).map(\.id).filter { selectedObjectIDs.contains($0) }
        guard !ids.isEmpty else { return nil }
        return .objects(ids)
    }

    enum StepTarget: Equatable {
        case objects([String])
        case ranges(objectID: String, ranges: [AnimationRange])
    }

    @discardableResult
    func addAnimationStep(
        kind: AnimationKind, animation: StepAnimation, trigger: AnimationTrigger,
        appendToLast: Bool = false
    ) -> [String] {
        guard let slideID = selectedSlideID, let target = stepTarget else { return [] }
        var newIDs: [String] = []
        updateSlide(slideID) { slide in
            switch target {
            case .objects(let ids):
                for (position, id) in ids.enumerated() {
                    guard let index = slide.objects.firstIndex(where: { $0.id == id }) else { continue }

                    let stepTrigger: AnimationTrigger = position == 0 || trigger == .withPrevious || trigger == .afterPrevious
                        ? trigger : .withPrevious
                    let step = Self.freshStep(kind: kind, animation: animation, trigger: stepTrigger, ranges: nil)
                    slide.objects[index].animationSteps = (slide.objects[index].animationSteps ?? []) + [step]
                    newIDs.append(step.id)
                    Self.appendToOrder(&slide, step.id)
                }
            case .ranges(let objectID, let ranges):
                guard let index = slide.objects.firstIndex(where: { $0.id == objectID }) else { return }
                if appendToLast,
                   let merged = AnimationRanges.appendingToLastStep(ranges, in: slide.objects[index].animationSteps) {
                    slide.objects[index].animationSteps = merged.animationSteps
                    newIDs.append(merged.stepID)
                } else {
                    let step = Self.freshStep(kind: kind, animation: animation, trigger: trigger, ranges: ranges)
                    slide.objects[index].animationSteps = (slide.objects[index].animationSteps ?? []) + [step]
                    newIDs.append(step.id)
                    Self.appendToOrder(&slide, step.id)
                }
            }
        }
        if let last = newIDs.last { selectedAnimationStepID = last }
        return newIDs
    }

    @discardableResult
    func generateAnimationSteps(
        by generator: AnimationRanges.Generator, kind: AnimationKind, animation: StepAnimation, trigger: AnimationTrigger
    ) -> [String] {
        guard let slideID = selectedSlideID,
              case .ranges(let objectID, let ranges)? = stepTarget,
              let object = object(id: objectID) else { return [] }
        let pieces = AnimationRanges.split(ranges, by: generator, in: object.text)
        guard !pieces.isEmpty else { return [] }
        var newIDs: [String] = []
        updateSlide(slideID) { slide in
            guard let index = slide.objects.firstIndex(where: { $0.id == objectID }) else { return }
            var animationSteps = slide.objects[index].animationSteps ?? []
            for piece in pieces {
                let step = Self.freshStep(kind: kind, animation: animation, trigger: trigger, ranges: [piece])
                animationSteps.append(step)
                newIDs.append(step.id)
                Self.appendToOrder(&slide, step.id)
            }
            slide.objects[index].animationSteps = animationSteps
        }
        if let last = newIDs.last { selectedAnimationStepID = last }
        return newIDs
    }

    func morphBaseline(objectID: String, before stepID: String?) -> SlideObject? {
        guard let slide = documentSlide, let object = slide.objects.first(where: { $0.id == objectID }) else { return nil }
        var state = object
        for entry in stepEntries where entry.objectID == objectID {
            if entry.step.id == stepID { break }
            if entry.step.kind == .morph, let to = entry.step.toObject { state = to; state.id = objectID }
        }
        state.animationSteps = nil
        return state
    }

    @discardableResult
    func addMorph() -> [String] {
        guard let slideID = selectedSlideID, case .objects(let ids)? = stepTarget else { return [] }
        var newIDs: [String] = []
        let baselines = Dictionary(uniqueKeysWithValues: ids.compactMap { id in morphBaseline(objectID: id, before: nil).map { (id, $0) } })
        updateSlide(slideID) { slide in
            for (position, id) in ids.enumerated() {
                guard let index = slide.objects.firstIndex(where: { $0.id == id }), let baseline = baselines[id] else { continue }
                var step = Self.freshStep(kind: .morph, animation: .fade, trigger: position == 0 ? .onClick : .withPrevious, ranges: nil)
                step.durationSeconds = 1.0
                step.toObject = baseline
                slide.objects[index].animationSteps = (slide.objects[index].animationSteps ?? []) + [step]
                newIDs.append(step.id)
                Self.appendToOrder(&slide, step.id)
            }
        }
        if let last = newIDs.last { selectedAnimationStepID = last }
        return newIDs
    }

    func setInCustomStart(_ stepID: String, enabled: Bool) {
        guard let (objectID, step) = animationStep(id: stepID), step.kind == .in else { return }
        if enabled {
            guard var pose = documentSlide?.objects.first(where: { $0.id == objectID }) else { return }
            pose.animationSteps = nil
            updateAnimationStep(stepID) { $0.fromObject = pose }
        } else {
            updateAnimationStep(stepID) { $0.fromObject = nil }
        }
    }

    static func freshStep(
        kind: AnimationKind, animation: StepAnimation, trigger: AnimationTrigger, ranges: [AnimationRange]?
    ) -> AnimationStep {
        var step = AnimationStep(
            id: UUID().uuidString, kind: kind, animation: animation, trigger: trigger,
            durationSeconds: kind == .morph ? 1.0 : 0.5, 
            ranges: ranges
        )
        switch animation {
        case .move: step.edge = kind == .emphasis ? nil : .left
        case .scale: step.fromScale = kind == .emphasis ? nil : 0.95
        case .wipe: step.edge = .left
        default: break
        }
        if animation == .move, kind == .emphasis { step.offsetX = 0; step.offsetY = -20 }
        return step
    }

    private static func appendToOrder(_ slide: inout Slide, _ id: String) {
        guard var order = slide.animationOrder, !order.isEmpty else { return }
        order.append(id)
        slide.animationOrder = order
    }

    func updateAnimationStep(_ id: String, _ mutate: (inout AnimationStep) -> Void) {
        guard let (objectID, _) = animationStep(id: id) else { return }
        updateDocumentObject(id: objectID) { object in
            guard var animationSteps = object.animationSteps, let index = animationSteps.firstIndex(where: { $0.id == id }) else { return }
            mutate(&animationSteps[index])
            object.animationSteps = animationSteps
        }
    }

    private func preserveVacatedClick(removing ids: Set<String>) {
        guard let slide = documentSlide else { return }
        let groups = AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
        for (index, club) in groups.click.enumerated()
        where !club.isEmpty && club.allSatisfy({ ids.contains($0.step.id) }) {
            timelineDraftClickAt = index
            return
        }
    }

    func removeAnimationStep(_ id: String) {
        guard let slideID = selectedSlideID, let (objectID, _) = animationStep(id: id) else { return }
        preserveVacatedClick(removing: [id])
        let promotion = documentSlide.flatMap { AnimationSequence.promotion(afterRemoving: id, objects: $0.objects, order: $0.animationOrder) }
        updateSlide(slideID) { slide in
            if let promotion {
                for index in slide.objects.indices {
                    guard var animationSteps = slide.objects[index].animationSteps,
                          let s = animationSteps.firstIndex(where: { $0.id == promotion.stepID }) else { continue }
                    animationSteps[s].trigger = promotion.trigger
                    slide.objects[index].animationSteps = animationSteps
                }
            }
            guard let index = slide.objects.firstIndex(where: { $0.id == objectID }) else { return }
            var animationSteps = slide.objects[index].animationSteps ?? []
            animationSteps.removeAll { $0.id == id }
            slide.objects[index].animationSteps = animationSteps.isEmpty ? nil : animationSteps
            if var order = slide.animationOrder {
                order.removeAll { $0 == id }
                slide.animationOrder = order.isEmpty ? nil : order
            }
        }
        if selectedAnimationStepID == id { selectedAnimationStepID = nil }
    }

    func moveAnimationStep(id: String, beforeID: String?) {
        guard let slideID = selectedSlideID else { return }
        var ids = stepEntries.map(\.step.id)
        guard let source = ids.firstIndex(of: id) else { return }
        ids.remove(at: source)
        let target = beforeID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(id, at: target)
        guard ids != stepEntries.map(\.step.id) else { return }
        updateSlide(slideID) { $0.animationOrder = ids }
    }

    func selectAnimationStep(_ id: String) {

        let redirects = animationStep(id: id).map {
            $0.1.toObject != nil || $0.1.fromObject != nil
        } ?? false
        if animationPreviewTime != nil, redirects { setAnimationPreviewTime(nil) }
        selectedAnimationStepID = id
        guard let (objectID, _) = animationStep(id: id) else { return }
        selectObject(id: objectID)
    }

    var animationPreviewShownTime: Double {
        animationPreviewPlaying ? animationPreviewPlayhead : (animationPreviewTime ?? 0)
    }

    var animationPreviewDuration: Double {
        guard let slide = currentSlide else { return 0 }
        return AnimationSequence.previewTimeline(objects: slide.objects, order: slide.animationOrder).duration
    }

    func animationPreviewContext(for slide: Slide) -> AnimationContext? {
        if animationPreviewPlaying {
            return AnimationSequence.previewContext(
                objects: slide.objects, order: slide.animationOrder, time: nil, startedAt: animationPreviewStartedAt
            )
        }
        guard let time = animationPreviewTime else { return nil }
        return AnimationSequence.previewContext(objects: slide.objects, order: slide.animationOrder, time: time)
    }

    func setAnimationPreviewTime(_ time: Double?) {
        stopAnimationPreviewClock()

        if animationPreviewPlaying { animationPreviewPlaying = false }
        animationPreviewTime = time.map { min(max($0, 0), animationPreviewDuration) }
        animationPreviewPlayhead = animationPreviewTime ?? 0
        refreshScene()
    }

    func playAnimationPreview(from offset: Double = 0, until stopAt: Double? = nil) {
        stopAnimationPreviewClock()
        animationPreviewTime = nil

        animationPreviewStartedAt = CACurrentMediaTime() - offset
        animationPreviewPlaying = true
        animationPreviewPlayhead = offset
        animationPreviewLoopStart = offset
        animationPreviewStopAt = stopAt
        refreshScene()
        let duration = animationPreviewDuration
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.animationPreviewPlaying else { return }
                let end = self.animationPreviewStopAt ?? duration
                let elapsed = CACurrentMediaTime() - self.animationPreviewStartedAt
                if elapsed >= end + 0.2 {
                    if self.previewRepeats {

                        self.animationPreviewStartedAt =
                            CACurrentMediaTime() - self.animationPreviewLoopStart
                        self.animationPreviewPlayhead = self.animationPreviewLoopStart
                        self.refreshScene()
                    } else {
                        self.stopAnimationPreview()
                    }
                } else {
                    self.animationPreviewPlayhead = min(elapsed, end)
                }
            }
        }
        RunLoop.main.add(clock, forMode: .common)
        animationPreviewClock = clock
    }

    func playPreviewScope() {
        switch previewScope {
        case .all:
            playAnimationPreview()
        case .thisClick:
            playColumn(timelineFocusColumn ?? .auto)
        case .fromPlayhead:
            playAnimationPreview(from: animationPreviewTime ?? animationPreviewPlayhead)
        }
    }

    func playColumn(_ group: SceneAnimationGroup) {
        guard let slide = currentSlide else { return }
        let timeline = AnimationTimelineLayout.timeline(
            objects: slide.objects, order: slide.animationOrder
        )
        guard let column = timeline.columns.first(where: { $0.group == group }) else { return }
        timelineFocusColumn = group
        playAnimationPreview(from: column.start, until: column.start + max(column.duration, 0.01))
    }

    func stopAnimationPreview() {
        stopAnimationPreviewClock()
        guard animationPreviewPlaying || animationPreviewTime != nil else { return }
        animationPreviewPlaying = false
        animationPreviewTime = nil
        animationPreviewPlayhead = 0
        refreshScene()
    }

    func insertPushStandIn(into scene: inout RenderScene, slide: Slide) {
        guard animationPreviewPlaying || animationPreviewTime != nil else { return }
        guard slide.objects.contains(where: { object in
            (object.animationSteps ?? []).contains { $0.videoPush != nil }
        }) else { return }
        scene.addItem(RenderItem(
            id: "preview::pushstandin",
            frame: CGRect(origin: .zero, size: scene.canvasSize),
            content: .media(id: LiveInputPlaceholder.cameraID, scaleMode: .fill, sourceRect: nil)
        ), to: .videoInput)
    }

    private func stopAnimationPreviewClock() {
        animationPreviewClock?.invalidate()
        animationPreviewClock = nil
    }
}

extension SlideEditorModel {

    func animationSentence(_ step: AnimationStep) -> String {
        let edge = step.edge?.displayName.lowercased()
        switch step.kind {
        case .in:
            if step.fromObject != nil { return "Arrives from its custom start" }
            switch step.animation {
            case .fade: return "Fades in"
            case .move: return "Slides in" + (edge.map { " from \($0)" } ?? "")
            case .scale: return "Grows in"
            case .wipe: return "Wipes in" + (edge.map { " from \($0)" } ?? "")
            case .blur: return "Blurs in"
            case .burn: return "Burns in"
            case .glitch: return "Glitches in"
            case .draw: return "Draws in"
            case .type: return "Types in"
            case .pulse, .color: return "Appears"
            }
        case .out:
            switch step.animation {
            case .fade: return "Fades out"
            case .move: return "Slides out" + (edge.map { " to \($0)" } ?? "")
            case .scale: return "Shrinks out"
            case .wipe: return "Wipes out" + (edge.map { " to \($0)" } ?? "")
            case .blur: return "Blurs out"
            case .burn: return "Burns out"
            case .glitch: return "Glitches out"
            case .draw: return "Erases"
            case .type: return "Un-types"
            case .pulse, .color: return "Disappears"
            }
        case .emphasis:
            switch step.animation {
            case .pulse: return "Pulses"
            case .color: return "Flashes color"
            case .scale: return "Grows and settles"
            case .move: return "Nudges"
            case .fade: return "Dims and returns"
            default: return "Emphasizes"
            }
        case .morph:

            let base = animationStep(id: step.id).flatMap { object(id: $0.objectID) }
            let verb = AnimationTimelineLayout.morphMoves(step, object: base) ? "Morphs" : "Changes"
            switch step.animation {
            case .blur: return "\(verb) (blur)"
            case .burn: return "\(verb) (burn)"
            case .glitch: return "\(verb) (glitch)"
            default: return verb
            }
        }
    }

    func stepTimingLabel(_ step: AnimationStep) -> String {
        var parts = [String(format: "%.1fs", step.durationSeconds)]
        let delay = step.delaySeconds ?? 0
        if delay < 0 { parts.append(String(format: "%.1fs early", -delay)) }
        else if delay > 0 { parts.append(String(format: "after %.1fs", delay)) }
        return parts.joined(separator: " · ")
    }

    @discardableResult
    func quickAdd(kind: AnimationKind, animation: StepAnimation, appendToLast: Bool = false) -> [String] {
        let ids: [String]
        switch kind {
        case .morph: ids = addMorph()
        case .out: ids = addAnimationStep(kind: .out, animation: animation, trigger: .onDismiss, appendToLast: appendToLast)
        case .in, .emphasis: ids = addAnimationStep(kind: kind, animation: animation, trigger: .onClick, appendToLast: appendToLast)
        }

        if let slot = stepAddSlot, !appendToLast {
            for id in ids { moveAnimationStep(id: id, into: slot, position: .max) }
        }
        stepAddSlot = nil
        stepAddArmed = false

        if selectQuickAddResult, let first = ids.first {
            selectedAnimationStepID = first
        }
        return ids
    }

    func armStepAdd(into slot: AnimationSequence.GroupSlot?) {
        selectedAnimationStepID = nil
        stepAddSlot = slot
        stepAddArmed = true

        if stepTarget == nil, let objects = currentSlide?.objects, objects.count == 1, let only = objects.first {
            selectObject(id: only.id)
        }
    }

    func moveAnimationStep(id: String, into slot: AnimationSequence.GroupSlot, position: Int) {
        guard let slideID = selectedSlideID, let slide = documentSlide,
              let move = AnimationSequence.groupedMove(objects: slide.objects, order: slide.animationOrder, moving: id, into: slot, position: position)
        else { return }
        let promotion = AnimationSequence.promotion(afterRemoving: id, objects: slide.objects, order: slide.animationOrder)
        updateSlide(slideID) { slide in
            slide.animationOrder = move.order
            var triggers = move.triggers
            if let promotion, triggers[promotion.stepID] == nil { triggers[promotion.stepID] = promotion.trigger }
            for (stepID, trigger) in triggers {
                for index in slide.objects.indices {
                    guard var animationSteps = slide.objects[index].animationSteps,
                          let s = animationSteps.firstIndex(where: { $0.id == stepID }) else { continue }
                    animationSteps[s].trigger = trigger
                    slide.objects[index].animationSteps = animationSteps
                }
            }
        }
    }

    func moveAnimationStep(id: String, toFlatIndex flatIndex: Int, trigger: AnimationTrigger?, displaceFollowingToWith: Bool) {
        guard let slideID = selectedSlideID, let slide = documentSlide else { return }
        var ids = stepEntries.map(\.step.id)
        guard ids.contains(id) else { return }

        let promotion = AnimationSequence.promotion(afterRemoving: id, objects: slide.objects, order: slide.animationOrder)
        ids.removeAll { $0 == id }
        let at = min(max(flatIndex, 0), ids.count)
        ids.insert(id, at: at)
        let following = ids.indices.contains(at + 1) ? ids[at + 1] : nil
        updateSlide(slideID) { slide in
            slide.animationOrder = ids
            func set(_ stepID: String, _ trigger: AnimationTrigger) {
                for index in slide.objects.indices {
                    guard var animationSteps = slide.objects[index].animationSteps,
                          let s = animationSteps.firstIndex(where: { $0.id == stepID }) else { continue }
                    animationSteps[s].trigger = trigger
                    slide.objects[index].animationSteps = animationSteps
                }
            }
            if let promotion, promotion.stepID != following || !displaceFollowingToWith {
                set(promotion.stepID, promotion.trigger)
            }
            if let trigger { set(id, trigger) }
            if displaceFollowingToWith, let following { set(following, .withPrevious) }
        }
    }

    func previewAnimationStep(_ id: String) {
        guard let slide = documentSlide,
              let start = AnimationSequence.previewStart(ofStep: id, objects: slide.objects, order: slide.animationOrder)
        else { return playAnimationPreview() }
        playAnimationPreview(from: max(start - 0.15, 0))
    }

    enum AnimationSpeed: String, CaseIterable {
        case quick, normal, slow, custom
        var seconds: Double? {
            switch self {
            case .quick: 0.3
            case .normal: 0.5
            case .slow: 1.0
            case .custom: nil
            }
        }
        static func of(_ seconds: Double) -> AnimationSpeed {
            allCases.first { $0.seconds.map { abs($0 - seconds) < 0.001 } ?? false } ?? .custom
        }
    }
}

extension SlideEditorModel {

    func replaceStepEffect(_ stepID: String, kind: AnimationKind, animation: StepAnimation) {
        guard let (objectID, current) = animationStep(id: stepID) else { return }
        let baseline = kind == .morph && current.kind != .morph ? morphBaseline(objectID: objectID, before: stepID) : nil
        updateAnimationStep(stepID) { step in
            let fresh = Self.freshStep(kind: kind, animation: animation, trigger: step.trigger, ranges: step.ranges)
            step.kind = kind
            step.animation = animation

            step.edge = fresh.edge
            step.offsetX = fresh.offsetX
            step.offsetY = fresh.offsetY
            step.fromScale = fresh.fromScale
            step.amount = nil
            step.softEdge = nil
            step.drawStart = nil
            step.reverse = nil
            step.colorHex = nil
            if kind == .morph {
                if step.toObject == nil { step.toObject = baseline }
            } else {
                step.toObject = nil
            }
            if kind != .in { step.fromObject = nil }
        }
    }

    func stepWarningFix(_ stepID: String) -> (label: String, apply: () -> Void)? {
        guard let warning = stepWarnings[stepID], let (objectID, step) = animationStep(id: stepID) else { return nil }
        if warning.hasPrefix("Plays before") {

            let entries = stepEntries
            guard let lastIn = entries.last(where: { $0.objectID == objectID && $0.step.kind == .in && $0.step.id != stepID })
            else { return nil }
            return ("Move after the In", { [weak self] in
                guard let self else { return }
                var ids = self.stepEntries.map(\.step.id)
                ids.removeAll { $0 == stepID }
                guard let at = ids.firstIndex(of: lastIn.step.id) else { return }
                ids.insert(stepID, at: at + 1)
                if let slideID = self.selectedSlideID {
                    self.updateSlide(slideID) { $0.animationOrder = ids }

                    if step.trigger == .onDismiss { self.updateAnimationStep(stepID) { $0.trigger = .withPrevious } }
                }
            })
        }
        if warning == "No end state yet" {
            return ("Set end state", { [weak self] in
                guard let self, let baseline = self.morphBaseline(objectID: objectID, before: stepID) else { return }
                self.updateAnimationStep(stepID) { $0.toObject = baseline }
            })
        }
        return nil
    }
}

extension SlideEditorModel {

    @discardableResult
    func applyAnimationPreset(_ preset: AnimationPreset, mode: AnimationPresetApplication.Mode) -> [String] {
        guard let slideID = selectedSlideID, case .objects(let ids)? = stepTarget else { return [] }
        var added: [String] = []
        updateSlide(slideID) { slide in
            for (position, id) in ids.enumerated() {
                guard let index = slide.objects.firstIndex(where: { $0.id == id }) else { continue }
                let result = AnimationPresetApplication.apply(preset, to: slide.objects[index].animationSteps, mode: mode, position: position)
                if mode == .replace, let order = slide.animationOrder {
                    let dropped = Set((slide.objects[index].animationSteps ?? []).map(\.id))
                    slide.animationOrder = order.filter { !dropped.contains($0) }
                }
                slide.objects[index].animationSteps = result.animationSteps
                for stepID in result.addedIDs { Self.appendToOrder(&slide, stepID) }
                added += result.addedIDs
                if let scroll = result.scroll, slide.objects[index].objectKind == .text {
                    var style = slide.objects[index].textStyle ?? TextStyle()
                    style.scroll = scroll
                    slide.objects[index].textStyle = style
                }
                if let tilt = result.tilt { slide.objects[index].tilt = tilt }
            }
            if slide.animationOrder?.isEmpty == true { slide.animationOrder = nil }
        }
        if let last = added.last { selectedAnimationStepID = last }
        return added
    }

    var animationPresetRecipe: (steps: [AnimationStep], scroll: BlockScroll?, tilt: Double?)? {
        guard case .objects(let ids)? = stepTarget, let first = ids.first, let object = object(id: first) else { return nil }
        let steps = AnimationPresetApplication.recipe(from: object.animationSteps)
        let scroll = object.textStyle?.scroll
        guard !steps.isEmpty || scroll != nil else { return nil }
        return (steps, scroll, scroll == nil ? nil : object.tilt)
    }
}

extension SlideEditorModel {

    func placeTimelineStep(_ id: String, atOffset offset: Double) {
        guard let slideID = selectedSlideID, let slide = documentSlide,
              let delta = AnimationSequence.placement(
                  of: id, targetOffset: snap(offset),
                  objects: slide.objects, order: slide.animationOrder
              )
        else {
            DiagnosticsStore.shared.note("timeline.place.bail", detail: "id=\(id.suffix(12)) slide=\(selectedSlideID != nil) doc=\(documentSlide != nil)")
            return
        }
        DiagnosticsStore.shared.note("timeline.place", detail: "id=\(id.suffix(12)) offset=\(offset) trigger=\(delta.trigger) delay=\(String(describing: delta.delaySeconds))")
        let old = AnimationSequence.schedule(objects: slide.objects, order: slide.animationOrder)
        updateSlide(slideID) { slide in
            Self.applyStepDelta(&slide, id: id, trigger: delta.trigger, delay: delta.delaySeconds)
            for pin in AnimationSequence.pins(
                objects: slide.objects, order: slide.animationOrder,
                toPrevious: old, excluding: [id]
            ) {
                Self.applyStepDelta(&slide, id: pin.stepID, trigger: pin.trigger, delay: pin.delaySeconds)
            }
        }
    }

    func resizeTimelineStep(_ id: String, duration: Double) {
        guard let slideID = selectedSlideID, let slide = documentSlide else { return }
        let old = AnimationSequence.schedule(objects: slide.objects, order: slide.animationOrder)
        let value = max(snap(duration), 0.05)
        updateSlide(slideID) { slide in
            for index in slide.objects.indices {
                guard var steps = slide.objects[index].animationSteps,
                      let s = steps.firstIndex(where: { $0.id == id }) else { continue }
                steps[s].durationSeconds = value
                slide.objects[index].animationSteps = steps
            }
            for pin in AnimationSequence.pins(
                objects: slide.objects, order: slide.animationOrder,
                toPrevious: old, excluding: [id]
            ) {
                Self.applyStepDelta(&slide, id: pin.stepID, trigger: pin.trigger, delay: pin.delaySeconds)
            }
        }
    }

    func moveTimelineSteps(_ ids: Set<String>, bySeconds delta: Double) {
        guard !ids.isEmpty, delta != 0,
              let slideID = selectedSlideID, let slide = documentSlide else { return }
        let old = AnimationSequence.schedule(objects: slide.objects, order: slide.animationOrder)

        let headroom = ids.compactMap { old[$0]?.start }.min() ?? 0
        let moved = max(snap(delta), -headroom)
        guard moved != 0 else { return }
        DiagnosticsStore.shared.note(
            "timeline.groupMove",
            detail: "delta=\(moved) ids=\(ids.map { String($0.suffix(14)) }.sorted().joined(separator: ","))"
        )

        var targets: [String: Double] = [:]
        for (id, value) in old {
            targets[id] = ids.contains(id) ? value.start + moved : value.start
        }
        updateSlide(slideID) { slide in
            for pin in AnimationSequence.pins(
                objects: slide.objects, order: slide.animationOrder, targets: targets
            ) {
                Self.applyStepDelta(&slide, id: pin.stepID, trigger: pin.trigger, delay: pin.delaySeconds)
            }
        }
    }

    func trimTimelineStepStart(_ id: String, deltaSeconds raw: Double) {
        guard let slideID = selectedSlideID, let slide = documentSlide,
              let (_, step) = animationStep(id: id) else { return }
        let old = AnimationSequence.schedule(objects: slide.objects, order: slide.animationOrder)
        guard let current = old[id] else { return }
        var delta = min(snap(raw), step.durationSeconds - 0.05)

        let groups = AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
        let isHead = (groups.click + [groups.auto, groups.exit])
            .contains { $0.first?.step.id == id }
        var target = current.start + delta
        if isHead, target < 0 {
            target = 0
            delta = -current.start
        }
        let duration = max((current.start + step.durationSeconds) - target, 0.05)
        guard let pinned = AnimationSequence.pin(
            of: id, targetOffset: target, objects: slide.objects, order: slide.animationOrder
        ) else { return }
        updateSlide(slideID) { slide in
            Self.applyStepDelta(&slide, id: id, trigger: pinned.trigger, delay: pinned.delaySeconds)
            for index in slide.objects.indices {
                guard var steps = slide.objects[index].animationSteps,
                      let s = steps.firstIndex(where: { $0.id == id }) else { continue }
                steps[s].durationSeconds = duration
                slide.objects[index].animationSteps = steps
            }
            for pin in AnimationSequence.pins(
                objects: slide.objects, order: slide.animationOrder,
                toPrevious: old, excluding: [id]
            ) {
                Self.applyStepDelta(&slide, id: pin.stepID, trigger: pin.trigger, delay: pin.delaySeconds)
            }
        }
    }

    private static func applyStepDelta(
        _ slide: inout Slide, id: String, trigger: AnimationTrigger, delay: Double?
    ) {
        for index in slide.objects.indices {
            guard var steps = slide.objects[index].animationSteps,
                  let s = steps.firstIndex(where: { $0.id == id }) else { continue }
            steps[s].trigger = trigger
            steps[s].delaySeconds = delay
            slide.objects[index].animationSteps = steps
        }
    }

    func moveTimelineSteps(
        _ ids: Set<String>, into slot: AnimationSequence.GroupSlot,
        grabbed: String, atOffset drop: Double
    ) {
        guard let slideID = selectedSlideID, let slide = documentSlide else { return }
        let previewOf: (String) -> Double = {
            AnimationSequence.previewStart(ofStep: $0, objects: slide.objects, order: slide.animationOrder) ?? 0
        }
        let first = AnimationSequence.orderedEntries(
            objects: slide.objects, order: slide.animationOrder
        ).first { ids.contains($0.step.id) }
        guard let first else { return }
        let firstOffset = snap(drop - (previewOf(grabbed) - previewOf(first.step.id)))
        guard let move = AnimationSequence.rehomeSteps(
            ids, to: slot, firstOffset: firstOffset,
            objects: slide.objects, order: slide.animationOrder
        ) else { return }
        preserveVacatedClick(removing: ids)
        DiagnosticsStore.shared.note(
            "timeline.rehomeSteps",
            detail: "to=\(slot) first=\(firstOffset) ids=\(ids.map { String($0.suffix(14)) }.sorted().joined(separator: ","))"
        )
        updateSlide(slideID) { slide in
            slide.animationOrder = move.order
            for delta in move.deltas {
                Self.applyStepDelta(&slide, id: delta.stepID, trigger: delta.trigger, delay: delta.delaySeconds)
            }
        }

        if let slide = documentSlide {
            let groups = AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
            if groups.auto.contains(where: { $0.step.id == grabbed }) {
                timelineFocusColumn = .auto
            } else if let n = groups.click.firstIndex(where: { $0.contains { $0.step.id == grabbed } }) {
                timelineFocusColumn = .click(n)
            } else if groups.exit.contains(where: { $0.step.id == grabbed }) {
                timelineFocusColumn = .exit
            }
        }
    }

    func deleteTimelineColumn(_ source: AnimationSequence.GroupSlot) {
        guard let slideID = selectedSlideID, let slide = documentSlide else { return }
        let groups = AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
        let members: [AnimationSequence.Entry]
        switch source {
        case .auto: members = groups.auto
        case .click(let n): members = groups.click.indices.contains(n) ? groups.click[n] : []
        case .newClick: members = []
        case .exit: members = groups.exit
        }
        let ids = Set(members.map(\.step.id))
        guard !ids.isEmpty else { return }
        DiagnosticsStore.shared.note("timeline.deleteColumn", detail: "from=\(source) steps=\(ids.count)")
        updateSlide(slideID) { slide in
            for index in slide.objects.indices {
                let kept = slide.objects[index].animationSteps?.filter { !ids.contains($0.id) }
                slide.objects[index].animationSteps = kept?.isEmpty == true ? nil : kept
            }
            slide.animationOrder = slide.animationOrder?.filter { !ids.contains($0) }
        }
        if let selected = selectedAnimationStepID, ids.contains(selected) {
            selectedAnimationStepID = nil
        }
    }

    func moveTimelineColumn(from source: AnimationSequence.GroupSlot, to slot: AnimationSequence.GroupSlot) {
        guard let slideID = selectedSlideID, let slide = documentSlide,
              let move = AnimationSequence.rehomeGroup(
                  from: source, to: slot,
                  objects: slide.objects, order: slide.animationOrder
              )
        else { return }
        DiagnosticsStore.shared.note(
            "timeline.rehomeColumn",
            detail: "from=\(source) to=\(slot) steps=\(move.deltas.count)"
        )
        updateSlide(slideID) { slide in
            slide.animationOrder = move.order
            for delta in move.deltas {
                Self.applyStepDelta(&slide, id: delta.stepID, trigger: delta.trigger, delay: delta.delaySeconds)
            }
        }

        timelineFocusColumn = {
            switch slot {
            case .auto: return .auto
            case .exit: return .exit
            case .newClick(let n): return .click(n)
            case .click(let n):
                if case .click(let m) = source, m < n { return .click(n - 1) }
                return .click(n)
            }
        }()
    }

    func moveTimelineStep(_ id: String, into slot: AnimationSequence.GroupSlot, atOffset offset: Double) {
        guard let slideID = selectedSlideID, let slide = documentSlide else { return }
        preserveVacatedClick(removing: [id])
        let offset = snap(offset)
        let groups = AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
        if case .click(let n) = slot, !groups.click.indices.contains(n) {

            moveAnimationStep(id: id, toFlatIndex: stepEntries.count, trigger: .onClick, displaceFollowingToWith: false)
            return
        }
        let starts = AnimationSequence.schedule(objects: slide.objects, order: slide.animationOrder)
        let target: [AnimationSequence.Entry] = switch slot {
        case .auto: groups.auto
        case .click(let n): groups.click[n]
        case .newClick: []
        case .exit: groups.exit
        }
        let position = target
            .filter { $0.step.id != id }
            .filter { (starts[$0.step.id]?.start ?? 0) < offset }
            .count
        guard let move = AnimationSequence.groupedMove(
            objects: slide.objects, order: slide.animationOrder,
            moving: id, into: slot, position: position
        ) else { return }
        let promotion = AnimationSequence.promotion(
            afterRemoving: id, objects: slide.objects, order: slide.animationOrder
        )
        updateSlide(slideID) { slide in
            slide.animationOrder = move.order
            var triggers = move.triggers
            if let promotion, triggers[promotion.stepID] == nil {
                triggers[promotion.stepID] = promotion.trigger
            }
            func set(_ stepID: String, _ mutate: (inout AnimationStep) -> Void) {
                for index in slide.objects.indices {
                    guard var steps = slide.objects[index].animationSteps,
                          let s = steps.firstIndex(where: { $0.id == stepID }) else { continue }
                    mutate(&steps[s])
                    slide.objects[index].animationSteps = steps
                }
            }
            for (stepID, trigger) in triggers {
                set(stepID) { $0.trigger = trigger }
            }

            if let delta = AnimationSequence.placement(
                of: id, targetOffset: offset,
                objects: slide.objects, order: slide.animationOrder
            ) {
                set(id) {
                    $0.trigger = delta.trigger
                    $0.delaySeconds = delta.delaySeconds
                }
            }

            for pin in AnimationSequence.pins(
                objects: slide.objects, order: slide.animationOrder,
                toPrevious: starts, excluding: [id]
            ) {
                set(pin.stepID) {
                    $0.trigger = pin.trigger
                    $0.delaySeconds = pin.delaySeconds
                }
            }
        }
    }

    func toggleStepLink(_ id: String) {
        guard let slide = documentSlide,
              let delta = AnimationSequence.linkToggle(
                  of: id, objects: slide.objects, order: slide.animationOrder
              )
        else { return }
        updateAnimationStep(id) {
            $0.trigger = delta.trigger
            $0.delaySeconds = delta.delaySeconds
        }
    }

    func duplicateAnimationStep(_ id: String) {
        guard let slideID = selectedSlideID, let (objectID, step) = animationStep(id: id) else { return }
        var copy = step
        copy.id = UUID().uuidString
        var ids = stepEntries.map(\.step.id)
        let insertAt = ids.firstIndex(of: id).map { $0 + 1 } ?? ids.count
        ids.insert(copy.id, at: insertAt)
        updateSlide(slideID) { slide in
            guard let index = slide.objects.firstIndex(where: { $0.id == objectID }) else { return }
            var steps = slide.objects[index].animationSteps ?? []
            if let at = steps.firstIndex(where: { $0.id == id }) {
                steps.insert(copy, at: at + 1)
            } else {
                steps.append(copy)
            }
            slide.objects[index].animationSteps = steps
            slide.animationOrder = ids
        }
        selectedAnimationStepID = copy.id
    }

    func applyDefaultStep(_ kind: AnimationKind, objectID: String, into slot: AnimationSequence.GroupSlot) {
        guard let slideID = selectedSlideID, let slide = documentSlide else { return }
        let recipe = kind == .out ? appModel.animationDefaultOut : appModel.animationDefaultIn
        var step = recipe
        step.id = UUID().uuidString
        step.kind = kind
        step.ranges = nil
        let groups = AnimationSequence.groups(objects: slide.objects, order: slide.animationOrder)
        var ids = stepEntries.map(\.step.id)
        switch slot {
        case .auto:
            step.trigger = .withPrevious
            if let last = groups.auto.last, let at = ids.firstIndex(of: last.step.id) {
                ids.insert(step.id, at: at + 1)
            } else {
                ids.insert(step.id, at: 0)
            }
        case .click(let n):
            if groups.click.indices.contains(n), let last = groups.click[n].last,
               let at = ids.firstIndex(of: last.step.id) {
                step.trigger = .withPrevious
                ids.insert(step.id, at: at + 1)
            } else {
                step.trigger = .onClick
                ids.append(step.id)
            }
        case .newClick(let k):

            step.trigger = .onClick
            if groups.click.indices.contains(k), let first = groups.click[k].first,
               let at = ids.firstIndex(of: first.step.id) {
                ids.insert(step.id, at: at)
            } else if let firstExit = groups.exit.first,
                      let at = ids.firstIndex(of: firstExit.step.id) {
                ids.insert(step.id, at: at)
            } else {
                ids.append(step.id)
            }
        case .exit:
            step.trigger = .onDismiss
            ids.append(step.id)
        }
        updateSlide(slideID) { slide in
            guard let index = slide.objects.firstIndex(where: { $0.id == objectID }) else { return }
            slide.objects[index].animationSteps = (slide.objects[index].animationSteps ?? []) + [step]
            slide.animationOrder = ids
        }
        selectedAnimationStepID = step.id
    }

    private func snap(_ seconds: Double) -> Double {
        (seconds * 20).rounded() / 20
    }
}
