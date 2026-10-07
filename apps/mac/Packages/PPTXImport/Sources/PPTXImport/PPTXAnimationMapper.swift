import Foundation
import PresenterCore

enum PPTXAnimationMapper {

    struct Result {
        var animationOrder: [String]?
        var warnings: [String] = []
    }

    static func apply(_ animationSteps: [PPTXAnimation], objectIDs: [Int: String], objects: inout [SlideObject]) -> Result {
        var result = Result()
        var order: [String] = []
        for build in animationSteps {
            guard let objectID = objectIDs[build.shapeID],
                  let index = objects.firstIndex(where: { $0.id == objectID })
            else { continue }
            guard let step = step(build, object: objects[index], warnings: &result.warnings) else { continue }
            objects[index].animationSteps = (objects[index].animationSteps ?? []) + [step]
            order.append(step.id)
        }
        result.animationOrder = order.isEmpty ? nil : order
        return result
    }

    static func step(_ build: PPTXAnimation, object: SlideObject, warnings: inout [String]) -> AnimationStep? {
        let kind: AnimationKind
        switch build.presetClass {
        case "entr": kind = .in
        case "exit": kind = .out
        case "emph", "path": kind = .emphasis
        default: return nil
        }
        let trigger: AnimationTrigger = switch build.nodeType {
        case "withEffect": .withPrevious
        case "afterEffect": .afterPrevious
        default: .onClick
        }
        var step = AnimationStep(
            id: UUID().uuidString, kind: kind, animation: .fade, trigger: trigger,
            durationSeconds: max((build.durationMs ?? 500) / 1000, 0)
        )

        if trigger != .afterPrevious, build.delayMs > 0 { step.delaySeconds = build.delayMs / 1000 }
        applyPreset(build, kind: kind, to: &step, warnings: &warnings)
        if let start = build.paragraphStart {
            let end = build.paragraphEnd ?? start
            let ranges = paragraphRanges(start...end, in: object.text)
            if !ranges.isEmpty { step.ranges = ranges }
        }
        return step
    }

    static func paragraphRanges(_ paragraphs: ClosedRange<Int>, in text: String) -> [AnimationRange] {
        let lines = text.components(separatedBy: "\n")
        return paragraphs.compactMap { line in
            guard line >= 0, line < lines.count, !lines[line].isEmpty else { return nil }
            return AnimationRange(line: line, column: 0, length: lines[line].count)
        }
    }

    private static func edge(_ subtype: Int?) -> AnimationEdge? {
        guard let subtype else { return nil }
        if subtype & 8 != 0 { return .left }
        if subtype & 2 != 0 { return .right }
        if subtype & 4 != 0 { return .bottom }
        if subtype & 1 != 0 { return .top }
        return nil
    }

    private static func applyPreset(_ build: PPTXAnimation, kind: AnimationKind, to step: inout AnimationStep, warnings: inout [String]) {
        func note(_ name: String, as nearest: String) {
            let warning = "animation \"\(name)\" has no MxU equivalent; imported as \(nearest)"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        let id = build.presetID ?? 0
        if build.presetClass == "path" {

            step.animation = .move
            step.offsetX = 0
            step.offsetY = -40
            note("motion path", as: "a nudge")
            return
        }
        if kind == .emphasis {
            switch id {
            case 6: step.animation = .scale; step.amount = 1.2                     
            case 1, 3, 7, 14, 16, 17, 18, 19, 20, 21, 22, 25, 26:                  
                step.animation = .color
            case 9, 24, 31: step.animation = .fade                                   
            case 10, 23, 32, 33, 36: step.animation = .pulse; step.amount = 1.1     
            case 8, 28, 30, 35: step.animation = .move; step.offsetX = 0; step.offsetY = -20  
                note("emphasis \(id)", as: "a nudge")
            default: step.animation = .pulse; step.amount = 1.1; note("emphasis \(id)", as: "a pulse")
            }
            return
        }

        switch id {
        case 1: step.animation = .fade; step.durationSeconds = 0                     
        case 9, 10: step.animation = .fade                                            
        case 2, 7, 12, 26, 27, 30, 32, 37, 38, 41, 42, 47, 48, 52, 54:               
            step.animation = .move; step.edge = edge(build.presetSubtype) ?? .bottom; step.withFade = id != 2 && id != 7
        case 3, 4, 5, 6, 8, 13, 14, 16, 18, 20, 21, 22, 28, 39:                      
            step.animation = .wipe; step.edge = edge(build.presetSubtype) ?? .left; step.softEdge = id == 22 ? 0 : 60
            if ![22, 16, 4, 6].contains(id) { note("entrance/exit \(id)", as: "a soft wipe") }
        case 23, 31, 53, 55, 50, 17, 51, 40, 56, 58, 33: 
            step.animation = .scale; step.fromScale = kind == .in ? 0.7 : 0.7; step.withFade = true
            if ![23, 31, 53, 55, 50].contains(id) { note("entrance/exit \(id)", as: "a scale") }
        case 19, 45, 43, 49, 35, 15: 
            step.animation = .scale; step.fromScale = 0.6; step.withFade = true; note("entrance/exit \(id)", as: "a scale")
        case 11, 34: step.animation = .burn; step.amount = 0.6                        
        case 29: step.animation = .move; step.edge = .bottom; step.durationSeconds = max(step.durationSeconds, 8) 
            note("Credits", as: "a slow rise (use Block Scroll for a real roll)")
        case 24: step.animation = .fade; note("Random Effects", as: "a fade")
        default: step.animation = .fade; note("entrance/exit \(id)", as: "a fade")
        }
    }
}
