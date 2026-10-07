import Foundation

public struct AnimationPresetGroup: Identifiable, Sendable, Equatable {
    public var name: String
    public var presets: [AnimationPreset]
    public var id: String { name }

    public init(name: String, presets: [AnimationPreset]) {
        self.name = name
        self.presets = presets
    }
}

public extension AnimationPreset {

    private static func step(
        _ kind: AnimationKind, _ animation: StepAnimation, trigger: AnimationTrigger,
        duration: Double = 0.5, delay: Double? = nil, ramp: AnimationRamp? = nil, withFade: Bool? = nil,
        edge: AnimationEdge? = nil, offsetX: Double? = nil, offsetY: Double? = nil, fromScale: Double? = nil,
        amount: Double? = nil, softEdge: Double? = nil, cursor: Bool? = nil, drawStart: Double? = nil
    ) -> AnimationStep {
        AnimationStep(
            id: "preset", kind: kind, animation: animation, trigger: trigger,
            delaySeconds: delay, durationSeconds: duration, ramp: ramp, withFade: withFade,
            edge: edge, offsetX: offsetX, offsetY: offsetY, fromScale: fromScale,
            amount: amount, softEdge: softEdge, cursor: cursor, drawStart: drawStart
        )
    }

    private static func pair(_ id: String, _ name: String, in enter: AnimationStep, out exit: AnimationStep, stagger: Double = 0.15) -> AnimationPresetGroup {
        AnimationPresetGroup(name: name, presets: [
            AnimationPreset(id: "builtin.\(id).in", name: "In", steps: [enter], staggerSeconds: stagger),
            AnimationPreset(id: "builtin.\(id).out", name: "Out", steps: [exit], staggerSeconds: stagger),
            AnimationPreset(id: "builtin.\(id).both", name: "In + Out", steps: [enter, exit], staggerSeconds: stagger),
        ])
    }

