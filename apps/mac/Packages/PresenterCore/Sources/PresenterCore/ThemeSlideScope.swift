import Foundation

extension Theme {

    public func scoped(toSlideFolder folder: String?) -> Theme {
        guard let folder, !folder.isEmpty else { return self }
        let matching = (slides ?? []).filter {
            ($0.folder ?? "").caseInsensitiveCompare(folder) == .orderedSame
        }
        guard !matching.isEmpty else { return self }
        var scoped = self
        scoped.slides = matching
        return scoped
    }

    public func scoped(toSlideID slideID: String?) -> Theme {
        guard let slideID, !slideID.isEmpty,
              let slide = (slides ?? []).first(where: { $0.id == slideID })
        else { return self }
        var scoped = self
        scoped.slides = [slide]
        return scoped
    }

    public func hasSlide(id slideID: String) -> Bool {
        (slides ?? []).contains { $0.id == slideID }
    }

    public func hasSlideFolder(_ folder: String) -> Bool {
        (slides ?? []).contains {
            ($0.folder ?? "").caseInsensitiveCompare(folder) == .orderedSame
        }
    }

    public var slideFolders: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for slide in slides ?? [] {
            guard let folder = slide.folder, !folder.isEmpty,
                  seen.insert(folder.lowercased()).inserted else { continue }
            result.append(folder)
        }
        return result
    }
}
