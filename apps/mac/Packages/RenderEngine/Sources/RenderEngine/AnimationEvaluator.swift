import CoreGraphics
import Foundation

public struct AnimationMotion: Equatable, Sendable {
    public struct Wipe: Equatable, Sendable {

        public var edge: SceneAnimationEdge

        public var progress: Double

        public var feather: Double

        public init(edge: SceneAnimationEdge, progress: Double, feather: Double) {
            self.edge = edge
            self.progress = progress
            self.feather = feather
        }
    }

    public var translate: CGVector = .zero

    public var scale: Double = 1

    public var scaleY: Double?

    public var tilt: Double = 0

    public var swing: Double = 0

    public var tiltPivot: SceneTiltPivot = .center

    public var keystoneTop: Double = 1
    public var keystoneBottom: Double = 1

    public var keystoneStretch: Bool = false

    public var skewX: Double = 0
    public var skewY: Double = 0
    public var wipe: Wipe?

    public var clip: Clip?

    public struct Clip: Equatable, Sendable {
        public var minU: Double, maxU: Double, minV: Double, maxV: Double

        public var featherMinU: Double = 0, featherMaxU: Double = 0
        public var featherMinV: Double = 0, featherMaxV: Double = 0

        public init(minU: Double = 0, maxU: Double = 1, minV: Double = 0, maxV: Double = 1,
                    featherMinU: Double = 0, featherMaxU: Double = 0,
                    featherMinV: Double = 0, featherMaxV: Double = 0) {
            self.minU = minU; self.maxU = maxU; self.minV = minV; self.maxV = maxV
            self.featherMinU = featherMinU; self.featherMaxU = featherMaxU
            self.featherMinV = featherMinV; self.featherMaxV = featherMaxV
        }
    }

    public init(
        translate: CGVector = .zero, scale: Double = 1, scaleY: Double? = nil,
        tilt: Double = 0, swing: Double = 0, tiltPivot: SceneTiltPivot = .center,
        keystoneTop: Double = 1, keystoneBottom: Double = 1, keystoneStretch: Bool = false,
        skewX: Double = 0, skewY: Double = 0,
        wipe: Wipe? = nil, clip: Clip? = nil
    ) {
        self.translate = translate
        self.scale = scale
        self.scaleY = scaleY
        self.tilt = tilt
        self.swing = swing
        self.tiltPivot = tiltPivot
        self.keystoneTop = keystoneTop
        self.keystoneBottom = keystoneBottom
        self.keystoneStretch = keystoneStretch
        self.skewX = skewX
        self.skewY = skewY
        self.wipe = wipe
        self.clip = clip
    }

    public var usesStretchKeystone: Bool {
        keystoneStretch && (keystoneTop != 1 || keystoneBottom != 1)
    }

    public static let identity = AnimationMotion()

    public var isIdentity: Bool {
        translate == .zero && scale == 1 && (scaleY ?? 1) == 1 && tilt == 0 && swing == 0
            && keystoneTop == 1 && keystoneBottom == 1 && skewX == 0 && skewY == 0 && wipe == nil
            && clip == nil
    }
}

public struct ResolvedBuildScene: Equatable, Sendable {
    public var scene: RenderScene
    public var motions: [String: AnimationMotion]

    public init(scene: RenderScene, motions: [String: AnimationMotion] = [:]) {
        self.scene = scene
        self.motions = motions
    }
}

public enum AnimationEvaluator {

