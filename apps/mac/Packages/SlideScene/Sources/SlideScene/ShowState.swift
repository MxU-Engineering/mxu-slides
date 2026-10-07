import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public enum ShowFunction: String, CaseIterable, Sendable {
    case slides
    case media
    case overlays
    case audio
    case alerts
    case signage

    public var displayName: String {
        switch self {
        case .slides: "Slides"
        case .media: "Media"
        case .overlays: "Overlays"
        case .audio: "Music"
        case .alerts: "Alerts"
        case .signage: "Signage"
        }
    }
}

public struct CueAudio: Sendable, Equatable {
    public var playlistId: String?
    public var audioItemId: String?

    public init(playlistId: String? = nil, audioItemId: String? = nil) {
        self.playlistId = playlistId
        self.audioItemId = audioItemId
    }
}

public struct ShowState: Sendable, Equatable {

    public struct LiveSlide: Sendable, Equatable {
        public var slide: Slide
        public var presentation: Presentation?
        public var theme: Theme?
        public var arrangementId: String?

        public var firedAtHostTime: Double

        public init(
            slide: Slide, presentation: Presentation? = nil,
            theme: Theme? = nil, arrangementId: String? = nil,
            firedAtHostTime: Double = 0
        ) {
            self.slide = slide
            self.presentation = presentation
            self.theme = theme
            self.arrangementId = arrangementId
            self.firedAtHostTime = firedAtHostTime
        }
    }

    public private(set) var liveSlide: LiveSlide?

    public private(set) var lastSlide: LiveSlide?

    public private(set) var liveMedia: [LayerKind: CueMedia] = [:]

    public private(set) var liveOverlays: [Overlay] = []

    public private(set) var liveAudio: [CueAudio] = []

    public private(set) var liveAlert: CueAlert?

    public private(set) var directMediaFires: Set<LayerKind> = []

    public private(set) var overlayFiredAt: [String: Double] = [:]
    public private(set) var alertFiredAtHostTime: Double = 0

    public private(set) var slideAdvanceClicks: [Double] = []

    public private(set) var slideExitAt: Double?

    public private(set) var slideArrivedSettled = false

    public private(set) var slideDismissAt: Double?

    public private(set) var heldFrom: LiveSlide?

    public private(set) var heldFromClicks = 0

    public private(set) var heldFromDismissedLooks: Set<String> = []

    public private(set) var lookDismissAt: [String: Double] = [:]
    public private(set) var overlayDismissAt: [String: Double] = [:]
    public private(set) var alertDismissAt: Double?

    public init() {}

    public mutating func fire(
        slide: Slide,
        presentation: Presentation? = nil,
        theme: Theme? = nil,
        arrangementId: String? = nil,
        atHostTime: Double = 0,
        arrivesSettled: Bool = false
    ) {
        if let outgoing = liveSlide, outgoing.slide.id != slide.id {
            lastSlide = outgoing

            heldFrom = slideDismissAt == nil && slideExitAt == nil ? outgoing : nil
            heldFromClicks = slideAdvanceClicks.count
            heldFromDismissedLooks = Set(lookDismissAt.keys)
        } else {
            heldFrom = nil
            heldFromClicks = 0
            heldFromDismissedLooks = []
        }
        lookDismissAt = [:]
        liveSlide = LiveSlide(
            slide: slide, presentation: presentation,
            theme: theme, arrangementId: arrangementId,
            firedAtHostTime: atHostTime
        )

        slideAdvanceClicks = []
        slideExitAt = nil
        slideArrivedSettled = arrivesSettled
        slideDismissAt = nil
        let background = SlideSceneBuilder.effectiveBackground(
            slide: slide, presentation: presentation, arrangementId: arrangementId
        )
        let backgroundLayer = background.map { SlideSceneBuilder.layerKind($0.layer) }

        for layer in [LayerKind.videos, .stillGraphics] where backgroundLayer != layer {
            if let live = liveMedia[layer], sweepsOnSlideFire(live, on: layer),
               !(layer == .stillGraphics && (slide.actions ?? []).contains(where: {
                   $0.kind == .fireMedia && $0.mediaId == live.mediaId
               })) {
                liveMedia[layer] = nil
                directMediaFires.remove(layer)
            }
        }
        guard let background, let layer = backgroundLayer else { return }
        if liveMedia[layer]?.mediaId == background.mediaId { return }
        liveMedia[layer] = background
        directMediaFires.remove(layer)
    }

