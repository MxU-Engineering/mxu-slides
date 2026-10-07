import Foundation

public enum NewSlide {

    public static func blank(sectionId: String?, id: String = UUID().uuidString) -> Slide {
        var slide = Slide(id: id, name: "", objects: [], sectionId: sectionId)
        slide.unthemed = true
        return slide
    }

    public static func fromDesign(
        _ design: Slide, themeId: String, deckThemeId: String, sectionId: String?,
        id: String = UUID().uuidString, objectID: () -> String = { UUID().uuidString }
    ) -> Slide {
        let boxes = design.objects
            .filter { $0.objectKind == .text }
            .map { placeholder in
                SlideObject(id: objectID(), objectKind: .text, name: placeholder.name, text: "")
            }
        var slide = Slide(
            id: id, name: "", objects: boxes, sectionId: sectionId,
            themeSlideName: design.name, themeId: themeId == deckThemeId ? nil : themeId)
        slide.adoptActions(of: design)
        return slide
    }

    public static func preview(of design: Slide, themeId: String) -> Slide {
        let id = "newSlide|\(themeId)|\(design.id)"
        let boxes = design.objects
            .filter { $0.objectKind == .text }
            .map { SlideObject(id: "\(id)|\($0.id)", objectKind: .text, name: $0.name, text: $0.text) }
        return Slide(id: id, name: design.name, objects: boxes, themeSlideName: design.name)
    }
}

public enum NewSlideChoice: Equatable, Sendable {
    case blank
    case design(themeId: String, design: Slide)

    public func slide(sectionId: String?, deckThemeId: String) -> Slide {
        switch self {
        case .blank:
            NewSlide.blank(sectionId: sectionId)
        case .design(let themeId, let design):
            NewSlide.fromDesign(design, themeId: themeId, deckThemeId: deckThemeId, sectionId: sectionId)
        }
    }
}

public struct NewSlideRoute: Equatable, Sendable {

    public var contextID: String?
    public var occurrence: Int?

    public init(contextID: String? = nil, occurrence: Int? = nil) {
        self.contextID = contextID
        self.occurrence = occurrence
    }

    public func answers(_ contextID: String, contexts: [String], isHostTarget: Bool) -> Bool {
        if let pointed = self.contextID, contexts.contains(pointed) {
            pointed == contextID
        } else {
            isHostTarget
        }
    }

    public func anchor(in contextID: String, selected: Set<Int>, count: Int) -> Int? {
        if let last = selected.max(), last < count {
            last
        } else if self.contextID == contextID, let occurrence, occurrence < count {
            occurrence
        } else {
            nil
        }
    }
}

public enum ThemeExplorer {
    public enum Place: Hashable, Sendable {
        case themes
        case theme(String)
        case folder(themeId: String, name: String)
    }

    public struct Folder: Equatable, Sendable {
        public let name: String
        public let designs: [Slide]
    }

    public struct Match: Equatable, Sendable {
        public let theme: Theme
        public let design: Slide
    }

    public static func folders(in theme: Theme) -> [Folder] {
        var names: [String] = []
        var designs: [String: [Slide]] = [:]
        for design in theme.slides ?? [] {
            if let folder = design.folder, !folder.isEmpty {
                if designs[folder] == nil { names.append(folder) }
                designs[folder, default: []].append(design)
            }
        }
        return names.map { Folder(name: $0, designs: designs[$0] ?? []) }
    }

    public static func looseDesigns(in theme: Theme) -> [Slide] {
        (theme.slides ?? []).filter { ($0.folder ?? "").isEmpty }
    }

    public static func designs(in theme: Theme, folder: String) -> [Slide] {
        (theme.slides ?? []).filter { $0.folder == folder }
    }

    public static func search(_ query: String, in themes: [Theme]) -> [Match] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [Match] = []
        if !words.isEmpty {
            for theme in themes {
                for design in theme.slides ?? [] {
                    let haystack = [theme.name, design.folder ?? "", design.name].joined(separator: " ").lowercased()
                    if words.allSatisfy({ haystack.contains($0) }) {
                        matches.append(Match(theme: theme, design: design))
                    }
                }
            }
        }
        return matches
    }
}
