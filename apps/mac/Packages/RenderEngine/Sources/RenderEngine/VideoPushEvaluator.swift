import CoreGraphics
import Foundation

public enum VideoPushEvaluator {

    public static let pushedLayers: Set<LayerKind> = [.videoInput, .loopingVideos, .stillGraphics, .videos]

    public struct State: Equatable, Sendable {
        public var push: SceneVideoPush

        public var amount: Double

        public var target: CGRect
    }

    public static func activeState(_ scene: RenderScene, now: Double) -> State? {
        var best: (anchor: Double, state: State)?
        for layer in scene.layers where !layer.isHidden && !pushedLayers.contains(layer.kind) {
            for item in layer.items {
                guard let context = item.animationContext, !item.animationSteps.isEmpty else { continue }
                var amount: Double?
                var push: SceneVideoPush?
                for step in item.animationSteps {
                    guard let stepPush = step.videoPush else { continue }
                    switch AnimationTimeline.phase(of: step, context: context, now: now) {
                    case .pending:
                        continue
                    case .running(let p):
                        amount = step.kind == .exit ? 1 - p : p
                        push = stepPush
                    case .done:
                        amount = step.kind == .exit ? 0 : 1
                        push = stepPush
                    }
                }
                guard let amount, amount > 0.0001, let push else { continue }
                let target = freeRect(around: item.frame, canvas: scene.canvasSize, margin: push.margin)
                let state = State(push: push, amount: min(amount, 1), target: target)
                if best == nil || context.anchorHostTime > best!.anchor {
                    best = (context.anchorHostTime, state)
                }
            }
        }
        return best?.state
    }

    public static func freeRect(around frame: CGRect, canvas: CGSize, margin: Double) -> CGRect {
        let full = CGRect(origin: .zero, size: canvas)
        let clipped = frame.intersection(full)
        guard !clipped.isEmpty else { return full.insetBy(dx: margin, dy: margin) }
        let candidates = [
            CGRect(x: 0, y: 0, width: clipped.minX, height: canvas.height),                                    
            CGRect(x: clipped.maxX, y: 0, width: canvas.width - clipped.maxX, height: canvas.height),          
            CGRect(x: 0, y: 0, width: canvas.width, height: clipped.minY),                                     
            CGRect(x: 0, y: clipped.maxY, width: canvas.width, height: canvas.height - clipped.maxY),          
        ]
        let bestRect = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) ?? full
        let inset = bestRect.insetBy(dx: CGFloat(margin), dy: CGFloat(margin))
        return (inset.isEmpty || bestRect.width * bestRect.height < 1) ? full : inset
    }

    public struct Transform: Equatable, Sendable {
        public var scale: Double
        public var offset: CGVector

        public var clip: CGRect?

        public var blurRadius: Double
    }

    public static func transform(canvas: CGSize, state: State) -> Transform {
        let push = state.push
        let amount = min(max(state.amount, 0), 1)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        if push.mode == .blurBackground {
            let scale = lerp(1, max(push.zoom, 1))
            let offset = CGVector(
                dx: canvas.width / 2 * (1 - scale),
                dy: canvas.height / 2 * (1 - scale)
            )
            return Transform(scale: scale, offset: offset, clip: nil, blurRadius: lerp(0, max(push.blurRadius, 0)))
        }

        let full = CGRect(origin: .zero, size: canvas)
        let rect = CGRect(
            x: lerp(0, state.target.minX), y: lerp(0, state.target.minY),
            width: lerp(canvas.width, state.target.width), height: lerp(canvas.height, state.target.height)
        )
        let ratioW = rect.width / canvas.width, ratioH = rect.height / canvas.height
        let base = push.mode == .fit ? min(ratioW, ratioH) : max(ratioW, ratioH)
        let scale = Double(base) * lerp(1, max(push.zoom, 0.05))
        let drawnW = canvas.width * scale, drawnH = canvas.height * scale
        let dx: Double = switch push.alignment {
        case .left: Double(rect.minX)
        case .right: Double(rect.maxX) - drawnW
        default: Double(rect.midX) - drawnW / 2
        }
        let dy: Double = switch push.alignment {
        case .top: Double(rect.minY)
        case .bottom: Double(rect.maxY) - drawnH
        default: Double(rect.midY) - drawnH / 2
        }
        _ = full
        return Transform(scale: scale, offset: CGVector(dx: dx, dy: dy), clip: rect, blurRadius: 0)
    }

    public static func backdropTransform(canvas: CGSize, state: State) -> Transform {
        let amount = min(max(state.amount, 0), 1)
        let scale = 1 + (max(state.push.zoom, 1.12) - 1) * amount
        return Transform(
            scale: scale,
            offset: CGVector(dx: canvas.width / 2 * (1 - scale), dy: canvas.height / 2 * (1 - scale)),
            clip: nil,
            blurRadius: max(state.push.blurRadius, 0) * amount
        )
    }

    public static func apply(_ transform: Transform, to resolved: AnimationEvaluator.ResolvedItem) -> AnimationEvaluator.ResolvedItem {
        var out = resolved
        let frame = resolved.item.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        out.motion.scale *= transform.scale
        out.motion.translate.dx += transform.offset.dx + (transform.scale - 1) * Double(center.x)
        out.motion.translate.dy += transform.offset.dy + (transform.scale - 1) * Double(center.y)
        if let clip = transform.clip, frame.width > 0, frame.height > 0 {

            let s = CGFloat(transform.scale)
            let originX = CGFloat(transform.offset.dx) + s * frame.minX
            let originY = CGFloat(transform.offset.dy) + s * frame.minY
            out.motion.clip = AnimationMotion.Clip(
                minU: Double((clip.minX - originX) / (frame.width * s)),
                maxU: Double((clip.maxX - originX) / (frame.width * s)),
                minV: Double((clip.minY - originY) / (frame.height * s)),
                maxV: Double((clip.maxY - originY) / (frame.height * s))
            )
        }
        if transform.blurRadius > 0.5 {
            out.item.effects = [SceneEffect(kind: .blur(radius: transform.blurRadius))] + out.item.effects
        }
        return out
    }
}