    private func sweepsOnSlideFire(_ cue: CueMedia, on layer: LayerKind) -> Bool {
        if cue.classification == nil, layer == .stillGraphics, directMediaFires.contains(layer) {
            true
        } else {
            cue.resolvedClassification == .foreground
        }
    }

    public mutating func presentationEdited(_ presentation: Presentation) {
        if liveSlide?.presentation?.id == presentation.id {
            liveSlide?.presentation = presentation
        }
        if lastSlide?.presentation?.id == presentation.id {
            lastSlide?.presentation = presentation
        }
    }

    public mutating func fire(media: CueMedia, on layer: LayerKind) {
        if liveMedia[layer]?.mediaId == media.mediaId { return }
        liveMedia[layer] = media
        directMediaFires.insert(layer)
    }

    public mutating func fire(overlay: Overlay, atHostTime: Double = 0) {
        if let index = liveOverlays.firstIndex(where: { $0.id == overlay.id }) {
            liveOverlays[index] = overlay
        } else {
            liveOverlays.append(overlay)
        }

        overlayFiredAt[overlay.id] = atHostTime
        overlayDismissAt[overlay.id] = nil
    }

    public mutating func dismissOverlay(id: String, atHostTime: Double? = nil) {
        if let atHostTime, overlayDismissAt[id] == nil,
           let overlay = liveOverlays.first(where: { $0.id == id }),
           AnimationSequence.exitDuration(objects: overlay.objects, order: overlay.animationOrder) > 0 {
            overlayDismissAt[id] = atHostTime
            return
        }
        removeOverlay(id: id)
    }

    private mutating func removeOverlay(id: String) {
        liveOverlays.removeAll { $0.id == id }
        overlayFiredAt[id] = nil
        overlayDismissAt[id] = nil
    }

    public mutating func fire(audio: CueAudio) {
        guard !liveAudio.contains(audio) else { return }
        liveAudio.append(audio)
    }

    public mutating func dismissAudio(_ cue: CueAudio) {
        liveAudio.removeAll { $0 == cue }
    }

    public mutating func fire(alert: CueAlert, atHostTime: Double = 0) {
        liveAlert = alert
        alertFiredAtHostTime = atHostTime
        alertDismissAt = nil
    }

    public var slideThemeOverrides: [Theme] = []

    public var pageTurn: Paging.Turn = .cut

    func slideAnimationCompositions(_ live: LiveSlide) -> [PlaceholderAnimations.Composition] {
        var compositions = [PlaceholderAnimations.stackComposition(slide: live.slide, theme: live.theme)]
        for theme in slideThemeOverrides {

            compositions.append(PlaceholderAnimations.overrideComposition(
                slide: live.slide, originalTheme: live.theme, overrideTheme: theme))
        }
        return compositions
    }

    public var slideClickCount: Int {
        guard let live = liveSlide else { return 0 }
        return slideAnimationCompositions(live)
            .map { AnimationSequence.clickCount(objects: $0.objects, order: $0.order) }
            .max() ?? 0
    }

    public var slideHasExitGroup: Bool {
        guard let live = liveSlide else { return false }
        return slideAnimationCompositions(live).contains {
            AnimationSequence.hasExitGroup(objects: $0.objects, order: $0.order)
        }
    }

    public var slideAdvanceCount: Int {
        slideClickCount + (slideHasExitGroup ? 1 : 0)
    }

    public var slideAnimationStep: (consumed: Int, total: Int)? {
        let total = slideAdvanceCount
        guard total > 0 else { return nil }
        let consumed = min(slideAdvanceClicks.count, slideClickCount)
            + (slideExitAt != nil ? 1 : 0)
        return (min(consumed, total), total)
    }

    public mutating func advanceStep(atHostTime: Double) -> Bool {
        guard liveSlide != nil, slideDismissAt == nil else { return false }
        if slideAdvanceClicks.count < slideClickCount {
            slideAdvanceClicks.append(atHostTime)
            return true
        }
        if slideHasExitGroup, slideExitAt == nil {
            slideExitAt = atHostTime
            return true
        }
        return false
    }

