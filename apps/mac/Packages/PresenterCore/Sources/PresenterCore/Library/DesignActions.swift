import Foundation

public extension Theme {

    func design(named name: String?) -> Slide? {
        let designs = slides ?? []
        if let name, !name.isEmpty, let match = designs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        } else {
            return designs.first
        }
    }
}

public extension Slide {

    mutating func adoptActions(of design: Slide?, replacing previous: Slide? = nil, newID: () -> String = { UUID().uuidString }) {
        let given = design?.actions ?? []
        let old = previous?.actions ?? []
        var own = actions ?? []
        own.removeAll { action in
            old.contains { $0.sameWork(as: action) } && !given.contains { $0.sameWork(as: action) }
        }
        for action in given where !own.contains(where: { $0.sameWork(as: action) }) {
            var copy = action
            copy.id = newID()
            own.append(copy)
        }
        actions = own.isEmpty ? nil : own
    }
}

public extension Presentation {

    mutating func adoptDesignActions(of theme: Theme?, themes: [String: Theme]) {
        for index in slides.indices where slides[index].unthemed != true {
            let slide = slides[index]
            let previous = themes[themeId(for: slide)]?.design(named: slide.themeSlideName)
            slides[index].adoptActions(of: theme?.design(named: slide.themeSlideName), replacing: previous)
        }
    }

    mutating func applyTheme(_ theme: Theme, toSlides ids: Set<String>, design: String? = nil, themes: [String: Theme]) {
        for index in slides.indices where ids.contains(slides[index].id) {
            let slide = slides[index]
            let previous = themes[themeId(for: slide)]?.design(named: slide.themeSlideName)
            let name = design ?? slide.themeSlideName
            slides[index].themeId = theme.id == themeId ? nil : theme.id
            slides[index].themeSlideName = name
            slides[index].unthemed = nil
            slides[index].adoptActions(of: theme.design(named: name), replacing: previous)
        }
    }

    func slides(_ ids: Set<String>, allFollow themeID: String, design: String? = nil) -> Bool {
        let chosen = slides.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { slide in
            themeId(for: slide) == themeID
                && (design.map { slide.themeSlideName?.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
    }
}

extension SlideAction {

    func sameWork(as other: SlideAction) -> Bool {
        var aligned = other
        aligned.id = id
        return aligned == self
    }
}