    public static func resolve(_ scene: RenderScene, hostTime: Double) -> ResolvedBuildScene {
        var out = scene
        var motions: [String: AnimationMotion] = [:]

        let pushState = VideoPushEvaluator.activeState(scene, now: hostTime)
        let pushTransform = pushState.map { VideoPushEvaluator.transform(canvas: scene.canvasSize, state: $0) }
        let backdrop: VideoPushEvaluator.Transform? = pushState.flatMap { state in
            state.push.mode != .blurBackground && state.push.backdrop
                ? VideoPushEvaluator.backdropTransform(canvas: scene.canvasSize, state: state) : nil
        }
        for layerIndex in out.layers.indices {
            let pushed = VideoPushEvaluator.pushedLayers.contains(out.layers[layerIndex].kind)
            var items: [RenderItem] = []
            items.reserveCapacity(out.layers[layerIndex].items.count)
            for item in out.layers[layerIndex].items {
                for var resolved in resolve(item, canvasSize: scene.canvasSize, hostTime: hostTime) {
                    if pushed, let transform = pushTransform {

                        if let backdrop, resolved.item.matteGroup == nil {
                            var clone = VideoPushEvaluator.apply(backdrop, to: resolved)
                            clone.item.id = "\(resolved.item.id)#pushbg"
                            clone.item.maskedBy = nil
                            clone.item.opacity = resolved.item.opacity * min(pushState!.amount * 2, 1)
                            items.append(clone.item)
                            if !clone.motion.isIdentity { motions[clone.item.id] = clone.motion }
                        }
                        resolved = VideoPushEvaluator.apply(transform, to: resolved)
                    }
                    items.append(resolved.item)
                    if !resolved.motion.isIdentity {
                        motions[resolved.item.id] = resolved.motion
                    }
                }
            }
            out.layers[layerIndex].items = items
        }
        return ResolvedBuildScene(scene: out, motions: motions)
    }

    public struct ResolvedItem: Equatable, Sendable {
        public var item: RenderItem
        public var motion: AnimationMotion
    }

    public static func resolve(_ item: RenderItem, canvasSize: CGSize, hostTime: Double) -> [ResolvedItem] {
        guard case .text(let text) = item.content, let scroll = text.scroll, scroll.speed > 0,
              text.pathData == nil
        else { return resolveBuilds(item, canvasSize: canvasSize, hostTime: hostTime) }

        if item.animationContext?.frozenHostTime == AnimationContext.settled.frozenHostTime {
            var still = item
            var content = text
            content.scroll = nil
            still.content = .text(content)
            return resolveBuilds(still, canvasSize: canvasSize, hostTime: hostTime)
        }

        let anchor = item.tickerAnchorHostTime ?? item.animationContext?.anchorHostTime
        let now = item.animationContext?.frozenHostTime ?? hostTime
        let elapsed = anchor.map { now - $0 } ?? now
        let blockHeight = TextRasterizer.blockHeight(for: text, sceneWidth: item.frame.width)
        guard let rolled = BlockScrollRoll.resolve(
            item, text: text, scroll: scroll, blockHeight: blockHeight, elapsed: elapsed, anchored: anchor != nil
        ) else { return [] }
        return resolveBuilds(rolled.item, canvasSize: canvasSize, hostTime: hostTime).map { resolved in
            var out = resolved
            out.motion.translate.dx += rolled.translate.dx
            out.motion.translate.dy += rolled.translate.dy
            out.motion.clip = rolled.clip
            return out
        }
    }