    public mutating func unadvanceStep() -> Bool {
        if slideExitAt != nil {
            slideExitAt = nil
            return true
        }
        guard !slideAdvanceClicks.isEmpty else { return false }
        slideAdvanceClicks.removeLast()
        return true
    }

    public var slideAnimationContext: AnimationContext? {
        guard let live = liveSlide else { return nil }
        guard slideAnimationCompositions(live).contains(where: { AnimationSequence.hasAnimationSteps($0.objects) })
        else { return nil }
        return AnimationContext(
            anchorHostTime: live.firedAtHostTime,
            clickHostTimes: slideAdvanceClicks,
            dismissHostTime: slideDismissAt,
            exitHostTime: slideExitAt,
            autoSettled: slideArrivedSettled
        )
    }

    public func slideStepsCompletedAt() -> Double? {
        guard let live = liveSlide else { return nil }
        let clicks = slideClickCount
        guard slideAdvanceClicks.count >= clicks else { return nil }
        if slideHasExitGroup {
            guard let exitAt = slideExitAt else { return nil }
            let duration = slideAnimationCompositions(live)
                .map { composition in
                    AnimationTimeline.groupDuration(
                        .exit,
                        in: AnimationSequence.sceneSteps(
                            objects: composition.objects, order: composition.order
                        ).values.flatMap { $0 }
                    )
                }
                .max() ?? 0
            return exitAt + duration
        }
        guard clicks > 0 else { return live.firedAtHostTime }
        let lastClick = slideAdvanceClicks[clicks - 1]
        let duration = slideAnimationCompositions(live)
            .map { composition in
                AnimationTimeline.groupDuration(
                    .click(clicks - 1),
                    in: AnimationSequence.sceneSteps(
                        objects: composition.objects, order: composition.order
                    ).values.flatMap { $0 }
                )
            }
            .max() ?? 0
        return lastClick + duration
    }

    public func upcomingRevealText() -> String? {
        guard let live = liveSlide else { return nil }
        for composition in slideAnimationCompositions(live) {
            if let text = AnimationSequence.upcomingRevealText(
                objects: composition.objects, order: composition.order,
                consumed: slideAdvanceClicks.count
            ) { return text }
        }
        return nil
    }

    func slideExitDuration(_ live: LiveSlide) -> Double {
        slideAnimationCompositions(live)
            .map {
                AnimationSequence.exitDuration(
                    objects: $0.objects, order: $0.order,
                    consumedClicks: slideAdvanceClicks.count
                )
            }
            .max() ?? 0
    }

    static func templateID(of slide: Slide, through theme: Theme) -> String? {
        SlideSceneBuilder.themeSlide(for: slide.rendered(throughOverride: theme), theme: theme)?.id
    }

    static func sameTemplate(_ a: Slide, _ b: Slide, through theme: Theme) -> Bool {
        guard !a.objects.isEmpty, !b.objects.isEmpty else { return false }
        return templateID(of: a, through: theme) == templateID(of: b, through: theme)
    }

    static func sameLook(_ a: Theme, _ b: Theme) -> Bool {
        a.id == b.id && a.slides?.map(\.id) == b.slides?.map(\.id)
    }

    public func holdsLook(through theme: Theme) -> Bool {
        if let live = liveSlide, let previous = heldFrom,
           !heldFromDismissedLooks.contains(Self.lookKey(theme)),
           lookStands(previous, through: theme, consumedClicks: heldFromClicks) {
            return Self.sameTemplate(previous.slide, live.slide, through: theme)
        } else {
            return false
        }
    }

    func lookStands(_ live: LiveSlide, through theme: Theme, consumedClicks: Int) -> Bool {
        let composition = PlaceholderAnimations.stackComposition(slide: live.slide.rendered(throughOverride: theme), theme: theme)
        let hasOuts = AnimationSequence.sceneSteps(objects: composition.objects, order: composition.order)
            .values.flatMap { $0 }.contains { $0.kind == .exit }
        return !hasOuts || lookExitDuration(live, through: theme, consumedClicks: consumedClicks) > 0
    }

