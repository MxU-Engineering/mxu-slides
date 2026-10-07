import CoreGraphics
import Foundation

public enum SceneAnimationKind: Hashable, Sendable {
    case enter
    case exit
    case emphasis

    case morph
}

public enum SceneStepAnimation: String, Hashable, Sendable {
    case fade, move, scale, wipe, blur, burn, glitch, draw, type, pulse, color
}

public enum SceneAnimationRamp: Hashable, Sendable {
    case none, easeIn, easeOut, easeInOut

    public func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .none: return x
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .easeInOut: return x * x * (3 - 2 * x)
        }
    }
}

public enum SceneAnimationEdge: Hashable, Sendable {
    case left, right, top, bottom
}

public struct SceneVideoPush: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case center, left, right, top, bottom }
    public enum Mode: Hashable, Sendable { case fill, fit, blurBackground }
    public var alignment: Alignment
    public var mode: Mode

    public var zoom: Double

    public var margin: Double

    public var backdrop: Bool

    public var blurRadius: Double

    public init(
        alignment: Alignment = .center, mode: Mode = .fill, zoom: Double = 1,
        margin: Double = 0, backdrop: Bool = false, blurRadius: Double = 36
    ) {
        self.alignment = alignment
        self.mode = mode
        self.zoom = zoom
        self.margin = margin
        self.backdrop = backdrop
        self.blurRadius = blurRadius
    }
}

public struct SceneAnimationRange: Hashable, Sendable {
    public var line: Int
    public var column: Int
    public var length: Int

    public init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
}

public enum SceneAnimationGroup: Hashable, Sendable {
    case auto
    case click(Int)
    case exit
}

public struct SceneAnimationStep: Equatable, Sendable {
    public var id: String
    public var kind: SceneAnimationKind
    public var animation: SceneStepAnimation
    public var group: SceneAnimationGroup
    public var startOffset: Double
    public var duration: Double
    public var ramp: SceneAnimationRamp
    public var withFade: Bool
    public var ranges: [SceneAnimationRange]?
    public var edge: SceneAnimationEdge?
    public var offset: CGVector
    public var fromScale: Double
    public var amount: Double
    public var softEdge: Double
    public var cursor: Bool
    public var color: SceneColor?
    public var placeholderUnderline: Bool

    public var drawStart: Double

    public var reverse: Bool

    public var toItem: RenderItem?

    public var fromItem: RenderItem?

    public var videoPush: SceneVideoPush?

    public init(
        id: String,
        kind: SceneAnimationKind,
        animation: SceneStepAnimation,
        group: SceneAnimationGroup,
        startOffset: Double = 0,
        duration: Double,
        ramp: SceneAnimationRamp = .easeOut,
        withFade: Bool = false,
        ranges: [SceneAnimationRange]? = nil,
        edge: SceneAnimationEdge? = nil,
        offset: CGVector = .zero,
        fromScale: Double = 0.95,
        amount: Double = 0.6,
        softEdge: Double = 0,
        cursor: Bool = true,
        color: SceneColor? = nil,
        placeholderUnderline: Bool = false,
        drawStart: Double = 0,
        reverse: Bool = false,
        toItem: RenderItem? = nil,
        fromItem: RenderItem? = nil,
        videoPush: SceneVideoPush? = nil
    ) {
        self.id = id
        self.kind = kind
        self.animation = animation
        self.group = group
        self.startOffset = startOffset
        self.duration = max(duration, 0)
        self.ramp = ramp
        self.withFade = withFade
        self.ranges = ranges
        self.edge = edge
        self.offset = offset
        self.fromScale = fromScale
        self.amount = amount
        self.softEdge = softEdge
        self.cursor = cursor
        self.color = color
        self.placeholderUnderline = placeholderUnderline
        self.drawStart = drawStart
        self.reverse = reverse
        self.toItem = toItem
        self.fromItem = fromItem
        self.videoPush = videoPush
    }

    public var targetsWholeObject: Bool { ranges?.isEmpty ?? true }
}

public struct AnimationContext: Hashable, Sendable {

    public var anchorHostTime: Double

    public var clickHostTimes: [Double]

    public var dismissHostTime: Double?

    public var exitHostTime: Double?

    public var frozenHostTime: Double?

    public var autoSettled: Bool

    public init(
        anchorHostTime: Double, clickHostTimes: [Double] = [], dismissHostTime: Double? = nil,
        exitHostTime: Double? = nil,
        frozenHostTime: Double? = nil,
        autoSettled: Bool = false
    ) {
        self.anchorHostTime = anchorHostTime
        self.clickHostTimes = clickHostTimes
        self.dismissHostTime = dismissHostTime
        self.exitHostTime = exitHostTime
        self.frozenHostTime = frozenHostTime
        self.autoSettled = autoSettled
    }

