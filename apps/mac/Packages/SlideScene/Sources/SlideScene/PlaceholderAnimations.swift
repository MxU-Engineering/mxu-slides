import Foundation
import PresenterCore

public enum PlaceholderAnimations {
    public struct Composition: Equatable, Sendable {

        public var objects: [SlideObject]

        public var order: [String]?
    }

    public static func composition(
        objects: [SlideObject],
        template: Slide?,
        slideOrder: [String]?
    ) -> Composition {
        guard let template else {
            return Composition(objects: objects, order: slideOrder)
        }
        let assignments = SlideSceneBuilder.placeholderAssignments(
            for: objects, in: template
        )

        var donatedIDs: [String: [String]] = [:]
        var result = objects
        for (index, object) in objects.enumerated() {
            guard object.objectKind == .text,
                  (object.animationSteps ?? []).isEmpty,
                  let animationSteps = assignments[object.id]?.animationSteps, !animationSteps.isEmpty
            else { continue }
            result[index].animationSteps = animationSteps.map { step in
                var donated = step
                donated.id = "\(object.id)::\(step.id)"
                donated.ranges = nil
                donatedIDs[step.id, default: []].append(donated.id)
                return donated
            }
        }
        if let slideOrder {
            return Composition(objects: result, order: slideOrder)
        }
        let order = template.animationOrder.map { ids in
            ids.flatMap { donatedIDs[$0] ?? [$0] }
        }
        return Composition(objects: result, order: order)
    }

    public static func stackComposition(slide: Slide, theme: Theme?, paging: Bool = true) -> Composition {
        let template = SlideSceneBuilder.themeSlide(for: slide, theme: theme)
        let donated = composition(
            objects: slide.objects, template: template, slideOrder: slide.animationOrder
        )
        guard paging else {
            let stack = SlideSceneBuilder.composedStack(for: donated.objects, in: template)
            return Composition(objects: stack.map(\.object), order: donated.order)
        }

        let paged = Paging.paged(
            objects: donated.objects, template: template, theme: theme, order: donated.order,
            canvas: SlideSceneBuilder.canvasSize)
        let stack = SlideSceneBuilder.composedStack(for: paged.objects, in: template)
        return Composition(objects: stack.map(\.object), order: paged.order)
    }

    public static func overrideComposition(slide: Slide, originalTheme: Theme?, overrideTheme: Theme, paging: Bool = true) -> Composition {
        stackComposition(slide: overrideSlide(slide, originalTheme: originalTheme, overrideTheme: overrideTheme), theme: overrideTheme, paging: paging)
    }

    public static func overrideSlide(_ slide: Slide, originalTheme: Theme?, overrideTheme: Theme) -> Slide {
        var rendered = slide.rendered(throughOverride: overrideTheme)
        rendered.objects = ThemeOverride.overrideObjects(
            for: rendered, objects: rendered.objects, originalTheme: originalTheme, overrideTheme: overrideTheme)
        return rendered
    }

    public static func compositions(slide: Slide, themes: [Theme?], paging: Bool = true) -> [Composition] {
        let own = themes.first ?? nil
        return themes.enumerated().map { index, theme in
            if index > 0, let theme {
                return overrideComposition(slide: slide, originalTheme: own, overrideTheme: theme, paging: paging)
            }
            return stackComposition(slide: slide, theme: theme, paging: paging)
        }
    }

    public static func clickCount(slide: Slide, themes: [Theme?], paging: Bool = true) -> Int {
        compositions(slide: slide, themes: themes, paging: paging).map { composition in
            AnimationSequence.clickCount(objects: composition.objects, order: composition.order)
        }.max() ?? 0
    }

    public static func advanceCount(slide: Slide, themes: [Theme?], paging: Bool = true) -> Int {
        let clicks = clickCount(slide: slide, themes: themes, paging: paging)
        let hasExit = compositions(slide: slide, themes: themes, paging: paging).contains { composition in
            AnimationSequence.hasExitGroup(objects: composition.objects, order: composition.order)
        }
        return clicks + (hasExit ? 1 : 0)
    }

    public static func hasAnimationSteps(slide: Slide, themes: [Theme?]) -> Bool {
        compositions(slide: slide, themes: themes).contains { composition in
            AnimationSequence.hasAnimationSteps(composition.objects)
        }
    }
}