    static func lookKey(_ theme: Theme) -> String {
        theme.id + "|" + (theme.slides?.map(\.id).joined(separator: ",") ?? "")
    }

    public func handoff(to slide: Slide, incomingOverrides: [Theme]) -> (wait: Double, leaving: [Theme]) {
        guard let live = liveSlide, slideDismissAt == nil, slideExitAt == nil, live.slide.id != slide.id else { return (0, []) }
        var leaving: [Theme] = []
        var wait = 0.0
        for theme in slideThemeOverrides where lookDismissAt[Self.lookKey(theme)] == nil {
            let stays = incomingOverrides.contains { Self.sameLook($0, theme) }
            if stays, Self.sameTemplate(live.slide, slide, through: theme) { continue }
            let out = lookExitDuration(live, through: theme, consumedClicks: slideAdvanceClicks.count)
            guard out > 0 else { continue }
            leaving.append(theme)
            wait = max(wait, out)
        }
        return (wait, leaving)
    }

    public func handoffWait(to slide: Slide, incomingOverrides: [Theme]) -> Double {
        handoff(to: slide, incomingOverrides: incomingOverrides).wait
    }

    public func lookSwitch(to incomingOverrides: [Theme]) -> (wait: Double, leaving: [Theme]) {
        guard let live = liveSlide, slideDismissAt == nil, slideExitAt == nil else { return (0, []) }
        var leaving: [Theme] = []
        var wait = 0.0
        for theme in slideThemeOverrides where lookDismissAt[Self.lookKey(theme)] == nil {
            guard !incomingOverrides.contains(where: { Self.sameLook($0, theme) }) else { continue }
            let out = lookExitDuration(live, through: theme, consumedClicks: slideAdvanceClicks.count)
            guard out > 0 else { continue }
            leaving.append(theme)
            wait = max(wait, out)
        }
        return (wait, leaving)
    }

    public mutating func dismissLooks(_ themes: [Theme], atHostTime: Double) {
        guard liveSlide != nil else { return }
        for theme in themes { lookDismissAt[Self.lookKey(theme)] = atHostTime }
    }

    func lookExitDuration(_ live: LiveSlide, through theme: Theme, consumedClicks: Int) -> Double {
        let composition = PlaceholderAnimations.stackComposition(slide: live.slide.rendered(throughOverride: theme), theme: theme)
        return AnimationSequence.exitDuration(
            objects: composition.objects, order: composition.order, consumedClicks: consumedClicks)
    }

    public var hasPendingExits: Bool {
        slideDismissAt != nil || !overlayDismissAt.isEmpty || alertDismissAt != nil
    }

    @discardableResult
    public mutating func sweepFinishedExits(now: Double) -> Bool {
        var changed = false
        if let dismissAt = slideDismissAt, let live = liveSlide {
            if now >= dismissAt + slideExitDuration(live) {
                removeSlide()
                changed = true
            }
        }
        for (id, dismissAt) in overlayDismissAt {
            guard let overlay = liveOverlays.first(where: { $0.id == id }) else {
                overlayDismissAt[id] = nil
                continue
            }
            if now >= dismissAt + AnimationSequence.exitDuration(objects: overlay.objects, order: overlay.animationOrder) {
                removeOverlay(id: id)
                changed = true
            }
        }
        if let dismissAt = alertDismissAt {
            if now >= dismissAt + alertExitDuration() {
                removeAlert()
                changed = true
            }
        }
        return changed
    }

    public static let holdFadeSeconds = 0.3

    static func holdFade(_ step: AnimationStep) -> AnimationStep {
        guard step.kind == .in, step.trigger == .withPrevious || step.trigger == .afterPrevious else { return step }
        var fade = step
        fade.animation = .fade
        fade.trigger = .withPrevious
        fade.delaySeconds = nil
        fade.durationSeconds = holdFadeSeconds
        fade.edge = nil
        fade.offsetX = nil
        fade.offsetY = nil
        fade.fromScale = nil
        fade.withFade = nil
        return fade
    }

    static func isDonated(_ object: SlideObject) -> Bool {
        guard let steps = object.animationSteps, !steps.isEmpty else { return false }
        return steps.allSatisfy { $0.id.contains("::") }
    }