    static func resolveBuilds(_ item: RenderItem, canvasSize: CGSize, hostTime: Double) -> [ResolvedItem] {
        let staticTilt = item.tilt

        let still = AnimationMotion(
            tilt: staticTilt, swing: item.swing, tiltPivot: item.tiltPivot,
            keystoneTop: item.keystoneTop, keystoneBottom: item.keystoneBottom,
            keystoneStretch: item.keystoneStretch, skewX: item.skewX, skewY: item.skewY
        )
        guard !item.animationSteps.isEmpty, item.animationContext != nil else {

            return [ResolvedItem(item: item, motion: still)]
        }
        let context = item.animationContext
        let visibility = AnimationTimeline.visibility(of: item.animationSteps, context: context, now: hostTime)
        if visibility.hidesWholeObject {

            return []
        }

        let morphed = morphState(of: item, context: context, now: hostTime)
        var base = morphed.base
        var partner = morphed.partner
        let morphMotion = morphed.motion

        let wholeSteps = item.animationSteps.filter { $0.targetsWholeObject }
        var whole = animate(
            steps: wholeSteps, context: context, now: hostTime,
            frame: base.frame, canvasSize: canvasSize
        )
        whole.motion.tilt += staticTilt + morphMotion.tilt
        whole.motion.swing += base.swing + morphMotion.swing
        whole.motion.tiltPivot = base.tiltPivot
        whole.motion.keystoneTop = base.keystoneTop
        whole.motion.keystoneBottom = base.keystoneBottom
        whole.motion.keystoneStretch = base.keystoneStretch
        whole.motion.skewX += base.skewX
        whole.motion.skewY += base.skewY
        whole.motion.translate.dx += morphMotion.translate.dx
        whole.motion.translate.dy += morphMotion.translate.dy
        let uniform = whole.motion.scale 
        whole.motion.scale = uniform * morphMotion.scale
        whole.motion.scaleY = morphMotion.scaleY.map { uniform * $0 }
        base.opacity = min(max(base.opacity * whole.opacity, 0), 1)
        if partner != nil { partner!.opacity = min(max(partner!.opacity * whole.opacity, 0), 1) }
        if !whole.effects.isEmpty {
            base.effects = whole.effects + base.effects
            if partner != nil { partner!.effects = whole.effects + partner!.effects }
        }

        if case .shape(var style) = base.content,
           let (step, progress) = runningStep(.draw, in: wholeSteps, context: context, now: hostTime) {
            let r = step.kind == .enter ? progress : 1 - progress
            style.strokeTrim = ShapeStyle.StrokeTrim(
                start: step.drawStart, length: quantize(r), reversed: step.reverse
            )
            style.fillOpacity = quantize(min(max((r - 0.6) / 0.4, 0), 1))
            base.content = .shape(style)
        }

        guard case .text(let text) = base.content else {
            return withPartner([ResolvedItem(item: base, motion: whole.motion)], partner, whole.motion)
        }

        var typeRuns: [StyleRun] = []
        var typingRanges: Set<SceneAnimationRange> = []
        for step in item.animationSteps where step.animation == .type {
            guard case .running(let progress) = AnimationTimeline.phase(of: step, context: context, now: hostTime) else { continue }
            let r = step.kind == .enter ? progress : 1 - progress
            let targets = step.ranges ?? wholeRanges(of: text.string)
            typeRuns += Self.typeRuns(revealing: r, of: targets, in: text.string, caret: step.cursor, reverse: step.reverse)
            for range in targets { typingRanges.insert(range) }
        }
        let rangeSteps = item.animationSteps.filter { !$0.targetsWholeObject }
        guard !rangeSteps.isEmpty || !typeRuns.isEmpty else {
            return withPartner([ResolvedItem(item: base, motion: whole.motion)], partner, whole.motion)
        }

        var results: [ResolvedItem] = []
        var hiddenOnBase: [SceneAnimationRange] = visibility.hiddenRanges
        let placeholders = Set(visibility.placeholderRanges)
        var pieceIndex = 0
        for step in rangeSteps where step.animation != .type {
            let phase = AnimationTimeline.phase(of: step, context: context, now: hostTime)
            guard case .running = phase, let ranges = step.ranges else { continue }

            var pieceText = text
            pieceText.styleRuns = text.styleRuns.filter { $0.hidden != true }
                + complementRuns(of: ranges, in: text.string)
            pieceText.chords = []
            var piece = base
            piece.id = "\(item.id)#step\(pieceIndex)"
            pieceIndex += 1
            piece.content = .text(pieceText)
            piece.matteGroup = nil 
            let animated = animate(
                steps: [step], context: context, now: hostTime,
                frame: item.frame, canvasSize: canvasSize
            )
            piece.opacity = min(max(base.opacity * animated.opacity, 0), 1)
            if !animated.effects.isEmpty { piece.effects = animated.effects + piece.effects }
            var motion = whole.motion
            motion.translate.dx += animated.motion.translate.dx
            motion.translate.dy += animated.motion.translate.dy
            motion.scale *= animated.motion.scale
            motion.wipe = animated.motion.wipe ?? motion.wipe
            results.append(ResolvedItem(item: piece, motion: motion))

            hiddenOnBase.append(contentsOf: ranges)
        }
        var baseText = text
        var runs = text.styleRuns
        for range in hiddenOnBase where !typingRanges.contains(range) {
            runs.append(StyleRun(
                line: range.line, column: range.column, length: range.length,
                hidden: true,
                placeholderUnderline: placeholders.contains(range) ? true : nil
            ))
        }
        runs += typeRuns
        baseText.styleRuns = runs
        base.content = .text(baseText)
        results.insert(ResolvedItem(item: base, motion: whole.motion), at: 0)
        return withPartner(results, partner, whole.motion)
    }

    private static func withPartner(_ items: [ResolvedItem], _ partner: RenderItem?, _ motion: AnimationMotion) -> [ResolvedItem] {
        guard let partner else { return items }
        return items + [ResolvedItem(item: partner, motion: motion)]
    }

    struct MorphState {
        var base: RenderItem

