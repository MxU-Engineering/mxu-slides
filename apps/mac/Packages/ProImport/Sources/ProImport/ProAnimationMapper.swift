import Foundation
import PresenterCore

enum ProAnimationMapper {

    static func steps(
        for wrapped: RVData_Slide.Element, objectID: String, text: String,
        warnings: inout [String]
    ) -> [AnimationStep] {
        var steps: [AnimationStep] = []
        if wrapped.hasBuildIn {
            let build = wrapped.buildIn
            let (animation, params) = animation(from: build.transition, kind: .in, warnings: &warnings)
            if wrapped.childBuilds.isEmpty {
                steps.append(step(build, kind: .in, animation: animation, params: params, id: id(build.uuid, fallback: "\(objectID)-in"), ranges: nil))
            } else {

                let lines = text.components(separatedBy: "\n")
                for (childIndex, child) in wrapped.childBuilds.enumerated() {
                    let line = Int(child.index)
                    guard line < lines.count, !lines[line].isEmpty else { continue }
                    var s = AnimationStep(
                        id: id(child.uuid, fallback: "\(objectID)-in-\(childIndex)"),
                        kind: .in, animation: animation, trigger: trigger(child.start),
                        delaySeconds: delay(child.delayTime),
                        durationSeconds: duration(build.transition),
                        ranges: [AnimationRange(line: line, column: 0, length: lines[line].count)]
                    )
                    params(&s)
                    if child.start == .withSlide { s.trigger = .withPrevious }
                    if wrapped.revealType == .underline { s.placeholderUnderline = true }
                    steps.append(s)
                }
            }
        }
        if wrapped.hasBuildOut {
            let build = wrapped.buildOut
            var (animation, params) = animation(from: build.transition, kind: .out, warnings: &warnings)

            if build.transition.effect.name.lowercased().contains("reveal") {
                let inEdge = steps.first { $0.kind == .in }?.edge
                animation = .move
                params = { $0.edge = inEdge ?? $0.edge ?? .left; $0.withFade = nil }
            }
            steps.append(step(build, kind: .out, animation: animation, params: params, id: id(build.uuid, fallback: "\(objectID)-out"), ranges: nil))
        }
        return steps
    }

    static func animationOrder(_ animationOrder: [RVData_UUID], objects: [SlideObject]) -> [String]? {
        guard !animationOrder.isEmpty else { return nil }
        let objectByID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        let stepIDs = Set(objects.flatMap { ($0.animationSteps ?? []).map(\.id) })
        var order: [String] = []
        for uuid in animationOrder {
            let id = uuid.string.lowercased()
            if stepIDs.contains(id) {
                order.append(id)
            } else if let object = objectByID[id], let animationSteps = object.animationSteps {

                order += animationSteps.filter { $0.kind != .out }.map(\.id)
                order += animationSteps.filter { $0.kind == .out }.map(\.id)
            }
        }
        let listed = Set(order)
        let rest = objects.flatMap { ($0.animationSteps ?? []).map(\.id) }.filter { !listed.contains($0) }
        order += rest
        return order.isEmpty ? nil : order
    }

    private static func step(
        _ build: RVData_Slide.Element.Build, kind: AnimationKind, animation: StepAnimation,
        params: (inout AnimationStep) -> Void, id: String, ranges: [AnimationRange]?
    ) -> AnimationStep {
        var s = AnimationStep(
            id: id, kind: kind, animation: animation, trigger: trigger(build.start),
            delaySeconds: delay(build.delayTime),
            durationSeconds: duration(build.transition), ranges: ranges
        )
        params(&s)
        return s
    }

    static func trigger(_ start: RVData_Slide.Element.Build.Start) -> AnimationTrigger {
        switch start {
        case .onClick: .onClick
        case .withPrevious: .withPrevious
        case .afterPrevious: .afterPrevious

        case .withSlide: .withPrevious
        case .UNRECOGNIZED: .onClick
        }
    }

    static func duration(_ transition: RVData_Transition) -> Double {
        transition.duration > 0 ? (transition.duration * 1000).rounded() / 1000 : 0.5
    }

    static func delay(_ raw: Double) -> Double? {
        abs(raw) < 0.001 ? nil : (raw * 1000).rounded() / 1000
    }

    private static func id(_ uuid: RVData_UUID, fallback: String) -> String {
        let s = uuid.string.lowercased()
        return s.isEmpty ? fallback : s
    }

    static func edge(of transition: RVData_Transition) -> AnimationEdge? {
        for variable in transition.effect.variables {
            guard case .direction(let d)? = variable.type else { continue }
            switch d.direction {
            case .left, .topLeft, .bottomLeft: return .left
            case .right, .topRight, .bottomRight: return .right
            case .top: return .top
            case .bottom: return .bottom
            case .center, .none, .UNRECOGNIZED: return nil
            }
        }
        return nil
    }

    static func animation(
        from transition: RVData_Transition, kind: AnimationKind, warnings: inout [String]
    ) -> (StepAnimation, (inout AnimationStep) -> Void) {
        let name = transition.effect.name.trimmingCharacters(in: .whitespaces)
        let lowered = name.lowercased()

        let edge: AnimationEdge? = edge(of: transition)
            ?? (lowered.contains("left") ? .left : lowered.contains("right") ? .right
                : lowered.contains("top") || lowered.contains("up") ? .top
                : lowered.contains("bottom") || lowered.contains("down") ? .bottom : nil)
        if lowered.isEmpty || lowered == "none" || lowered == "cut" {
            return (.fade, { $0.durationSeconds = 0 })
        }
        if lowered.contains("blur") { return (.blur, { $0.withFade = true }) }
        if lowered.contains("dissolve") || lowered.contains("fade") || lowered.contains("cross") { return (.fade, { _ in }) }
        if lowered.contains("wipe") || lowered.contains("reveal") || lowered.contains("iris") { return (.wipe, { $0.edge = edge ?? .left }) }
        if lowered.contains("move") || lowered.contains("fly") || lowered.contains("slide") || lowered.contains("push") || lowered.contains("swipe") {
            return (.move, { $0.edge = edge ?? .left; $0.withFade = true })
        }
        if lowered.contains("zoom") || lowered.contains("scale") || lowered.contains("grow") || lowered.contains("pop") || lowered.contains("bounce") {
            return (.scale, { $0.fromScale = lowered.contains("out") && kind == .in ? 1.3 : 0.7; $0.withFade = true })
        }
        if lowered.contains("burn") || lowered.contains("flash") || lowered.contains("light") { return (.burn, { $0.amount = 0.6 }) }
        if lowered.contains("glitch") || lowered.contains("static") || lowered.contains("noise") { return (.glitch, { $0.amount = 0.6 }) }
        if lowered.contains("type") { return (.type, { $0.cursor = true }) }
        if lowered.contains("draw") || lowered.contains("stroke") { return (.draw, { _ in }) }
        let warning = "animation \"\(name)\" has no MxU equivalent; imported as a fade"
        if !warnings.contains(warning) { warnings.append(warning) }
        return (.fade, { _ in })
    }
}