    private func alertExitDuration() -> Double {
        guard let alert = liveAlert, alert.showsOnAudience,
              let template = AlertSceneBuilder.alertsThemeSlide(in: alert.theme)
        else { return 0 }
        return AnimationSequence.exitDuration(objects: template.objects, order: template.animationOrder)
    }

    private mutating func removeSlide() {

        lastSlide = liveSlide ?? lastSlide
        liveSlide = nil
        heldFrom = nil
        heldFromClicks = 0
        heldFromDismissedLooks = []
        lookDismissAt = [:]
        slideAdvanceClicks = []
        slideExitAt = nil
        slideArrivedSettled = false
        slideDismissAt = nil
    }

    private mutating func removeAlert() {
        liveAlert = nil
        alertDismissAt = nil
    }

    private mutating func clearSlide(atHostTime: Double?) {
        if slideExitAt != nil {
            removeSlide()
            return
        }
        if let atHostTime, slideDismissAt == nil, let live = liveSlide {
            if slideExitDuration(live) > 0 {
                slideDismissAt = atHostTime
                return
            }
        }
        removeSlide()
    }

    private mutating func clearAlert(atHostTime: Double?) {
        if let atHostTime, alertDismissAt == nil, liveAlert != nil, alertExitDuration() > 0 {
            alertDismissAt = atHostTime
            return
        }
        removeAlert()
    }

    public mutating func clear(function: ShowFunction, atHostTime: Double? = nil) {
        switch function {
        case .slides:
            clearSlide(atHostTime: atHostTime)
        case .media:
            liveMedia = [:]
            directMediaFires = []
        case .overlays:
            for overlay in liveOverlays {
                dismissOverlay(id: overlay.id, atHostTime: atHostTime)
            }
        case .audio: liveAudio = [] 
        case .alerts: clearAlert(atHostTime: atHostTime)
        case .signage:

            break
        }
    }

    public mutating func clear(layer: LayerKind, atHostTime: Double? = nil) {
        switch layer {
        case .loopingVideos, .stillGraphics, .videos, .videoInput:

            liveMedia[layer] = nil
            directMediaFires.remove(layer)
        case .slide:
            clearSlide(atHostTime: atHostTime)
        case .overlays, .alerts:
            break 
        }
        for overlay in liveOverlays
        where (overlay.layer.flatMap(LayerKind.init(rawValue:)) ?? .overlays) == layer {
            dismissOverlay(id: overlay.id, atHostTime: atHostTime)
        }
        if let alert = liveAlert, (alert.layer ?? .alerts) == layer {
            clearAlert(atHostTime: atHostTime)
        }

    }

    public mutating func clearAll(includingAudio: Bool = true, protecting: Set<LayerKind> = []) {
        guard !protecting.isEmpty else {
            for function in ShowFunction.allCases {
                if function == .audio && !includingAudio { continue }
                clear(function: function)
            }
            return
        }
        for layer in LayerKind.allCases where !protecting.contains(layer) {
            clear(layer: layer)
        }
        if includingAudio { clear(function: .audio) }
        clear(function: .signage)
    }