        var partner: RenderItem?
        var motion = AnimationMotion()
    }

    static func morphState(of item: RenderItem, context: AnimationContext?, now: Double) -> MorphState {
        var current = item
        for step in item.animationSteps {
            if step.kind == .morph, let target = step.toItem {
                switch AnimationTimeline.phase(of: step, context: context, now: now) {
                case .done:
                    current = adopt(target, into: current)
                case .running(let p):
                    return blended(tween(from: current, to: adopt(target, into: current), progress: p, item: item), step: step, progress: p)
                case .pending:
                    continue
                }
            } else if step.kind == .enter, step.targetsWholeObject, let start = step.fromItem {
                if case .running(let p) = AnimationTimeline.phase(of: step, context: context, now: now) {
                    return blended(tween(from: adopt(start, into: current), to: current, progress: p, item: item), step: step, progress: p)
                }
            }
        }
        return MorphState(base: current)
    }

    static func blended(_ state: MorphState, step: SceneAnimationStep, progress p: Double) -> MorphState {
        let peak = quantize(1 - abs(2 * p - 1))
        let pass: SceneEffect?
        switch step.animation {
        case .blur: pass = SceneEffect(kind: .blur(radius: peak * step.amount))
        case .burn: pass = SceneEffect(kind: .burn(amount: peak * step.amount, phase: quantize(p)))
        case .glitch: pass = SceneEffect(kind: .glitch(amount: peak * step.amount, phase: quantize(p)))
        default: pass = nil
        }
        guard let pass, peak > 0.001 else { return state }
        var out = state
        out.base.effects = [pass] + out.base.effects
        if out.partner != nil { out.partner!.effects = [pass] + out.partner!.effects }
        return out
    }

    static func adopt(_ target: RenderItem, into item: RenderItem) -> RenderItem {
        var out = item
        out.frame = target.frame
        out.content = target.content
        out.rotationDegrees = target.rotationDegrees
        out.tilt = target.tilt
        out.swing = target.swing
        out.tiltPivot = target.tiltPivot
        out.keystoneTop = target.keystoneTop
        out.keystoneBottom = target.keystoneBottom
        out.keystoneStretch = target.keystoneStretch
        out.skewX = target.skewX
        out.skewY = target.skewY
        out.flipHorizontal = target.flipHorizontal
        out.flipVertical = target.flipVertical
        out.opacity = target.opacity
        out.blendMode = target.blendMode
        out.effects = target.effects
        out.effectsApplyBelow = target.effectsApplyBelow
        return out
    }

    static func tween(from start: RenderItem, to end: RenderItem, progress p: Double, item: RenderItem) -> MorphState {
        var base = start
        var motion = AnimationMotion()
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        let q = quantize(p)
        let frameLerp = CGRect(
            x: lerp(start.frame.minX, end.frame.minX), y: lerp(start.frame.minY, end.frame.minY),
            width: lerp(start.frame.width, end.frame.width), height: lerp(start.frame.height, end.frame.height)
        )
        let isText: Bool = { if case .text = start.content { return true } else { return false } }()
        if isText, start.frame.size != end.frame.size {

            let sx = start.frame.width > 0 ? frameLerp.width / start.frame.width : 1
            let sy = start.frame.height > 0 ? frameLerp.height / start.frame.height : 1
            motion.scale = sx
            motion.scaleY = sy
            motion.translate = CGVector(dx: frameLerp.midX - start.frame.midX, dy: frameLerp.midY - start.frame.midY)
        } else if isText {
            motion.translate = CGVector(dx: frameLerp.minX - start.frame.minX, dy: frameLerp.minY - start.frame.minY)
        } else {
            base.frame = CGRect(
                x: start.frame.minX + (end.frame.minX - start.frame.minX) * q,
                y: start.frame.minY + (end.frame.minY - start.frame.minY) * q,
                width: start.frame.width + (end.frame.width - start.frame.width) * q,
                height: start.frame.height + (end.frame.height - start.frame.height) * q
            )
        }
        base.rotationDegrees = lerp(start.rotationDegrees, end.rotationDegrees)
        base.tilt = lerp(start.tilt, end.tilt)
        base.swing = lerp(start.swing, end.swing)
        base.tiltPivot = p >= 0.5 ? end.tiltPivot : start.tiltPivot
        base.keystoneTop = lerp(start.keystoneTop, end.keystoneTop)
        base.keystoneBottom = lerp(start.keystoneBottom, end.keystoneBottom)
        base.keystoneStretch = p >= 0.5 ? end.keystoneStretch : start.keystoneStretch
        base.skewX = lerp(start.skewX, end.skewX)
        base.skewY = lerp(start.skewY, end.skewY)
        base.opacity = lerp(start.opacity, end.opacity)
        base.effects = tweenEffects(start.effects, end.effects, q)
        if start.flipHorizontal != end.flipHorizontal || start.flipVertical != end.flipVertical || start.blendMode != end.blendMode {
            if p >= 0.5 { base.flipHorizontal = end.flipHorizontal; base.flipVertical = end.flipVertical; base.blendMode = end.blendMode }
        }

        if let tweened = tweenContent(start.content, end.content, q) {
            base.content = tweened
            return MorphState(base: base, partner: nil, motion: motion)
        }

        var partner = base
        partner.id = "\(item.id)#morph"
        partner.content = end.content
        partner.matteGroup = nil
        partner.opacity = base.opacity * p
        base.opacity = base.opacity * (1 - p)
        return MorphState(base: base, partner: partner, motion: motion)
    }

