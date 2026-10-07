import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public enum SlideSceneBuilder {

    public static let canvasSize = CGSize(width: 1920, height: 1080)

    public static func canvasSize(for presentation: Presentation?) -> CGSize {
        guard let presentation,
            let width = presentation.canvasWidth, width > 0,
            let height = presentation.canvasHeight, height > 0
        else { return canvasSize }
        return CGSize(width: width, height: height)
    }

    public static func defaultFrame(
        for kind: SlideObjectKind, in canvas: CGSize = canvasSize
    ) -> CGRect {
        switch kind {
        case .text:
            CGRect(
                x: canvas.width * 0.1,
                y: canvas.height * 0.1,
                width: canvas.width * 0.8,
                height: canvas.height * 0.8
            )
        case .media, .shape, .liveInput:
            CGRect(origin: .zero, size: canvas)
        }
    }

    public static func arrangedSlides(
        for presentation: Presentation,
        arrangementId: String? = nil
    ) -> [Slide] {
        let id = arrangementId
        guard let id, !id.isEmpty,
              let arrangement = presentation.arrangements?.first(where: { $0.id == id }),
              !arrangement.sectionIds.isEmpty
        else { return presentation.slides }
        return arrangement.sectionIds.flatMap { sectionId in
            presentation.slides.filter { $0.sectionId == sectionId }
        }
    }

    public static func arrangementBlockStarts(
        for presentation: Presentation,
        arrangementId: String? = nil
    ) -> [Int] {
        if let id = arrangementId, !id.isEmpty,
           let arrangement = presentation.arrangements?.first(where: { $0.id == id }),
           !arrangement.sectionIds.isEmpty {
            var starts: [Int] = []
            var index = 0
            for sectionId in arrangement.sectionIds {
                starts.append(index)
                index += presentation.slides.count { $0.sectionId == sectionId }
            }
            return starts
        }
        let sections = presentation.sections ?? []
        var starts: [Int] = []
        var lastID: String?
        for (index, slide) in presentation.slides.enumerated() {
            if slide.sectionId != lastID, let id = slide.sectionId,
               sections.contains(where: { $0.id == id }) {
                starts.append(index)
            }
            lastID = slide.sectionId
        }
        return starts
    }

    public static func autoAdvanceTarget(
        occurrence: Int, count: Int, loopToStart: Bool
    ) -> Int? {
        guard count > 0, (0 ..< count).contains(occurrence) else { return nil }
        let next = occurrence + 1
        if next < count { return next }
        return loopToStart ? 0 : nil
    }

    public static func effectiveAutoAdvance(
        slide: Slide, presentation: Presentation?
    ) -> AutoAdvance? {
        slide.autoAdvance ?? presentation?.autoAdvance
    }

    public enum BackgroundSource: Equatable {

        case slide(String)
        case section(String)
        case song
    }

    public static func backgroundSource(
        slide: Slide,
        presentation: Presentation?,
        arrangementId: String? = nil
    ) -> (media: CueMedia, source: BackgroundSource)? {
        if let own = slide.background, !own.mediaId.isEmpty { return (own, .slide(slide.id)) }
        guard let presentation else { return nil }
        let sequence = arrangedSlides(for: presentation, arrangementId: arrangementId)
        if let index = sequence.firstIndex(where: { $0.id == slide.id }) {

            for prior in sequence[..<index].reversed() {
                guard let declared = prior.background, !declared.mediaId.isEmpty else { continue }

                if layerKind(declared.layer) == .videos { continue }
                if declared.mode == .untilReplaced { return (declared, .slide(prior.id)) }
                break
            }
        }
        if let sectionId = slide.sectionId, !sectionId.isEmpty,
           let section = presentation.sections?.first(where: { $0.id == sectionId }),
           let declared = section.background, !declared.mediaId.isEmpty {
            return (declared, .section(sectionId))
        }
        if let song = presentation.background, !song.mediaId.isEmpty { return (song, .song) }
        return nil
    }

    public static func effectiveBackground(
        slide: Slide,
        presentation: Presentation?,
        arrangementId: String? = nil
    ) -> CueMedia? {
        backgroundSource(slide: slide, presentation: presentation, arrangementId: arrangementId)?.media
    }

    public static func backgroundSources(
        for presentation: Presentation,
        arrangementId: String? = nil
    ) -> [String: (media: CueMedia, source: BackgroundSource)] {
        var result: [String: (media: CueMedia, source: BackgroundSource)] = [:]

        var covering: (media: CueMedia, declarer: String)?
        for slide in arrangedSlides(for: presentation, arrangementId: arrangementId) {
            let own = slide.background.flatMap { $0.mediaId.isEmpty ? nil : $0 }

            if result[slide.id] == nil {
                if let own {
                    result[slide.id] = (own, .slide(slide.id))
                } else if let covering {
                    result[slide.id] = (covering.media, .slide(covering.declarer))
                }
            }
            if let own, layerKind(own.layer) != .videos {
                covering = own.mode == .untilReplaced ? (own, slide.id) : nil
            }
        }
        for slide in presentation.slides where result[slide.id] == nil {
            if let own = slide.background, !own.mediaId.isEmpty {

                result[slide.id] = (own, .slide(slide.id))
            } else if let sectionId = slide.sectionId, !sectionId.isEmpty,
                      let section = presentation.sections?.first(where: { $0.id == sectionId }),
                      let declared = section.background, !declared.mediaId.isEmpty {
                result[slide.id] = (declared, .section(sectionId))
            } else if let song = presentation.background, !song.mediaId.isEmpty {
                result[slide.id] = (song, .song)
            }
        }
        return result
    }

    public static func themeSlide(for slide: Slide, theme: Theme?) -> Slide? {
        guard let slides = theme?.slides, !slides.isEmpty else { return nil }
        if let name = slide.themeSlideName, !name.isEmpty,
           let match = slides.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        return slides.first
    }

    public static func lookKey(for slide: Slide, theme: Theme?) -> String {
        "\(theme?.id ?? "")|\(themeSlide(for: slide, theme: theme)?.id ?? "")"
    }

    public static func peakLook(_ scene: RenderScene) -> RenderScene {
        var scene = scene
        for layer in scene.layers.indices {
            for item in scene.layers[layer].items.indices {

                scene.layers[layer].items[item].animationSteps.removeAll {
                    $0.kind == .exit || $0.id.contains(Paging.stepMarker)
                }
            }
        }
        return scene
    }

    public static func placeholder(in themeSlide: Slide) -> SlideObject? {
        themeSlide.objects.first { $0.objectKind == .text }
    }

    public static func placeholderAssignments(
        for objects: [SlideObject],
        in template: Slide?
    ) -> [String: SlideObject] {
        guard let template else { return [:] }
        let placeholders = template.objects.filter { $0.objectKind == .text }
        guard !placeholders.isEmpty else { return [:] }
        let textObjects = objects.filter { $0.objectKind == .text }

        var assignments: [String: SlideObject] = [:]
        var claimed = Set<String>()
        for object in textObjects {
            guard let match = placeholders.first(where: {
                $0.name.caseInsensitiveCompare(object.name) == .orderedSame
            }) else { continue }
            assignments[object.id] = match
            claimed.insert(match.id)
        }
        var remaining = placeholders.filter { !claimed.contains($0.id) }
        for object in textObjects where assignments[object.id] == nil {
            assignments[object.id] = remaining.isEmpty ? placeholders[0] : remaining.removeFirst()
        }
        return assignments
    }

    public static func hasThemeOverrides(_ slide: Slide) -> Bool {
        slide.objects.contains { object in
            object.objectKind == .text && (
                object.textStyle != nil
                    || object.x != nil || object.y != nil
                    || object.width != nil || object.height != nil
            )
        }
    }

    public static func resetThemeOverrides(_ slide: inout Slide) {
        for index in slide.objects.indices where slide.objects[index].objectKind == .text {
            slide.objects[index].textStyle = nil
            slide.objects[index].x = nil
            slide.objects[index].y = nil
            slide.objects[index].width = nil
            slide.objects[index].height = nil
        }
    }

    public static func bakedSlide(_ slide: Slide, theme: Theme?) -> Slide {
        guard let theme else { return slide }
        let template = themeSlide(for: slide, theme: theme)
        let assignments = placeholderAssignments(for: slide.objects, in: template)

        func baked(_ object: SlideObject) -> SlideObject {
            guard object.objectKind == .text else { return object }
            var copy = object
            let resolved = frame(for: object, placeholder: assignments[object.id])
            copy.x = resolved.origin.x
            copy.y = resolved.origin.y
            copy.width = resolved.width
            copy.height = resolved.height
            copy.textStyle = bakedTextStyle(
                own: object.textStyle,
                placeholder: assignments[object.id]?.textStyle,
                theme: theme
            )
            return copy
        }

        var objects: [SlideObject] = []
        for entry in composedStack(for: slide.objects, in: template) {
            if entry.fromTheme {
                var copy = entry.object
                copy.id = UUID().uuidString
                objects.append(copy)
            } else {
                objects.append(baked(entry.object))
            }
        }

        var result = slide
        result.objects = objects
        result.themeSlideName = nil
        return result
    }

    public static func clippedTextObjectIDs(
        for slide: Slide,
        theme: Theme?,
        presentation: Presentation? = nil
    ) -> [String] {
        let built = scene(for: slide, theme: theme, presentation: presentation)
        let objectIDs = Set(slide.objects.map(\.id))
        var clipped: [String] = []
        for layer in built.layers where layer.kind == .slide {
            for item in layer.items {

                guard case .text(let styled) = item.content,
                      styled.pathData == nil, styled.tickerSpeed == 0, styled.scroll == nil
                else { continue }
                let baseID = item.id.hasSuffix("::text") ? String(item.id.dropLast(6)) : item.id
                guard objectIDs.contains(baseID), !clipped.contains(baseID) else { continue }
                if TextRasterizer.overflows(styled, sceneFrame: item.frame.size) {
                    clipped.append(baseID)
                }
            }
        }
        return clipped
    }

    public static func backdropItem(
        _ fill: ObjectFill, canvasSize: CGSize, baseID: String
    ) -> RenderItem? {
        var object = SlideObject(id: baseID, objectKind: .shape, name: "Backdrop", text: "")
        object.x = 0
        object.y = 0
        object.width = canvasSize.width
        object.height = canvasSize.height
        object.fill = fill
        return renderItems(for: object, theme: nil, in: canvasSize).first
    }

    private static func bakedTextStyle(
        own: TextStyle?,
        placeholder: TextStyle?,
        theme: Theme
    ) -> TextStyle {
        var style = own ?? TextStyle()
        func fill<T>(_ keyPath: WritableKeyPath<TextStyle, T?>, base: T? = nil) {
            if style[keyPath: keyPath] == nil {
                style[keyPath: keyPath] = placeholder?[keyPath: keyPath] ?? base
            }
        }
        fill(\.fontName, base: theme.fontFamily)
        fill(\.fontSize, base: theme.fontSize)
        fill(\.colorHex, base: theme.textColorHex)
        fill(\.fill)
        fill(\.lineFill)
        fill(\.tracking)
        fill(\.lineHeightMultiple)
        fill(\.horizontalAlignment)
        fill(\.verticalAlignment)
        fill(\.textTransform)
        fill(\.tabularFigures)
        fill(\.autoShrink)
        fill(\.minFontSize)
        fill(\.keepLinesWhole)
        fill(\.balancedWrap)
        fill(\.outline)
        fill(\.shadow)

        fill(\.pathData)
        fill(\.tickerSpeed)
        fill(\.pathSide)
        fill(\.pathOffset)
        fill(\.tickerDirection)
        fill(\.tickerRepeat)
        fill(\.tickerStream)
        fill(\.tickerGap)
        fill(\.tickerSeparator)
        fill(\.tickerRamp)
        fill(\.scroll)
        fill(\.wordSpacing)

        fill(\.insetTop)
        fill(\.insetLeft)
        fill(\.insetBottom)
        fill(\.insetRight)
        fill(\.firstLineIndent)
        fill(\.leftIndent)
        fill(\.rightIndent)
        fill(\.paragraphSpacing)
        return style
    }

    public static func scene(
        for slide: Slide,
        theme: Theme?,
        presentation: Presentation? = nil,
        arrangementId: String? = nil,
        showThemeDecor: Bool = true,
        canvasSize explicitCanvas: CGSize? = nil,
        animationContext: AnimationContext? = nil,
        pageTurn: Paging.Turn = .cut,
        carriedMedia: [LayerKind: String] = [:]
    ) -> RenderScene {

        let canvasSize = explicitCanvas ?? Self.canvasSize(for: presentation)
        var scene = RenderScene(canvasSize: canvasSize)
        if let theme, let background = ColorHex.color(theme.backgroundColorHex) {
            scene.background = background
        }
        let background = effectiveBackground(
            slide: slide, presentation: presentation, arrangementId: arrangementId
        )
        if let background {
            scene.addItem(
                RenderItem(
                    id: "\(slide.id)-cue-background",
                    frame: CGRect(origin: .zero, size: canvasSize),
                    content: .media(id: background.mediaId, scaleMode: .fill)
                ),
                to: layerKind(background.layer)
            )
        }

        let cueBackground = background.map { (layer: layerKind($0.layer), mediaId: $0.mediaId) }
        for layer in LayerKind.allCases {
            if let mediaId = carriedMedia[layer],
               !(cueBackground?.layer == layer && cueBackground?.mediaId == mediaId) {
                scene.addItem(
                    RenderItem(
                        id: "\(slide.id)-carried-\(layer.rawValue)",
                        frame: CGRect(origin: .zero, size: canvasSize),
                        content: .media(id: mediaId, scaleMode: .fill)
                    ),
                    to: layer
                )
            }
        }

        if let fill = slide.backgroundFill ?? presentation?.backgroundFill,
           let item = backdropItem(fill, canvasSize: canvasSize, baseID: "\(slide.id)-backdrop") {
            scene.addItem(item, to: .slide)
        }
        let template = themeSlide(for: slide, theme: theme)

        let donated = PlaceholderAnimations.composition(
            objects: slide.objects, template: template, slideOrder: slide.animationOrder
        )

        let paged = Paging.paged(
            objects: donated.objects, template: template, theme: theme, order: donated.order, canvas: canvasSize,
            turn: pageTurn)
        let placeholders = placeholderAssignments(for: paged.objects, in: template)
        let stack = composedStack(for: paged.objects, in: template)

        let wiring = maskWiring(for: stack.map(\.object))

        let music = MusicContext(presentation)

        let animationSteps = AnimationSequence.sceneSteps(
            objects: stack.map(\.object), order: paged.order
        )
        for entry in stack {
            if entry.fromTheme {
                guard showThemeDecor else { continue }

                for var item in renderItems(
                    for: entry.object, theme: theme, in: canvasSize, baseID: entry.id,
                    maskedBy: wiring.maskedBy[entry.object.id],
                    matteGroup: wiring.mattes.contains(entry.object.id) ? entry.object.id : nil,
                    music: music,
                    animationSteps: animationSteps[entry.object.id] ?? []
                ) {
                    item.animationContext = animationContext
                    scene.addItem(item, to: .slide)
                }
            } else {
                for var item in renderItems(
                    for: entry.object, theme: theme,
                    placeholder: placeholders[entry.object.id],
                    in: canvasSize,
                    maskedBy: wiring.maskedBy[entry.object.id],
                    matteGroup: wiring.mattes.contains(entry.object.id) ? entry.object.id : nil,
                    music: music,
                    animationSteps: animationSteps[entry.object.id] ?? []
                ) {
                    item.animationContext = animationContext
                    scene.addItem(item, to: .slide)
                }
            }
        }
        return scene
    }

    public struct MusicContext: Sendable, Equatable {
        public var musicKey: String?
        public var displayKey: String?

        public init(musicKey: String?, displayKey: String?) {
            self.musicKey = musicKey
            self.displayKey = displayKey
        }

        public init?(_ presentation: Presentation?) {
            guard let presentation,
                  presentation.musicKey != nil || presentation.displayKey != nil
            else { return nil }
            self.init(musicKey: presentation.musicKey, displayKey: presentation.displayKey)
        }
    }

    public struct ComposedEntry: Identifiable {
        public let object: SlideObject

        public let fromTheme: Bool

        public var id: String { fromTheme ? "theme-\(object.id)" : object.id }
    }

    public static func composedStack(
        for objects: [SlideObject],
        in template: Slide?
    ) -> [ComposedEntry] {
        guard let template else { return objects.map { ComposedEntry(object: $0, fromTheme: false) } }
        let placeholders = placeholderAssignments(for: objects, in: template)
        var stack: [ComposedEntry] = []
        var bound = Set<String>()
        for templateObject in template.objects {
            if templateObject.objectKind == .text {
                var boundAny = false
                for object in objects where placeholders[object.id]?.id == templateObject.id {
                    bound.insert(object.id)
                    boundAny = true
                    stack.append(ComposedEntry(object: object, fromTheme: false))
                }

                if !boundAny, templateObject.textLink != nil {
                    stack.append(ComposedEntry(object: templateObject, fromTheme: true))
                }
            } else {
                stack.append(ComposedEntry(object: templateObject, fromTheme: true))
            }
        }
        for object in objects where !bound.contains(object.id) {
            stack.append(ComposedEntry(object: object, fromTheme: false))
        }
        return stack
    }

    public static func composedOrder(for objects: [SlideObject], in template: Slide?) -> [SlideObject] {
        composedStack(for: objects, in: template).filter { !$0.fromTheme }.map(\.object)
    }

    public static func fireActions(for slide: Slide) -> [SlideAction] {
        fireActions(for: slide, protected: protectedLayers(for: slide))
    }

    public static func protectedLayers(
        for slide: Slide, mediaLayer: (String) -> LayerKind? = { _ in nil }
    ) -> Set<LayerKind> {
        var protected: Set<LayerKind> = [.slide]
        if let background = slide.background, !background.mediaId.isEmpty {
            protected.insert(layerKind(background.layer))
        }
        for action in slide.actions ?? [] where action.kind == .fireMedia {
            if let id = action.mediaId, let layer = mediaLayer(id) {
                protected.insert(layer)
            }
        }
        return protected
    }

    public static func fireActions(
        for slide: Slide, protected: Set<LayerKind>
    ) -> [SlideAction] {
        guard let actions = slide.actions else { return [] }
        return actions.filter { action in
            guard action.kind == .clearLayer, !waitsBeforeFiring(action),
                  let layer = action.layer.flatMap(LayerKind.init(rawValue:))
            else { return true }
            return !protected.contains(layer)
        }
    }

    public static func fireActions(forMedia item: MediaItem, on layer: LayerKind) -> [SlideAction] {
        guard let actions = item.actions else { return [] }
        return actions.filter { action in
            guard action.kind == .clearLayer, !waitsBeforeFiring(action),
                  let target = action.layer.flatMap(LayerKind.init(rawValue:))
            else { return true }
            return target != layer
        }
    }

    public static func waitsBeforeFiring(_ action: SlideAction) -> Bool {
        (action.delaySeconds ?? 0) > 0
    }

    public static func delaySchedule(_ actions: [SlideAction])
        -> (immediate: [SlideAction], delayed: [(delay: Double, actions: [SlideAction])])
    {
        var immediate: [SlideAction] = []
        var byDelay: [Double: [SlideAction]] = [:]
        for action in actions {
            if waitsBeforeFiring(action) {
                byDelay[action.delaySeconds ?? 0, default: []].append(action)
            } else {
                immediate.append(action)
            }
        }
        let delayed = byDelay.keys.sorted().map { (delay: $0, actions: byDelay[$0]!) }
        return (immediate, delayed)
    }

    public static func layerKind(_ layer: CueMediaLayer?) -> LayerKind {
        switch layer {
        case .none, .loopingVideos: .loopingVideos
        case .stillGraphics: .stillGraphics
        case .videos: .videos
        }
    }

    public static func fireMediaPosterIDs(
        slide: Slide,
        item: (String) -> (kind: MediaKind, classification: MediaClassification)?
    ) -> (below: [String], above: [String]) {
        var below: [String] = []
        var above: [String] = []
        for action in slide.actions ?? [] where action.kind == .fireMedia {
            guard let id = action.mediaId, !id.isEmpty,
                  !below.contains(id), !above.contains(id) else { continue }
            if let facts = item(id), facts.kind == .video, facts.classification != .background {
                above.append(id)
            } else {
                below.append(id)
            }
        }
        return (below, above)
    }

    public static func renderItem(
        for object: SlideObject,
        theme: Theme?,
        placeholder: SlideObject? = nil,
        in canvas: CGSize = canvasSize,
        music: MusicContext? = nil
    ) -> RenderItem {

        let object = SlideObjectNormalization.normalized(object)
        return RenderItem(
            id: object.id,
            frame: frame(for: object, placeholder: placeholder, in: canvas),
            content: content(for: object, theme: theme, placeholder: placeholder, music: music),
            rotationDegrees: object.rotationDegrees ?? 0,
            tilt: object.tilt ?? 0,
            swing: object.swing ?? 0,
            tiltPivot: tiltPivot(object.tiltPivot),
            keystoneTop: (object.keystoneTop ?? 100) / 100,
            keystoneBottom: (object.keystoneBottom ?? 100) / 100,
            keystoneStretch: object.keystoneMode == .stretch,
            skewX: object.skewX ?? 0,
            skewY: object.skewY ?? 0,
            flipHorizontal: object.flipHorizontal ?? false,
            flipVertical: object.flipVertical ?? false,
            opacity: object.opacity ?? 1,
            blendMode: blendMode(object.blendMode),
            effects: sceneEffects(object.effects),
            effectsApplyBelow: object.effectsApplyBelow ?? false
        )
    }

    public static func sceneEffects(_ effects: [Effect]?) -> [SceneEffect] {
        (effects ?? []).compactMap { effect in

            guard effect.enabled ?? true else { return nil }
            let opacity = min(max(effect.opacity ?? 1, 0), 1)
            guard opacity > 0.001 else { return nil }
            switch effect.effectKind {
            case .blur:
                let radius = effect.radius ?? 0
                return radius > 0
                    ? SceneEffect(kind: .blur(radius: radius), opacity: opacity) : nil
            case .colorAdjust:
                return SceneEffect(
                    kind: .colorAdjust(
                        brightness: effect.brightness ?? 0,
                        contrast: effect.contrast ?? 0,
                        saturation: effect.saturation ?? 1,
                        hue: effect.hue ?? 0
                    ),
                    opacity: opacity
                )

            case .hueRotate:
                let degrees = effect.amount ?? 90
                return abs(degrees) > 0.1
                    ? SceneEffect(kind: .hueRotate(degrees: degrees), opacity: opacity) : nil
            case .invert:
                return SceneEffect(kind: .invert, opacity: opacity)
            case .posterize:
                let levels = min(max(effect.amount ?? 6, 2), 32)
                return SceneEffect(kind: .posterize(levels: levels), opacity: opacity)
            case .pixelate:
                let size = effect.amount ?? 16
                return size >= 1
                    ? SceneEffect(kind: .pixelate(size: size), opacity: opacity) : nil
            case .vignette:
                let strength = min(max(effect.amount ?? 0.8, 0), 1.5)
                return strength > 0.001
                    ? SceneEffect(kind: .vignette(strength: strength), opacity: opacity) : nil

            case .warp:
                let amount = max(effect.amount ?? 40, 0)
                let scale = max(effect.scale ?? 240, 1)
                let speed = max(effect.speed ?? 0.5, 0)
                return amount >= 0.5
                    ? SceneEffect(kind: .warp(amount: amount, scale: scale, speed: speed), opacity: opacity)
                    : nil
            case .echo:
                let fade = min(max(effect.amount ?? 1, 0), 20)
                return fade > 0.01
                    ? SceneEffect(kind: .echo(fade: fade), opacity: opacity) : nil
            case .scatter:
                let amount = max(effect.amount ?? 8, 0)
                let size = max(effect.scale ?? 1, 1)
                let speed = min(max(effect.speed ?? 1, 0), 1)
                let smooth = min(max(effect.smooth ?? 0, 0), 1)
                return amount >= 0.5
                    ? SceneEffect(
                        kind: .scatter(amount: amount, size: size, speed: speed, smooth: smooth),
                        opacity: opacity
                    )
                    : nil
            case .stainedGlass:
                let cell = min(max(effect.scale ?? 80, 4), 2000)
                let leading = max(effect.radius ?? 3, 0)
                let jitter = min(max(effect.amount ?? 0.8, 0), 1)
                let speed = max(effect.speed ?? 0, 0)
                return SceneEffect(
                    kind: .stainedGlass(cellSize: cell, leading: leading, jitter: jitter, speed: speed),
                    opacity: opacity
                )
            case .grain:
                let amount = min(max(effect.amount ?? 0.3, 0), 1)
                let size = max(effect.scale ?? 1, 1)
                let speed = min(max(effect.speed ?? 1, 0), 1)
                return amount > 0.001
                    ? SceneEffect(kind: .grain(amount: amount, size: size, speed: speed), opacity: opacity)
                    : nil
            case .ghostTrails:
                let fade = min(max(effect.fade ?? 1.5, 0), 20)
                let drift = max(effect.amount ?? 6, 0)
                let scale = max(effect.scale ?? 160, 1)
                let speed = max(effect.speed ?? 0.5, 0)
                return fade > 0.01
                    ? SceneEffect(
                        kind: .ghostTrails(fade: fade, drift: drift, scale: scale, speed: speed),
                        opacity: opacity
                    )
                    : nil
            }
        }
    }

    public static func renderItems(
        for object: SlideObject,
        theme: Theme?,
        placeholder: SlideObject? = nil,
        in canvas: CGSize = canvasSize,
        baseID: String? = nil,
        maskedBy: (matte: String, out: Bool)? = nil,
        matteGroup: String? = nil,
        music: MusicContext? = nil,
        animationSteps: [SceneAnimationStep] = []
    ) -> [RenderItem] {

        guard object.hidden != true else { return [] }

        let object = SlideObjectNormalization.normalized(object)
        var primary = renderItem(for: object, theme: theme, placeholder: placeholder, in: canvas, music: music)

        primary.visibility = VisibilityRules.itemVisibility(for: object)
        let id = baseID ?? object.id
        primary.id = id

        primary.maskedBy = maskedBy?.matte
        primary.maskOut = maskedBy?.out ?? false
        primary.matteGroup = matteGroup

        primary.animationSteps = animationSteps
        let stateItems: [String: [RenderItem]] = Dictionary(uniqueKeysWithValues: animationSteps.compactMap { step -> (String, [RenderItem])? in
            guard let stateObject = buildStateObject(object, for: step, animationSteps: object.animationSteps) else { return nil }

            var state = SlideObjectNormalization.normalized(stateObject)
            state.id = object.id
            state.animationSteps = nil
            let items = renderItems(for: state, theme: theme, placeholder: placeholder, in: canvas, baseID: id, music: music)
            return (step.id, items)
        })
        func stampStates(_ item: inout RenderItem) {
            guard !stateItems.isEmpty else { return }
            let wantsText = item.id.hasSuffix("::text")
            item.animationSteps = item.animationSteps.map { step in
                var step = step
                guard let items = stateItems[step.id],
                      let match = items.first(where: { $0.id.hasSuffix("::text") == wantsText }) else { return step }
                if step.kind == .morph { step.toItem = match } else { step.fromItem = match }
                return step
            }
        }
        stampStates(&primary)
        guard object.objectKind == .shape,
              !object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [primary] }

        var text = styledText(for: object, theme: theme, placeholder: nil, music: music)
        let placement = object.shapeTextPlacement ?? .inside
        switch placement {
        case .inside:

            text.pathData = nil
            text.pathReversed = false
        case .edgeOutside, .edgeInside:

            let itemFrame = frame(for: object, placeholder: placeholder, in: canvas)
            guard let outline = ShapeOutlineSVG.pathData(
                shapeKind: object.shapeKind,
                frame: itemFrame.size,
                cornerRadius: object.shapeTextCornerRadius ?? object.cornerRadius,
                customPathData: object.pathData,
                placement: placement
            ) else {
                return [primary]
            }
            text.pathData = outline
            text.pathReversed = placement == .edgeInside

            text.pathOffset = (object.textStyle?.pathOffset ?? 0)
                * (placement == .edgeInside ? -1 : 1)
        }

        let textItem = RenderItem(
            id: "\(id)::text",
            frame: primary.frame,
            content: .text(text),
            rotationDegrees: primary.rotationDegrees,
            tilt: primary.tilt,
            swing: primary.swing,
            tiltPivot: primary.tiltPivot,
            keystoneTop: primary.keystoneTop,
            keystoneBottom: primary.keystoneBottom,
            keystoneStretch: primary.keystoneStretch,
            skewX: primary.skewX,
            skewY: primary.skewY,
            flipHorizontal: primary.flipHorizontal,
            flipVertical: primary.flipVertical,
            opacity: primary.opacity,
            blendMode: primary.blendMode,
            maskedBy: primary.maskedBy,
            maskOut: primary.maskOut,
            matteGroup: primary.matteGroup,

            effects: primary.effectsApplyBelow ? [] : primary.effects,
            effectsApplyBelow: false,
            visibility: primary.visibility,
            animationSteps: primary.animationSteps
        )
        var stampedText = textItem
        stampStates(&stampedText)
        return [primary, stampedText]
    }

    static func buildStateObject(_ object: SlideObject, for step: SceneAnimationStep, animationSteps: [AnimationStep]?) -> SlideObject? {
        guard let source = animationSteps?.first(where: { $0.id == step.id }) else { return nil }
        switch step.kind {
        case .morph: return source.toObject
        case .enter: return source.fromObject
        default: return nil
        }
    }

    public static func maskWiring(
        for objects: [SlideObject]
    ) -> (maskedBy: [String: (matte: String, out: Bool)], mattes: Set<String>) {
        let ids = Set(objects.map(\.id))
        var maskedBy: [String: (matte: String, out: Bool)] = [:]
        var mattes: Set<String> = []
        for object in objects {
            guard let matteID = object.maskObjectId, !matteID.isEmpty,
                  matteID != object.id, ids.contains(matteID)
            else { continue }
            maskedBy[object.id] = (matteID, object.maskMode == .out)
            mattes.insert(matteID)
        }
        return (maskedBy, mattes)
    }

    public static func frame(
        for object: SlideObject, placeholder: SlideObject? = nil,
        in canvas: CGSize = canvasSize
    ) -> CGRect {
        let fallback: CGRect = if object.objectKind == .text,
                                  let placeholder, placeholder.id != object.id {
            frame(for: placeholder, in: canvas)
        } else {
            defaultFrame(for: object.objectKind, in: canvas)
        }
        return CGRect(
            x: object.x ?? fallback.origin.x,
            y: object.y ?? fallback.origin.y,
            width: object.width ?? fallback.width,
            height: object.height ?? fallback.height
        )
    }

    public static func liveInputEngineID(_ object: SlideObject) -> String {
        if let itemId = object.liveInputId, !itemId.isEmpty {
            return "input::item::\(itemId)"
        }
        let kind = object.captureSourceKind == .ndi ? "ndi" : "camera"
        return "input::\(kind)::\(object.captureSourceId ?? "")"
    }

    public static func screenMirrorEngineID(screenId: String) -> String {
        "screen::\(screenId)"
    }

    public static func fillScreenMirrorID(_ object: SlideObject) -> String? {
        let object = SlideObjectNormalization.normalized(object)
        guard object.objectKind == .shape,
              let fill = object.fill, fill.fillKind == .media,
              let screenId = fill.screenSourceId, !screenId.isEmpty
        else { return nil }
        return screenMirrorEngineID(screenId: screenId)
    }

    private static func content(
        for object: SlideObject,
        theme: Theme?,
        placeholder: SlideObject? = nil,
        music: MusicContext? = nil
    ) -> ItemContent {

        let object = SlideObjectNormalization.normalized(object)
        return switch object.objectKind {
        case .text:
            .text(styledText(for: object, theme: theme, placeholder: placeholder, music: music))
        case .shape, .media, .liveInput:

            .shape(shapeStyle(for: object))
        }
    }

    static func styledText(
        for object: SlideObject,
        theme: Theme?,
        placeholder: SlideObject? = nil,
        music: MusicContext? = nil
    ) -> StyledText {
        let own = object.textStyle

        let base = (placeholder?.id == object.id) ? nil : placeholder?.textStyle
        func resolve<T>(_ key: KeyPath<TextStyle, T?>) -> T? {
            own?[keyPath: key] ?? base?[keyPath: key]
        }
        return StyledText(
            string: object.text,
            fontName: resolve(\.fontName) ?? theme?.fontFamily ?? "HelveticaNeue-Bold",
            fontSize: resolve(\.fontSize) ?? theme?.fontSize ?? 96,
            color: resolve(\.colorHex).flatMap(ColorHex.color)
                ?? theme.flatMap { ColorHex.color($0.textColorHex) }
                ?? .white,
            alignment: alignment(resolve(\.horizontalAlignment)),
            shadow: resolve(\.shadow).map(sceneShadow),
            tracking: resolve(\.tracking) ?? 0,
            lineHeightMultiple: resolve(\.lineHeightMultiple) ?? 1,
            verticalAlignment: verticalAlignment(resolve(\.verticalAlignment)),
            transform: resolve(\.textTransform) == .uppercase ? .uppercase : .none,
            tabularFigures: resolve(\.tabularFigures) ?? false,
            autoShrink: resolve(\.autoShrink) ?? false,
            minFontSize: resolve(\.minFontSize) ?? StyledText.defaultMinFontSize,
            keepLinesWhole: resolve(\.keepLinesWhole) ?? false,
            balancedWrap: resolve(\.balancedWrap) ?? false,
            outline: resolve(\.outline).flatMap { outline in
                ColorHex.color(outline.colorHex).map { TextOutline(color: $0, width: outline.width) }
            },

            lineOverrides: (own?.lineStyles ?? []).map { line in
                TextLineOverride(
                    lineIndex: line.lineIndex,
                    fontName: line.fontName,
                    fontSize: line.fontSize,
                    color: line.colorHex.flatMap(ColorHex.color),
                    tracking: line.tracking,
                    firstLineIndent: line.firstLineIndent,
                    leftIndent: line.leftIndent,
                    rightIndent: line.rightIndent
                )
            },
            fill: resolve(\.fill).flatMap(textFill),
            lineFill: resolve(\.lineFill).flatMap(lineFillStyle),

            pathData: resolve(\.pathData),
            tickerSpeed: resolve(\.tickerSpeed) ?? 0,

            pathReversed: resolve(\.pathSide) == .inside,
            pathOffset: (resolve(\.pathOffset) ?? 0)
                * (resolve(\.pathSide) == .inside ? -1 : 1),
            tickerRepeat: resolve(\.tickerRepeat) ?? 0,
            tickerLeftToRight: resolve(\.tickerDirection) == .leftToRight,
            tickerStream: resolve(\.tickerStream) ?? false,
            tickerGap: resolve(\.tickerGap) ?? 0,
            tickerSeparator: resolve(\.tickerSeparator) ?? "",
            wordSpacing: resolve(\.wordSpacing) ?? 0,
            chords: chordRuns(for: object, showChords: resolve(\.showChords) ?? false,
                              notation: resolve(\.chordNotation) ?? .chords,
                              pathData: resolve(\.pathData), music: music),
            chordColor: resolve(\.chordColorHex).flatMap(ColorHex.color),

            insetTop: resolve(\.insetTop) ?? 0,
            insetLeft: resolve(\.insetLeft) ?? 0,
            insetBottom: resolve(\.insetBottom) ?? 0,
            insetRight: resolve(\.insetRight) ?? 0,
            firstLineIndent: resolve(\.firstLineIndent) ?? 0,
            leftIndent: resolve(\.leftIndent) ?? 0,
            rightIndent: resolve(\.rightIndent) ?? 0,
            paragraphSpacing: resolve(\.paragraphSpacing) ?? 0,
            underline: resolve(\.underline) ?? false,
            strikethrough: resolve(\.strikethrough) ?? false,

            styleRuns: (object.styleRuns ?? []).map { run in
                StyleRun(
                    line: run.line, column: run.column, length: run.length,
                    underline: run.underline, strikethrough: run.strikethrough,
                    fontName: run.fontName, fontSize: run.fontSize,
                    color: run.colorHex.flatMap(ColorHex.color),
                    highlightColor: run.highlightColorHex.flatMap(ColorHex.color),
                    tracking: run.tracking
                )
            },

            tickerRamp: sceneRamp(resolve(\.tickerRamp)),
            scroll: resolve(\.scroll).flatMap(blockScroll)
        )
    }

    static func sceneRamp(_ ramp: AnimationRamp?) -> SceneAnimationRamp {
        switch ramp {
        case .in?: .easeIn
        case .out?: .easeOut
        case .both?: .easeInOut
        case .none?, nil: .none
        }
    }

    static func blockScroll(_ scroll: BlockScroll) -> SceneBlockScroll? {
        guard scroll.speed > 0 else { return nil }
        let axis: SceneBlockScroll.Axis = switch scroll.axis ?? .up {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
        return SceneBlockScroll(
            axis: axis, speed: scroll.speed, passes: max(scroll.passes ?? 0, 0),
            ramp: sceneRamp(scroll.ramp), restAtEnd: scroll.restAtEnd ?? false,
            fadeTowardTop: min(max(scroll.fadeTowardTop ?? 0, 0), 1)
        )
    }

    static func chordRuns(
        for object: SlideObject,
        showChords: Bool,
        notation: ChordNotation,
        pathData: String?,
        music: MusicContext?
    ) -> [ChordRun] {
        guard showChords, let placements = object.chords, !placements.isEmpty,
              pathData == nil
        else { return [] }
        let display = object.textLink != nil
            ? placements
            : ChordMath.displayPlacements(
                placements,
                musicKey: music?.musicKey, displayKey: music?.displayKey,
                notation: notation
            )
        return display.map { ChordRun(line: $0.line, column: $0.column, symbol: $0.symbol) }
    }

    static func lineFillStyle(_ lineFill: TextLineFill) -> TextLineFillStyle? {
        guard let fill = textFill(lineFill.fill), fill != SceneFill.none else { return nil }
        let widthMode: TextLineFillStyle.WidthMode = switch lineFill.widthMode ?? .fullWidth {
        case .fullWidth: .fullWidth
        case .lineWidth: .lineWidth
        case .maxLineWidth: .maxLineWidth
        }
        return TextLineFillStyle(
            fill: fill,
            widthMode: widthMode,
            verticalPadding: lineFill.verticalPadding ?? 0,
            horizontalPadding: lineFill.horizontalPadding ?? 0,
            verticalOffset: lineFill.verticalOffset ?? 0,
            horizontalOffset: lineFill.horizontalOffset ?? 0,
            cornerRadius: lineFill.cornerRadius ?? 0
        )
    }

    static func textFill(_ fill: ObjectFill) -> SceneFill? {
        switch fill.fillKind {
        case .none:
            return SceneFill.none
        case .solid:
            return fill.colorHex.flatMap(ColorHex.color).map(SceneFill.solid)
        case .linearGradient:
            let stops = (fill.gradientStops ?? []).compactMap { stop in
                ColorHex.color(stop.colorHex).map { SceneGradientStop(color: $0, position: stop.position) }
            }
            guard stops.count >= 2 else { return nil }
            return .linearGradient(angleDegrees: fill.gradientAngleDegrees ?? 0, stops: stops)
        case .media:
            return nil
        }
    }

    static func shapeStyle(for object: SlideObject) -> ShapeStyle {
        let kind: SceneShapeKind = switch object.shapeKind ?? .rectangle {
        case .rectangle: .rectangle
        case .roundedRectangle: .roundedRectangle(cornerRadius: object.cornerRadius ?? 0)
        case .ellipse: .ellipse
        case .path: .path(object.pathData ?? "")
        }
        return ShapeStyle(
            kind: kind,
            fill: fill(object.fill),
            stroke: (object.stroke).flatMap { stroke in
                ColorHex.color(stroke.colorHex).map {
                    SceneStroke(color: $0, width: stroke.width, dash: dash(stroke.dashKind))
                }
            },
            shadow: (object.shadow).map(sceneShadow)
        )
    }

    static func dash(_ kind: StrokeDashKind?) -> SceneStroke.Dash {
        switch kind {
        case .dashed: .dashed
        case .dotted: .dotted
        case .solid, nil: .solid
        }
    }

    static func fill(_ fill: ObjectFill?) -> SceneFill {

        guard let fill else { return .solid(.white) }
        switch fill.fillKind {
        case .none:
            return .none
        case .solid:
            return .solid(fill.colorHex.flatMap(ColorHex.color) ?? .white)
        case .linearGradient:
            let stops = (fill.gradientStops ?? []).compactMap { stop in
                ColorHex.color(stop.colorHex).map { SceneGradientStop(color: $0, position: stop.position) }
            }
            guard stops.count >= 2 else { return .solid(.white) }
            return .linearGradient(angleDegrees: fill.gradientAngleDegrees ?? 0, stops: stops)
        case .media:

            if let screenId = fill.screenSourceId, !screenId.isEmpty {
                return .media(
                    id: screenMirrorEngineID(screenId: screenId),
                    scaleMode: scaleMode(fill.mediaScaleMode))
            }
            if let id = fillInputEngineID(fill) {
                return .media(id: id, scaleMode: scaleMode(fill.mediaScaleMode))
            }
            guard let id = fill.mediaId, !id.isEmpty else { return .none }
            return .media(
                id: id, scaleMode: scaleMode(fill.mediaScaleMode),
                sourceRect: sourceRect(fill.mediaSourceRect))
        }
    }

    public static func fillMediaID(_ object: SlideObject) -> String? {
        let object = SlideObjectNormalization.normalized(object)
        guard object.objectKind == .shape,
              let fill = object.fill, fill.fillKind == .media,
              fill.screenSourceId?.isEmpty != false,
              fillInputEngineID(fill) == nil,
              let id = fill.mediaId, !id.isEmpty
        else { return nil }
        return id
    }

    public static func fillLiveInputID(_ object: SlideObject) -> String? {
        let object = SlideObjectNormalization.normalized(object)
        guard object.objectKind == .shape,
              let fill = object.fill, fill.fillKind == .media,
              fill.screenSourceId?.isEmpty != false,

              fill.liveInputId?.isEmpty == false || fill.captureSourceId?.isEmpty == false
        else { return nil }
        return fillInputEngineID(fill)
    }

    private static func fillInputEngineID(_ fill: ObjectFill) -> String? {
        if let itemId = fill.liveInputId, !itemId.isEmpty {
            return "input::item::\(itemId)"
        }

        guard fill.captureSourceKind != nil || fill.captureSourceId?.isEmpty == false
        else { return nil }
        let kind = fill.captureSourceKind == .ndi ? "ndi" : "camera"
        return "input::\(kind)::\(fill.captureSourceId ?? "")"
    }

    public static func mediaWants(for objects: [SlideObject]) -> [String: Bool?] {

        let objects = SlideObjectNormalization.normalized(objects)
        var wanted: [String: Bool?] = [:]
        for object in objects {
            if let id = fillMediaID(object) ?? fillLiveInputID(object), wanted[id] == nil {
                wanted.updateValue(object.fill?.loops, forKey: id)
            }
        }

        for object in objects {
            if let id = fillScreenMirrorID(object), wanted[id] == nil {
                wanted.updateValue(nil, forKey: id)
            }
        }
        return wanted
    }

    private static func sceneShadow(_ shadow: ObjectShadow) -> TextShadow {
        TextShadow(
            color: ColorHex.color(shadow.colorHex) ?? SceneColor(red: 0, green: 0, blue: 0, alpha: 0.5),
            blurRadius: shadow.blurRadius,
            offsetX: shadow.offsetX,
            offsetY: shadow.offsetY
        )
    }

    private static func blendMode(_ mode: BlendMode?) -> SceneBlendMode {
        switch mode {
        case .none, .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .add: .add
        }
    }

    private static func tiltPivot(_ pivot: TiltPivot?) -> SceneTiltPivot {
        switch pivot {
        case .none, .center: .center
        case .top: .top
        case .bottom: .bottom
        }
    }

    private static func scaleMode(_ mode: MediaScaleMode?) -> SceneMediaScaleMode {
        switch mode {
        case .none, .fill: .fill
        case .fit: .fit
        case .stretch: .stretch
        }
    }

    private static func sourceRect(_ rect: MediaSourceRect?) -> SceneSourceRect? {
        guard let rect, rect.width > 0, rect.height > 0 else { return nil }
        if rect.x == 0, rect.y == 0, rect.width == 1, rect.height == 1 { return nil }
        return SceneSourceRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private static func alignment(_ alignment: TextHorizontalAlignment?) -> SceneTextAlignment {
        switch alignment {
        case .none, .center: .center
        case .left: .left
        case .right: .right
        }
    }

    private static func verticalAlignment(_ alignment: TextVerticalAlignment?) -> SceneTextVerticalAlignment {
        switch alignment {
        case .none, .middle: .middle
        case .top: .top
        case .bottom: .bottom
        }
    }
}