    public func scene(
        canvasSize explicitCanvas: CGSize? = nil,
        alertVisible: Bool = true,
        linkedText info: ConfidenceInfo? = nil,
        slideThemeOverride: Theme? = nil,
        at date: Date = Date()
    ) -> RenderScene {

        let canvasSize = explicitCanvas
            ?? SlideSceneBuilder.canvasSize(for: liveSlide?.presentation)
        var scene = RenderScene(canvasSize: canvasSize)
        for (layer, media) in liveMedia {
            scene.addItem(
                RenderItem(
                    id: "live-media-\(layer.rawValue)",
                    frame: CGRect(origin: .zero, size: canvasSize),
                    content: .media(id: media.mediaId, scaleMode: .fill)
                ),
                to: layer
            )
        }
        if let live = liveSlide {

            if let fill = live.slide.backgroundFill ?? live.presentation?.backgroundFill,
               let item = SlideSceneBuilder.backdropItem(
                   fill, canvasSize: canvasSize, baseID: "\(live.slide.id)-backdrop"
               ) {
                scene.addItem(item, to: .slide)
            }
            let theme = slideThemeOverride ?? live.theme

            let renderedSlide = slideThemeOverride.map { live.slide.rendered(throughOverride: $0) } ?? live.slide
            var slideObjects = live.slide.objects
            if let info {
                slideObjects = LinkedText.resolvedObjects(slideObjects, info: info, at: date)
            }
            if let override = slideThemeOverride {

                slideObjects = ThemeOverride.overrideObjects(
                    for: renderedSlide, objects: slideObjects,
                    originalTheme: live.theme, overrideTheme: override
                )
            }
            let template = SlideSceneBuilder.themeSlide(for: renderedSlide, theme: theme)

            let donated = PlaceholderAnimations.composition(
                objects: slideObjects, template: template, slideOrder: live.slide.animationOrder
            )
            slideObjects = donated.objects

            let held = slideThemeOverride.map { holdsLook(through: $0) } ?? false
            if held {
                for index in slideObjects.indices where Self.isDonated(slideObjects[index]) {
                    slideObjects[index].animationSteps = slideObjects[index].animationSteps?.map(Self.holdFade)
                }
            }

            let paged = Paging.paged(
                objects: slideObjects, template: template, theme: theme, order: donated.order,
                canvas: canvasSize, turn: pageTurn)
            slideObjects = paged.objects
            let placeholders = SlideSceneBuilder.placeholderAssignments(
                for: slideObjects, in: template
            )
            var stack = SlideSceneBuilder.composedStack(for: slideObjects, in: template)
            if let info {

                stack = stack.map { entry in
                    guard entry.fromTheme, entry.object.textLink != nil else { return entry }
                    return SlideSceneBuilder.ComposedEntry(
                        object: LinkedText.resolvedObjects([entry.object], info: info, at: date)[0],
                        fromTheme: true
                    )
                }
            }
            let wiring = SlideSceneBuilder.maskWiring(for: stack.map(\.object))

            let slideSteps = AnimationSequence.sceneSteps(
                objects: stack.map(\.object), order: paged.order
            )
            let slideContext = slideAnimationContext

            var lookContext = slideContext
            if let override = slideThemeOverride, let dismissedAt = lookDismissAt[Self.lookKey(override)] {
                lookContext?.dismissHostTime = dismissedAt
            }
            var heldContext = lookContext
            heldContext?.autoSettled = true
            for entry in stack {
                let context = held && entry.fromTheme ? heldContext : lookContext
                for var item in SlideSceneBuilder.renderItems(
                    for: entry.object, theme: theme,
                    placeholder: entry.fromTheme ? nil : placeholders[entry.object.id],
                    in: canvasSize, baseID: entry.id,
                    maskedBy: wiring.maskedBy[entry.object.id],
                    matteGroup: wiring.mattes.contains(entry.object.id) ? entry.object.id : nil,
                    animationSteps: slideSteps[entry.object.id] ?? []
                ) {

                    item.tickerAnchorHostTime = live.firedAtHostTime
                    item.animationContext = context
                    scene.addItem(item, to: .slide)
                }
            }
        }
        for overlay in liveOverlays {

            let layer = overlay.layer.flatMap(LayerKind.init(rawValue:)) ?? .overlays
            var overlayObjects = overlay.objects
            if let info {
                overlayObjects = LinkedText.resolvedObjects(overlayObjects, info: info, at: date)
            }
            let wiring = SlideSceneBuilder.maskWiring(for: overlayObjects)
            let overlaySteps = AnimationSequence.sceneSteps(objects: overlayObjects, order: overlay.animationOrder)
            let overlayContext = overlaySteps.isEmpty ? nil : AnimationContext(
                anchorHostTime: overlayFiredAt[overlay.id] ?? 0,
                dismissHostTime: overlayDismissAt[overlay.id]
            )
            for object in overlayObjects {
                for var item in SlideSceneBuilder.renderItems(
                    for: object, theme: nil,
                    baseID: "overlay-\(overlay.id)-\(object.id)",
                    maskedBy: wiring.maskedBy[object.id],
                    matteGroup: wiring.mattes.contains(object.id) ? object.id : nil,
                    animationSteps: overlaySteps[object.id] ?? []
                ) {
                    item.tickerAnchorHostTime = overlayFiredAt[overlay.id] ?? 0
                    item.animationContext = overlayContext
                    scene.addItem(item, to: layer)
                }
            }
        }

        if let alert = liveAlert, alert.showsOnAudience, alertVisible {
            let alertHasAnimationSteps = AlertSceneBuilder.alertsThemeSlide(in: alert.theme)
                .map { AnimationSequence.hasAnimationSteps($0.objects) } ?? false
            let alertContext = alertHasAnimationSteps
                ? AnimationContext(anchorHostTime: alertFiredAtHostTime, dismissHostTime: alertDismissAt)
                : nil
            for var item in AlertSceneBuilder.audienceItems(
                for: alert, canvasSize: canvasSize, info: info, at: date
            ) {
                item.tickerAnchorHostTime = alertFiredAtHostTime
                item.animationContext = alertContext
                scene.addItem(item, to: alert.layer ?? .alerts)
            }
        }
        return scene
    }