    static func tweenContent(_ a: ItemContent, _ b: ItemContent, _ p: Double) -> ItemContent? {
        if a == b { return a }
        switch (a, b) {
        case (.solid(let ca), .solid(let cb)):
            return .solid(lerpColor(ca, cb, p))
        case (.shape(let sa), .shape(let sb)):
            guard let kind = tweenKind(sa.kind, sb.kind, p),
                  let fill = tweenFill(sa.fill, sb.fill, p),
                  let stroke = tweenStroke(sa.stroke, sb.stroke, p)
            else { return nil }
            var out = sa
            out.kind = kind
            out.fill = fill
            out.stroke = stroke
            out.shadow = tweenShadow(sa.shadow, sb.shadow, p)
            out.fillOpacity = sa.fillOpacity + (sb.fillOpacity - sa.fillOpacity) * p
            out.strokeTrim = p < 0.5 ? sa.strokeTrim : sb.strokeTrim
            return .shape(out)
        case (.text(let ta), .text(let tb)):

            var probe = ta
            probe.color = tb.color
            probe.fontSize = tb.fontSize
            probe.tracking = tb.tracking
            guard probe == tb else { return nil }
            var out = ta
            out.color = lerpColor(ta.color, tb.color, p)
            out.fontSize = ta.fontSize + (tb.fontSize - ta.fontSize) * p
            out.tracking = ta.tracking + (tb.tracking - ta.tracking) * p
            return .text(out)
        default:
            return nil
        }
    }

    static func tweenKind(_ a: SceneShapeKind, _ b: SceneShapeKind, _ p: Double) -> SceneShapeKind? {
        switch (a, b) {
        case (.rectangle, .rectangle), (.ellipse, .ellipse): return a
        case (.path(let x), .path(let y)) where x == y: return a
        case (.rectangle, .roundedRectangle(let r)): return .roundedRectangle(cornerRadius: r * p)
        case (.roundedRectangle(let r), .rectangle): return .roundedRectangle(cornerRadius: r * (1 - p))
        case (.roundedRectangle(let r1), .roundedRectangle(let r2)): return .roundedRectangle(cornerRadius: r1 + (r2 - r1) * p)
        default: return nil
        }
    }

    static func tweenFill(_ a: SceneFill, _ b: SceneFill, _ p: Double) -> SceneFill? {
        if a == b { return a }
        switch (a, b) {
        case (.solid(let ca), .solid(let cb)): return .solid(lerpColor(ca, cb, p))
        default: return nil
        }
    }

    static func tweenStroke(_ a: SceneStroke?, _ b: SceneStroke?, _ p: Double) -> SceneStroke?? {
        switch (a, b) {
        case (nil, nil): return .some(nil)
        case (let sa?, let sb?):
            guard sa.dash == sb.dash else { return nil }
            var out = sa
            out.color = lerpColor(sa.color, sb.color, p)
            out.width = sa.width + (sb.width - sa.width) * p
            return .some(out)
        case (let sa?, nil):
            var out = sa
            out.width = sa.width * (1 - p)
            return .some(out.width > 0.01 ? out : nil)
        case (nil, let sb?):
            var out = sb
            out.width = sb.width * p
            return .some(out.width > 0.01 ? out : nil)
        }
    }