    public static let settled = AnimationContext(
        anchorHostTime: 0,
        clickHostTimes: Array(repeating: 0, count: 256),
        dismissHostTime: nil,
        frozenHostTime: 1e9
    )

    public func start(of group: SceneAnimationGroup) -> Double? {
        switch group {
        case .auto: return anchorHostTime
        case .click(let n): return n < clickHostTimes.count ? clickHostTimes[n] : nil
        case .exit: return exitHostTime ?? dismissHostTime
        }
    }
}

public enum AnimationStepPhase: Hashable, Sendable {

    case pending

    case running(Double)

    case done

    public var progress: Double {
        switch self {
        case .pending: 0
        case .running(let p): p
        case .done: 1
        }
    }

    public var hasStarted: Bool { self != .pending }
    public var isDone: Bool { self == .done }
}

public struct AnimationVisibility: Hashable, Sendable {

    public var hidesWholeObject: Bool

    public var hiddenRanges: [SceneAnimationRange]

    public var placeholderRanges: [SceneAnimationRange]

    public init(hidesWholeObject: Bool = false, hiddenRanges: [SceneAnimationRange] = [], placeholderRanges: [SceneAnimationRange] = []) {
        self.hidesWholeObject = hidesWholeObject
        self.hiddenRanges = hiddenRanges
        self.placeholderRanges = placeholderRanges
    }

    public static let shown = AnimationVisibility()
}

public enum AnimationTimeline {

    public static func phase(of step: SceneAnimationStep, context: AnimationContext?, now: Double) -> AnimationStepPhase {
        guard let context else { return .done }

        if context.autoSettled, step.group == .auto { return .done }
        guard let groupStart = effectiveStart(of: step, context: context) else { return .pending }
        let elapsed = (context.frozenHostTime ?? now) - groupStart - step.startOffset
        if elapsed < 0 { return .pending }
        if step.duration <= 0 || elapsed >= step.duration { return .done }
        return .running(step.ramp.apply(elapsed / step.duration))
    }

    static func effectiveStart(of step: SceneAnimationStep, context: AnimationContext) -> Double? {
        if let start = context.start(of: step.group) { return start }
        if step.kind == .exit, case .click = step.group,
           let dismiss = context.dismissHostTime {
            return dismiss
        }
        return nil
    }

    public static func visibility(
        of steps: [SceneAnimationStep], context: AnimationContext?, now: Double
    ) -> AnimationVisibility {

        guard context != nil else { return .shown }
        var result = AnimationVisibility()

        result.hidesWholeObject = isHidden(
            steps.filter { $0.targetsWholeObject }, context: context, now: now
        )

        var byRange: [SceneAnimationRange: [SceneAnimationStep]] = [:]
        var order: [SceneAnimationRange] = []
        for step in steps where !step.targetsWholeObject {
            for range in step.ranges ?? [] {
                if byRange[range] == nil { order.append(range) }
                byRange[range, default: []].append(step)
            }
        }
        for range in order {
            let rangeSteps = byRange[range] ?? []
            guard isHidden(rangeSteps, context: context, now: now) else { continue }
            result.hiddenRanges.append(range)
            if rangeSteps.contains(where: { $0.placeholderUnderline }) {
                result.placeholderRanges.append(range)
            }
        }
        return result
    }

    private static func isHidden(_ steps: [SceneAnimationStep], context: AnimationContext?, now: Double) -> Bool {
        let gates = steps.filter { $0.kind != .emphasis && $0.kind != .morph }
        guard !gates.isEmpty else { return false }
        var latestStarted: (step: SceneAnimationStep, phase: AnimationStepPhase)?
        for step in gates {
            let p = phase(of: step, context: context, now: now)
            if p.hasStarted { latestStarted = (step, p) }
        }
        guard let latest = latestStarted else {

            return gates.contains { $0.kind == .enter }
        }

        let enters = gates.filter { $0.kind == .enter }
        if !enters.isEmpty,
           !enters.contains(where: { phase(of: $0, context: context, now: now).hasStarted }) {
            return true
        }
        switch latest.step.kind {
        case .enter: return false
        case .exit: return latest.phase.isDone
        case .emphasis, .morph: return false
        }
    }

    public static func groupCompleted(
        _ group: SceneAnimationGroup, in steps: [SceneAnimationStep], context: AnimationContext?, now: Double
    ) -> Bool {
        let members = steps.filter { $0.group == group }
        guard !members.isEmpty else { return true }
        return members.allSatisfy { phase(of: $0, context: context, now: now).isDone }
    }

    public static func groupDuration(_ group: SceneAnimationGroup, in steps: [SceneAnimationStep]) -> Double {
        steps.filter { $0.group == group }.map { $0.startOffset + $0.duration }.max() ?? 0
    }
}
