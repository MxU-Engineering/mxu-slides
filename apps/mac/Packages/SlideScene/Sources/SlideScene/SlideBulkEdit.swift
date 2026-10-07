import Foundation
import PresenterCore

public enum SlideBulkEdit {

    public static func slideIDs(
        occurrences: some Sequence<Int>, slides: [Slide]
    ) -> [String] {
        var seen = Set<String>()
        return occurrences.sorted().compactMap { index in
            guard slides.indices.contains(index) else { return nil }
            let id = slides[index].id
            return seen.insert(id).inserted ? id : nil
        }
    }

    @discardableResult
    public static func addAction(
        _ template: SlideAction, to slideIDs: [String], in presentation: inout Presentation,
        actionIDs: [String: String] = [:]
    ) -> [(slideID: String, actionID: String)] {
        var added: [(slideID: String, actionID: String)] = []
        let targets = Set(slideIDs)
        for index in presentation.slides.indices
        where targets.contains(presentation.slides[index].id) {
            var action = template
            action.id = actionIDs[presentation.slides[index].id] ?? UUID().uuidString
            var actions = presentation.slides[index].actions ?? []
            actions.append(action)
            presentation.slides[index].actions = actions
            added.append((presentation.slides[index].id, action.id))
        }
        return added
    }

    public static func actionKinds(
        on slideIDs: [String], in slides: [Slide]
    ) -> [SlideActionKind] {
        let targets = Set(slideIDs)
        var kinds: [SlideActionKind] = []
        for slide in slides where targets.contains(slide.id) {
            for action in slide.actions ?? [] where !kinds.contains(action.kind) {
                kinds.append(action.kind)
            }
        }
        return kinds
    }

    public static func removeActions(
        ofKind kind: SlideActionKind?, from slideIDs: [String],
        in presentation: inout Presentation
    ) {
        let targets = Set(slideIDs)
        for index in presentation.slides.indices
        where targets.contains(presentation.slides[index].id) {
            var actions = presentation.slides[index].actions ?? []
            actions.removeAll { kind == nil || $0.kind == kind }
            presentation.slides[index].actions = actions.isEmpty ? nil : actions
        }
    }

    public static func setAutoAdvance(
        _ advance: AutoAdvance?, on slideIDs: [String], in presentation: inout Presentation
    ) {
        let targets = Set(slideIDs)
        for index in presentation.slides.indices
        where targets.contains(presentation.slides[index].id) {
            presentation.slides[index].autoAdvance = advance
        }
    }

    public static func duplicateSlides(
        _ slideIDs: [String], in presentation: inout Presentation
    ) {
        duplicateSlides(slideIDs, in: &presentation.slides)
    }

    public static func duplicateSlides(_ slideIDs: [String], in slides: inout [Slide]) {
        let targets = Set(slideIDs)

        for index in slides.indices.reversed() where targets.contains(slides[index].id) {
            slides.insert(slides[index].freshIDCopy(), at: index + 1)
        }
    }

    @discardableResult
    public static func deleteSlides(
        _ slideIDs: [String], in presentation: inout Presentation
    ) -> Bool {
        deleteSlides(slideIDs, in: &presentation.slides)
    }

    @discardableResult
    public static func deleteSlides(_ slideIDs: [String], in slides: inout [Slide]) -> Bool {
        let targets = Set(slideIDs)
        let remaining = slides.filter { !targets.contains($0.id) }
        let deletes = !remaining.isEmpty && remaining.count < slides.count
        if deletes {
            slides = remaining
        }
        return deletes
    }

    public static let slideDragPrefix = "mxuslide::"

    public static func slideDragPayload(presentationID: String, slideID: String) -> String {
        slideDragPrefix + presentationID + "::" + slideID
    }

    public static func draggedSlide(
        in payload: String
    ) -> (presentationID: String, slideID: String)? {
        let parts = payload.components(separatedBy: "::")
        if parts.count == 3, payload.hasPrefix(slideDragPrefix),
           !parts[1].isEmpty, !parts[2].isEmpty {
            return (parts[1], parts[2])
        } else {
            return nil
        }
    }

    public static func insertSlides(
        _ slides: [Slide], before slideID: String?, in presentation: inout Presentation
    ) {
        let target = slideID.flatMap { id in
            presentation.slides.firstIndex { $0.id == id }
        } ?? presentation.slides.count
        let neighbor = target < presentation.slides.count
            ? presentation.slides[target] : presentation.slides.last
        let landing = slides.map { slide in
            var slide = slide
            slide.sectionId = neighbor?.sectionId
            return slide
        }
        presentation.slides.insert(contentsOf: landing, at: target)
    }

    public static func insertSlides(
        _ slides: [Slide], after slideID: String?, in presentation: inout Presentation
    ) {
        let anchor = slideID.flatMap { id in
            presentation.slides.firstIndex { $0.id == id }
        } ?? presentation.slides.count - 1
        let neighbor = presentation.slides.indices.contains(anchor)
            ? presentation.slides[anchor] : presentation.slides.last
        let landing = slides.map { slide in
            var slide = slide
            slide.sectionId = neighbor?.sectionId
            return slide
        }
        presentation.slides.insert(contentsOf: landing, at: min(anchor + 1, presentation.slides.count))
    }

    public static func moveSlide(
        _ slideID: String, before anchorID: String?, in presentation: inout Presentation
    ) {
        if slideID != anchorID,
           let from = presentation.slides.firstIndex(where: { $0.id == slideID }) {
            let slide = presentation.slides.remove(at: from)
            insertSlides([slide], before: anchorID, in: &presentation)
        }
    }

    public static func moveSlide(
        _ slideID: String, after anchorID: String, in presentation: inout Presentation
    ) {
        if slideID != anchorID,
           let from = presentation.slides.firstIndex(where: { $0.id == slideID }) {
            let slide = presentation.slides.remove(at: from)
            insertSlides([slide], after: anchorID, in: &presentation)
        }
    }

    public static func batch(
        for id: String, selected: Set<String>, slides: [Slide]
    ) -> [String] {
        if selected.count > 1, selected.contains(id) {
            return slides.map(\.id).filter { selected.contains($0) }
        } else {
            return [id]
        }
    }

    public static func uniqueThemeSlideName(_ name: String, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var candidate = name
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return candidate
    }

    public static func adoptedForTheme(_ slides: [Slide], existing: [Slide]) -> [Slide] {
        var names = existing.map(\.name)
        return slides.map { slide in
            var adopted = slide
            adopted.sectionId = nil
            let base = slide.name.isEmpty ? "Category" : slide.name
            adopted.name = uniqueThemeSlideName(base, among: names)
            names.append(adopted.name)
            return adopted
        }
    }

    @discardableResult
    public static func moveSlides(
        _ slideIDs: [String], from source: inout [Slide], to destination: inout [Slide]
    ) -> Bool {
        let targets = Set(slideIDs)
        let moving = source.filter { targets.contains($0.id) }
        let remaining = source.filter { !targets.contains($0.id) }
        if moving.isEmpty || remaining.isEmpty {
            return false
        } else {
            source = remaining
            destination += adoptedForTheme(moving, existing: destination)
            return true
        }
    }
}

extension Slide {

    public func freshIDCopy() -> Slide {
        var copy = self
        copy.id = UUID().uuidString
        copy.objects = copy.objects.map { object in
            var object = object
            object.id = UUID().uuidString
            return object
        }
        return copy
    }
}