    static func tweenShadow(_ a: TextShadow?, _ b: TextShadow?, _ p: Double) -> TextShadow? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let sa?, let sb?):
            var out = sa
            out.color = lerpColor(sa.color, sb.color, p)
            out.blurRadius = sa.blurRadius + (sb.blurRadius - sa.blurRadius) * p
            out.offsetX = sa.offsetX + (sb.offsetX - sa.offsetX) * p
            out.offsetY = sa.offsetY + (sb.offsetY - sa.offsetY) * p
            return out
        case (let sa?, nil):
            var out = sa
            out.color.alpha *= (1 - p)
            return out
        case (nil, let sb?):
            var out = sb
            out.color.alpha *= p
            return out
        }
    }

    static func tweenEffects(_ a: [SceneEffect], _ b: [SceneEffect], _ p: Double) -> [SceneEffect] {
        guard a.count == b.count else { return p < 0.5 ? a : b }
        var out: [SceneEffect] = []
        for (ea, eb) in zip(a, b) {
            switch (ea.kind, eb.kind) {
            case (.blur(let ra), .blur(let rb)):
                var e = ea
                e.kind = .blur(radius: ra + (rb - ra) * p)
                e.opacity = ea.opacity + (eb.opacity - ea.opacity) * p
                out.append(e)
            default:
                out.append(p < 0.5 ? ea : eb)
            }
        }
        return out
    }

    static func lerpColor(_ a: SceneColor, _ b: SceneColor, _ p: Double) -> SceneColor {
        SceneColor(
            red: a.red + (b.red - a.red) * p, green: a.green + (b.green - a.green) * p,
            blue: a.blue + (b.blue - a.blue) * p, alpha: a.alpha + (b.alpha - a.alpha) * p
        )
    }

    static func runningStep(
        _ animation: SceneStepAnimation, in steps: [SceneAnimationStep], context: AnimationContext?, now: Double
    ) -> (SceneAnimationStep, Double)? {
        for step in steps where step.animation == animation {
            if case .running(let p) = AnimationTimeline.phase(of: step, context: context, now: now) {
                return (step, p)
            }
        }
        return nil
    }

    static func quantize(_ value: Double) -> Double {
        (value * 240).rounded() / 240
    }

    static func wholeRanges(of string: String) -> [SceneAnimationRange] {
        string.components(separatedBy: "\n").enumerated().compactMap { index, line in
            line.isEmpty ? nil : SceneAnimationRange(line: index, column: 0, length: line.count)
        }
    }

    static func typeRuns(
        revealing reveal: Double, of ranges: [SceneAnimationRange], in string: String,
        caret: Bool, reverse: Bool
    ) -> [StyleRun] {
        let lines = string.components(separatedBy: "\n")
        let clamped: [SceneAnimationRange] = ranges.compactMap { range in
            guard range.line >= 0, range.line < lines.count else { return nil }
            let count = lines[range.line].count
            let start = min(max(range.column, 0), count)
            let end = min(start + max(range.length, 0), count)
            return end > start ? SceneAnimationRange(line: range.line, column: start, length: end - start) : nil
        }
        let total = clamped.reduce(0) { $0 + $1.length }
        guard total > 0 else { return [] }
        let shown = Int((min(max(reveal, 0), 1) * Double(total)).rounded(.down))
        var runs: [StyleRun] = []
        var remaining = shown
        let ordered = reverse ? Array(clamped.reversed()) : clamped
        var caretPlaced = false
        for range in ordered {
            if remaining >= range.length {
                remaining -= range.length
                continue
            }

            let hidden: SceneAnimationRange = reverse
                ? SceneAnimationRange(line: range.line, column: range.column, length: range.length - remaining)
                : SceneAnimationRange(line: range.line, column: range.column + remaining, length: range.length - remaining)
            remaining = 0
            runs.append(StyleRun(
                line: hidden.line, column: hidden.column, length: hidden.length,
                hidden: true, caret: caret && !caretPlaced && !reverse ? true : nil
            ))
            caretPlaced = true
        }
        return runs
    }

    struct Animated {
        var motion = AnimationMotion()
        var opacity: Double = 1

        var effects: [SceneEffect] = []
    }

    static func animate(
        steps: [SceneAnimationStep], context: AnimationContext?, now: Double,
        frame: CGRect, canvasSize: CGSize
    ) -> Animated {
        var out = Animated()
        for step in steps {
            guard case .running(let progress) = AnimationTimeline.phase(of: step, context: context, now: now) else {
                continue
            }
            switch step.kind {
            case .morph:
                break 
            case .enter where step.fromItem != nil:

                if step.withFade { out.opacity *= progress }
            case .enter, .exit:
                let r = step.kind == .enter ? progress : 1 - progress
                switch step.animation {
                case .fade:
                    out.opacity *= r
                case .move:
                    let from = moveOrigin(step, frame: frame, canvasSize: canvasSize)
                    out.motion.translate.dx += from.dx * (1 - r)
                    out.motion.translate.dy += from.dy * (1 - r)
                    if step.withFade { out.opacity *= r }
                case .scale:
                    out.motion.scale *= step.fromScale + (1 - step.fromScale) * r
                    if step.withFade { out.opacity *= r }
                case .wipe:
                    out.motion.wipe = AnimationMotion.Wipe(
                        edge: step.edge ?? .left, progress: r, feather: step.softEdge
                    )
                    if step.withFade { out.opacity *= r }
                case .draw, .type:

                    if step.withFade { out.opacity *= r }
                case .blur:

                    out.effects.append(SceneEffect(kind: .blur(radius: quantize(1 - r) * step.amount)))
                    if step.withFade { out.opacity *= r }
                case .burn:

                    out.effects.append(SceneEffect(kind: .burn(amount: quantize(1 - r) * step.amount, phase: quantize(r))))
                    out.opacity *= min(1, r * 2.5)
                case .glitch:

                    out.effects.append(SceneEffect(kind: .glitch(amount: quantize(1 - r) * step.amount, phase: quantize(r))))
                    out.opacity *= r < 0.08 ? 0 : 1
                case .pulse, .color:

                    out.opacity *= r
                }
            case .emphasis:
                let envelope = sin(progress * .pi) 
                switch step.animation {
                case .pulse, .scale:
                    out.motion.scale *= 1 + (step.amount - 1) * envelope
                case .fade:
                    out.opacity *= 1 - 0.5 * envelope
                case .move:
                    let from = moveOrigin(step, frame: frame, canvasSize: canvasSize)
                    out.motion.translate.dx += from.dx * envelope
                    out.motion.translate.dy += from.dy * envelope
                case .color:

                    if let color = step.color {
                        out.effects.append(SceneEffect(kind: .tint(
                            color: color,
                            amount: min(max(step.amount, 0), 1) * color.alpha * quantize(envelope)
                        )))
                    }
                default:
                    break
                }
            }
        }
        return out
    }

    static func moveOrigin(_ step: SceneAnimationStep, frame: CGRect, canvasSize: CGSize) -> CGVector {
        switch step.edge {
        case .left?: return CGVector(dx: -frame.maxX, dy: 0)
        case .right?: return CGVector(dx: canvasSize.width - frame.minX, dy: 0)
        case .top?: return CGVector(dx: 0, dy: -frame.maxY)
        case .bottom?: return CGVector(dx: 0, dy: canvasSize.height - frame.minY)
        case nil: return step.offset
        }
    }

    static func complementRuns(of ranges: [SceneAnimationRange], in string: String) -> [StyleRun] {
        let lines = string.components(separatedBy: "\n")
        var runs: [StyleRun] = []
        for (index, line) in lines.enumerated() {
            let count = line.count
            guard count > 0 else { continue }
            var keep: [Range<Int>] = ranges
                .filter { $0.line == index && $0.length > 0 }
                .map { r in
                    let start = min(max(r.column, 0), count)
                    return start..<min(start + r.length, count)
                }
                .filter { !$0.isEmpty }
                .sorted { $0.lowerBound < $1.lowerBound }

            var merged: [Range<Int>] = []
            for r in keep {
                if let last = merged.last, r.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                } else {
                    merged.append(r)
                }
            }
            keep = merged
            var cursor = 0
            for r in keep {
                if r.lowerBound > cursor {
                    runs.append(StyleRun(line: index, column: cursor, length: r.lowerBound - cursor, hidden: true))
                }
                cursor = r.upperBound
            }
            if cursor < count {
                runs.append(StyleRun(line: index, column: cursor, length: count - cursor, hidden: true))
            }
        }
        return runs
    }
}
