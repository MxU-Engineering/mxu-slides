import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public enum Paging {

    public static let stepMarker = "::page::"

    public struct Turn: Equatable, Sendable {
        public var animation: StepAnimation
        public var duration: Double
        public var amount: Double?

        public init(animation: StepAnimation, duration: Double, amount: Double? = nil) {
            self.animation = animation
            self.duration = duration
            self.amount = amount
        }

        public static let cut = Turn(animation: .fade, duration: 0)
        public static let fade = Turn(animation: .fade, duration: 0.35)

        public static func following(_ kind: TransitionKind?, duration: Double) -> Turn {
            switch kind {
            case nil, .cut: .cut
            case .dissolve, .fadeBlack, .fadeWhite, .fadeColor: Turn(animation: .fade, duration: duration)
            case .blurDissolve: Turn(animation: .blur, duration: duration, amount: 24)
            case .filmBurn: Turn(animation: .burn, duration: duration, amount: 1)
            }
        }
    }

    struct Paged {
        var objects: [SlideObject]
        var order: [String]?

        var pageCount: Int
    }

    static func paged(
        objects: [SlideObject], template: Slide?, theme: Theme?, order: [String]?,
        canvas: CGSize, turn: Turn = .cut
    ) -> Paged {
        let pagesByIndex = pages(of: objects, template: template, theme: theme, canvas: canvas)
        guard !pagesByIndex.isEmpty else { return Paged(objects: objects, order: order, pageCount: 1) }
        var result = objects
        let count = pagesByIndex.values.map(\.count).max() ?? 1
        for (index, pages) in pagesByIndex { result[index].text = pages[0] }
        var stepIDs: [String] = []
        for page in 2...count {
            var leads = true
            for index in pagesByIndex.keys.sorted() {
                guard let pages = pagesByIndex[index], page <= pages.count else { continue }
                var target = objects[index]
                target.text = pages[page - 1]
                target.animationSteps = nil
                let id = "\(objects[index].id)\(stepMarker)\(page)"
                let step = AnimationStep(
                    id: id, kind: .morph, animation: turn.animation, trigger: leads ? .onClick : .withPrevious,
                    durationSeconds: turn.duration, ramp: .both, amount: turn.amount, toObject: target)
                result[index].animationSteps = (result[index].animationSteps ?? []) + [step]
                stepIDs.append(id)
                leads = false
            }
        }
        return Paged(objects: result, order: placingPages(in: order, objects: result, template: template, pageStepIDs: stepIDs), pageCount: count)
    }

    private static func pages(
        of objects: [SlideObject], template: Slide?, theme: Theme?, canvas: CGSize
    ) -> [Int: [String]] {
        guard let template else { return [:] }
        let assignments = SlideSceneBuilder.placeholderAssignments(for: objects, in: template)
        var result: [Int: [String]] = [:]
        for (index, object) in objects.enumerated() {
            guard object.objectKind == .text, object.hidden != true, !object.text.isEmpty,
                  let placeholder = assignments[object.id], placeholder.textStyle?.pageOnClick == true
            else { continue }
            let styled = SlideSceneBuilder.styledText(for: object, theme: theme, placeholder: placeholder)
            let frame = SlideSceneBuilder.frame(for: object, placeholder: placeholder, in: canvas)
            let pages = TextRasterizer.pages(for: styled, sceneFrame: frame.size)
            if pages.count > 1 { result[index] = pages }
        }
        return result
    }

    private static func placingPages(in order: [String]?, objects: [SlideObject], template: Slide?, pageStepIDs: [String]) -> [String]? {
        guard !pageStepIDs.isEmpty else { return order }

        let stack = SlideSceneBuilder.composedStack(for: objects, in: template).map(\.object)
        let entries = AnimationSequence.orderedEntries(objects: stack, order: order)
            .filter { !$0.step.id.contains(stepMarker) }
        var ids = entries.map(\.step.id)
        let leave = entries.firstIndex {
            $0.step.trigger == .onDismiss || ($0.step.kind == .out && $0.step.trigger == .onClick)
        }
        ids.insert(contentsOf: pageStepIDs, at: leave ?? ids.count)
        return ids
    }

    public static func pages(of slide: Slide, theme: Theme?, canvas: CGSize = SlideSceneBuilder.canvasSize) -> [Slide] {
        pagesOfRead(slide, theme: theme, canvas: canvas)
    }

    public static func pages(of slide: Slide, through look: Theme?, from originalTheme: Theme?, canvas: CGSize = SlideSceneBuilder.canvasSize) -> [Slide] {

        let read: Slide = if let look {
            PlaceholderAnimations.overrideSlide(slide, originalTheme: originalTheme, overrideTheme: look)
        } else {
            slide
        }
        return pagesOfRead(read, theme: look, canvas: canvas)
    }

    private static func pagesOfRead(_ slide: Slide, theme: Theme?, canvas: CGSize) -> [Slide] {
        let template = SlideSceneBuilder.themeSlide(for: slide, theme: theme)
        let pagesByIndex = pages(of: slide.objects, template: template, theme: theme, canvas: canvas)
        guard let count = pagesByIndex.values.map(\.count).max(), count > 1 else { return [slide] }
        return (1...count).map { page in
            var copy = slide
            if page > 1 { copy.id = "\(slide.id)\(stepMarker)\(page)" }
            for (index, pages) in pagesByIndex { copy.objects[index].text = pages[min(page, pages.count) - 1] }
            return copy
        }
    }

    public static func pageCount(of slide: Slide, theme: Theme?, canvas: CGSize = SlideSceneBuilder.canvasSize) -> Int {
        pages(of: slide, theme: theme, canvas: canvas).count
    }
}