    public var hasLinkedText: Bool {
        linkedObjects { $0.textLink != nil }
    }

    public var hasTimeVaryingLinkedText: Bool {
        linkedObjects { $0.textLink.map(LinkedText.isTimeVarying) == true }
    }

    public func hasTimeVaryingLinkedText(slideThemeOverrides: [Theme]) -> Bool {
        hasLinkedText(where: LinkedText.isTimeVarying, slideThemeOverrides: slideThemeOverrides)
    }

    public func linkedTextTickInterval(slideThemeOverrides: [Theme]) -> TimeInterval? {
        if hasLinkedText(where: LinkedText.ticksSubSecond, slideThemeOverrides: slideThemeOverrides) {
            return LinkedText.subSecondTickInterval
        } else if hasLinkedText(where: LinkedText.isTimeVarying, slideThemeOverrides: slideThemeOverrides) {
            return 1.0
        } else {
            return nil
        }
    }

    private func hasLinkedText(where matches: @escaping (TextLink) -> Bool, slideThemeOverrides: [Theme]) -> Bool {
        let objectMatches: (SlideObject) -> Bool = { $0.textLink.map(matches) == true }
        if linkedObjects(objectMatches) {
            return true
        } else if let live = liveSlide {
            return slideThemeOverrides.contains { theme in
                SlideSceneBuilder.themeSlide(for: live.slide.rendered(throughOverride: theme), theme: theme)?
                    .objects.contains(where: objectMatches) ?? false
            }
        } else {
            return false
        }
    }

    private func linkedObjects(_ matches: (SlideObject) -> Bool) -> Bool {
        if let live = liveSlide {
            if live.slide.objects.contains(where: matches) { return true }
            if let template = SlideSceneBuilder.themeSlide(for: live.slide, theme: live.theme),
               template.objects.contains(where: matches) { return true }
        }

        if let alert = liveAlert, alert.showsOnAudience,
           let template = AlertSceneBuilder.alertsThemeSlide(in: alert.theme),
           template.objects.contains(where: matches) { return true }
        return liveOverlays.contains { $0.objects.contains(where: matches) }
    }

    public func wantedMedia(slideThemeOverrides: [Theme] = []) -> [String: Bool?] {
        var wanted: [String: Bool?] = [:]
        for media in liveMedia.values where !media.mediaId.isEmpty {
            wanted[media.mediaId] = media.loops
        }

        func merge(_ objects: [SlideObject]) {
            for (id, loops) in SlideSceneBuilder.mediaWants(for: objects)
            where wanted[id] == nil {
                wanted.updateValue(loops, forKey: id)
            }
        }
        if let live = liveSlide {
            var objects = live.slide.objects
            if let template = SlideSceneBuilder.themeSlide(for: live.slide, theme: live.theme) {
                objects += template.objects
            }
            for theme in slideThemeOverrides {
                if let template = SlideSceneBuilder.themeSlide(for: live.slide.rendered(throughOverride: theme), theme: theme) {
                    objects += template.objects
                }
            }
            merge(objects)
        }
        for overlay in liveOverlays {
            merge(overlay.objects)
        }

        if let alert = liveAlert, alert.showsOnAudience,
           let template = AlertSceneBuilder.alertsThemeSlide(in: alert.theme) {
            merge(template.objects)
        }
        return wanted
    }
}