    static let recommendedGroups: [AnimationPresetGroup] = [

        pair("settle", "Settle",
             in: step(.in, .scale, trigger: .onClick, withFade: true, fromScale: 0.95),
             out: step(.out, .scale, trigger: .onDismiss, duration: 0.4, withFade: true, fromScale: 0.95)),

        pair("float", "Float",
             in: step(.in, .move, trigger: .onClick, withFade: true, offsetX: 0, offsetY: 40),
             out: step(.out, .move, trigger: .onDismiss, duration: 0.4, withFade: true, offsetX: 0, offsetY: -40)),

        AnimationPresetGroup(name: "Slide", presets: [
            AnimationPreset(id: "builtin.slide.left", name: "From Left", steps: [step(.in, .move, trigger: .onClick, edge: .left)]),
            AnimationPreset(id: "builtin.slide.right", name: "From Right", steps: [step(.in, .move, trigger: .onClick, edge: .right)]),
            AnimationPreset(id: "builtin.slide.bottom", name: "From Bottom", steps: [step(.in, .move, trigger: .onClick, edge: .bottom)]),
            AnimationPreset(id: "builtin.slide.top", name: "From Top", steps: [step(.in, .move, trigger: .onClick, edge: .top)]),
            AnimationPreset(id: "builtin.slide.leftBoth", name: "From Left, Out Left", steps: [
                step(.in, .move, trigger: .onClick, edge: .left),
                step(.out, .move, trigger: .onDismiss, duration: 0.4, edge: .left),
            ]),
        ]),

        pair("barWipe", "Bar Wipe",
             in: step(.in, .wipe, trigger: .onClick, duration: 0.6, edge: .left, softEdge: 40),
             out: step(.out, .wipe, trigger: .onDismiss, duration: 0.5, edge: .right, softEdge: 40)),

        AnimationPresetGroup(name: "Line Draw", presets: [
            AnimationPreset(id: "builtin.lineDraw", name: "Line Draw", steps: [
                step(.in, .draw, trigger: .onClick, duration: 1.0, drawStart: 0),
            ]),
        ]),

        AnimationPresetGroup(name: "Pill Grow", presets: [
            AnimationPreset(id: "builtin.pillGrow", name: "Pill Grow", steps: [
                step(.in, .scale, trigger: .onClick, duration: 0.4, ramp: .out, withFade: true, fromScale: 0.6),
                step(.emphasis, .pulse, trigger: .afterPrevious, duration: 0.3, amount: 1.06),
            ]),
        ]),

        AnimationPresetGroup(name: "Bracket Pop", presets: [
            AnimationPreset(id: "builtin.bracketPop", name: "Bracket Pop", steps: [
                step(.in, .scale, trigger: .onClick, duration: 0.3, ramp: .out, withFade: true, fromScale: 1.2),
            ]),
        ]),

        pair("blurResolve", "Blur Resolve",
             in: step(.in, .blur, trigger: .onClick, duration: 0.9, withFade: true, amount: 32),
             out: step(.out, .blur, trigger: .onDismiss, duration: 0.7, withFade: true, amount: 32)),

        pair("burn", "Burn",
             in: step(.in, .burn, trigger: .onClick, duration: 1.2, amount: 0.7),
             out: step(.out, .burn, trigger: .onDismiss, duration: 1.0, amount: 0.7)),

        pair("glitch", "Glitch",
             in: step(.in, .glitch, trigger: .onClick, duration: 0.9, amount: 0.9),
             out: step(.out, .glitch, trigger: .onDismiss, duration: 0.8, amount: 0.9)),

        AnimationPresetGroup(name: "Type", presets: [
            AnimationPreset(id: "builtin.type", name: "Type", steps: [
                step(.in, .type, trigger: .onClick, duration: 1.2, cursor: true),
            ]),
            AnimationPreset(id: "builtin.type.frame", name: "Frame, then Type", steps: [
                step(.in, .draw, trigger: .onClick, duration: 0.8, drawStart: 0),
                step(.in, .type, trigger: .afterPrevious, duration: 1.2, delay: -0.3, cursor: true),
            ]),
        ]),

        AnimationPresetGroup(name: "Roll", presets: [
            AnimationPreset(id: "builtin.roll", name: "Roll (credits)", steps: [],
                        scroll: BlockScroll(axis: .up, speed: 60, passes: 1, ramp: .both, restAtEnd: false)),
            AnimationPreset(id: "builtin.roll.rest", name: "Roll, rest on last lines", steps: [],
                        scroll: BlockScroll(axis: .up, speed: 60, passes: 1, ramp: .both, restAtEnd: true)),
        ]),
        AnimationPresetGroup(name: "Crawl", presets: [
            AnimationPreset(id: "builtin.crawl", name: "Crawl", steps: [],
                        scroll: BlockScroll(axis: .up, speed: 50, passes: 1, ramp: .none, fadeTowardTop: 0.35),
                        tilt: 35),
        ]),
    ]

    static var recommended: [AnimationPreset] { recommendedGroups.flatMap(\.presets) }
}

public enum AnimationPresetApplication {
    public enum Mode: Sendable { case replace, add }

    public struct Result: Equatable, Sendable {

        public var animationSteps: [AnimationStep]?

        public var addedIDs: [String]

        public var scroll: BlockScroll?
        public var tilt: Double?
    }

    public static func apply(
        _ preset: AnimationPreset, to existing: [AnimationStep]?, mode: Mode, position: Int,
        makeID: () -> String = { UUID().uuidString }
    ) -> Result {
        let stagger = preset.staggerSeconds ?? 0.15
        var steps: [AnimationStep] = []
        for (index, template) in preset.steps.enumerated() {
            var step = template
            step.id = makeID()
            step.ranges = nil 
            if position > 0 {

                if index == 0, template.trigger == .onClick {
                    step.trigger = .withPrevious
                }
                if index == 0 || template.trigger == .onDismiss {
                    step.delaySeconds = (template.delaySeconds ?? 0) + stagger * Double(position)
                }
            }
            steps.append(step)
        }
        let kept: [AnimationStep] = mode == .replace ? [] : (existing ?? [])
        let animationSteps = kept + steps
        return Result(
            animationSteps: animationSteps.isEmpty ? nil : animationSteps,
            addedIDs: steps.map(\.id),
            scroll: preset.scroll,
            tilt: preset.tilt
        )
    }

    public static func recipe(from animationSteps: [AnimationStep]?) -> [AnimationStep] {
        (animationSteps ?? []).map { step in
            var s = step
            s.ranges = nil
            s.toObject = nil
            s.fromObject = nil
            return s
        }
    }
}
