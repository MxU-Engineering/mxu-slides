import Foundation
import Metal
import Testing
import PresenterCore
import RenderEngine
@testable import SlideScene

@MainActor
struct StarterPackRenderTests {
    private func ink(_ frame: RenderedFrame, _ rect: CGRect) -> Int {
        var count = 0
        frame.data.withUnsafeBytes { raw in
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
                    let halves = base.assumingMemoryBound(to: Float16.self)
                    if Float(halves[3]) > 0.05 { count += 1 }
                }
            }
        }
        return count
    }

    private func arrivedInstant(_ overlay: Overlay) -> Double {
        let timeline = AnimationSequence.previewTimeline(objects: overlay.objects, order: overlay.animationOrder)
        let scheduled = AnimationSequence.sceneSteps(objects: overlay.objects, order: overlay.animationOrder)
            .values.flatMap { $0 }
        let outStarts: [Double] = scheduled.filter { $0.kind == .exit }.compactMap { step in
            switch step.group {
            case .auto: return step.startOffset
            case .click(let n):
                return timeline.clicks.indices.contains(n) ? timeline.clicks[n] + step.startOffset : nil
            case .exit: return timeline.dismissAt + step.startOffset
            }
        }
        return max((outStarts.min() ?? timeline.dismissAt) - 0.05, 0)
    }

    private func render(_ overlay: Overlay, at time: Double, compositor: Compositor) throws -> RenderedFrame {
        let slide = Slide(id: overlay.id, name: overlay.name, objects: overlay.objects, animationOrder: overlay.animationOrder)
        let context = AnimationSequence.previewContext(objects: slide.objects, order: slide.animationOrder, time: time)
        let scene = SlideSceneBuilder.scene(for: slide, theme: nil, canvasSize: CGSize(width: 1920, height: 1080), animationContext: context)
        return try compositor.renderFrame(scene: scene, width: 480, height: 270, at: 0, transparentBackground: true)
    }

    @Test func everyPackOverlayRendersInkMidSequenceAndSettled() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let compositor = try Compositor()
        let all = CGRect(x: 0, y: 0, width: 480, height: 270)
        for pack in StarterPack.allCases {
            for overlay in pack.makeOverlays() {

                let settled = try render(
                    overlay, at: arrivedInstant(overlay), compositor: compositor
                )
                #expect(ink(settled, all) > 200, "\(pack.title)/\(overlay.name) settled")
                let mid = try render(overlay, at: 0.45, compositor: compositor)
                #expect(ink(mid, all) > 0, "\(pack.title)/\(overlay.name) mid")
            }
        }
    }

    @Test func plateNeverLeavesBeforeItsText() {
        let covered: Set<String> = [
            "Point", "Point (Lower Third)", "Point (Side Third)",
            "Verse + Reference", "Verse + Reference (Lower Third)", "Verse + Reference (Side Third)",
            "Call to Action", "Call to Action (Lower Third)", "Call to Action (Side Third)",
            "Lower Third", "Side Third",
        ]
        for pack in StarterPack.allCases {
            let compositions: [(String, [SlideObject], [String]?)] =
                pack.makeOverlays().map { ("\(pack.title)/\($0.name)", $0.objects, $0.animationOrder) }
                + (pack.makeTheme().slides ?? []).filter { $0.animationOrder != nil }.map { ("\(pack.title)/\($0.name)", $0.objects, $0.animationOrder) }
            for (label, objects, order) in compositions
            where covered.contains(label.split(separator: "/").last.map(String.init) ?? "") {
                let kinds = Dictionary(uniqueKeysWithValues: objects.map { object -> (String, SlideObjectKind?) in
                    let area = (object.width ?? 0) * (object.height ?? 0)
                    let isPlate = object.objectKind == .shape && area >= 20_000 && object.name != "Mask"
                    return (object.id, isPlate ? .shape : (object.objectKind == .text ? .text : nil))
                })
                let steps = AnimationSequence.sceneSteps(objects: objects, order: order)

                var textEnd: [SceneAnimationGroup: Double] = [:]
                var plateStart: [SceneAnimationGroup: Double] = [:]
                for (objectID, list) in steps {
                    for step in list where step.kind == .exit {
                        if kinds[objectID] == .text {
                            textEnd[step.group] = max(textEnd[step.group] ?? 0, step.startOffset + step.duration)
                        }
                        if kinds[objectID] == .shape {
                            plateStart[step.group] = min(plateStart[step.group] ?? .infinity, step.startOffset)
                        }
                    }
                }
                for (group, start) in plateStart {
                    guard let end = textEnd[group] else { continue }
                    #expect(start >= end - 0.06, "\(label): plate leaves at \(start) under text until \(end)")
                }
            }
        }
    }

    @Test func textNeverArrivesBeforeItsShape() {
        for pack in StarterPack.allCases {
            let compositions: [(String, [SlideObject], [String]?)] =
                pack.makeOverlays().map { ("\(pack.title)/\($0.name)", $0.objects, $0.animationOrder) }
                + (pack.makeTheme().slides ?? []).filter { $0.animationOrder != nil }.map { ("\(pack.title)/\($0.name)", $0.objects, $0.animationOrder) }
            for (label, objects, order) in compositions {

                let kinds = Dictionary(uniqueKeysWithValues: objects.map { object -> (String, SlideObjectKind?) in
                    let area = (object.width ?? 0) * (object.height ?? 0)
                    let isPlate = object.objectKind == .shape && area >= 20_000 && object.name != "Mask"
                    return (object.id, isPlate ? .shape : (object.objectKind == .text ? .text : nil))
                })
                let steps = AnimationSequence.sceneSteps(objects: objects, order: order)
                var firstShapeEnd: Double?
                var firstTextStart: Double?
                for (objectID, list) in steps {
                    for step in list where step.kind == .enter && step.group == .auto {
                        if kinds[objectID] == .shape { firstShapeEnd = min(firstShapeEnd ?? .infinity, step.startOffset + step.duration) }
                        if kinds[objectID] == .text { firstTextStart = min(firstTextStart ?? .infinity, step.startOffset) }
                    }
                }
                if let shapeEnd = firstShapeEnd, let textStart = firstTextStart {
                    if textStart < shapeEnd - 0.06 { print("TEXT-BEFORE-PLATE \(label): text \(textStart) vs plate end \(shapeEnd)") }
                    #expect(textStart >= shapeEnd - 0.06, "\(label): text \(textStart) vs plate end \(shapeEnd)")
                }
            }
        }
    }

    @Test func everyIconRendersAndRingsHaveHoles() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let compositor = try Compositor()
        for icon in IconCatalog.all {
            let object = SlideObject(id: "i", objectKind: .shape, name: icon.name, text: "", x: 440, y: 20, width: 1040, height: 1040,
                                     shapeKind: .path, pathData: icon.pathData, fill: ObjectFill(fillKind: .solid, colorHex: "#FFFFFFFF"))
            let slide = Slide(id: "s", name: icon.name, objects: [object])
            let scene = SlideSceneBuilder.scene(for: slide, theme: nil, canvasSize: CGSize(width: 1920, height: 1080))
            let frame = try compositor.renderFrame(scene: scene, width: 480, height: 270, at: 0, transparentBackground: true)
            let all = CGRect(x: 110, y: 5, width: 260, height: 260)
            #expect(ink(frame, all) > 800, "\(icon.name) draws")
            if icon.id == "ring" {
                #expect(ink(frame, CGRect(x: 225, y: 120, width: 30, height: 30)) == 0, "the ring's center is empty")
            }
            if icon.id == "clock" {

                #expect(ink(frame, CGRect(x: 178, y: 177, width: 20, height: 20)) == 0, "the clock face is hollow")
            }
            if icon.id == "search" {
                #expect(ink(frame, CGRect(x: 205, y: 95, width: 20, height: 20)) == 0, "the magnifier lens is hollow")
            }
        }
        #expect(Set(IconCatalog.all.map(\.id)).count == IconCatalog.all.count)
    }

    @Test func cleanGeometricNameRisesInsideItsPlate() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let compositor = try Compositor()
        let overlay = StarterPack.cleanGeometric.makeOverlays()[0]

        let below = CGRect(x: 0, y: 249, width: 480, height: 21)
        for t in stride(from: 0.2, through: 1.2, by: 0.2) {
            let frame = try render(overlay, at: t, compositor: compositor)
            #expect(ink(frame, below) == 0, "t=\(t): nothing leaks below the plate")
        }
        let timeline = AnimationSequence.previewTimeline(objects: overlay.objects, order: overlay.animationOrder)
        let settled = try render(overlay, at: arrivedInstant(overlay), compositor: compositor)
        let nameRow = CGRect(x: 90, y: 207, width: 200, height: 18)
        #expect(ink(settled, nameRow) > 40, "the name is on the plate once settled")
    }
}
