import Foundation

public extension Presentation {

    func themeId(for slide: Slide) -> String {
        if slide.unthemed == true {
            ""
        } else if let own = slide.themeId, !own.isEmpty {
            own
        } else {
            themeId
        }
    }

    var hasSlideThemes: Bool {
        slides.contains { !($0.themeId ?? "").isEmpty || $0.unthemed == true }
    }

    mutating func clearSlideThemes() {
        for index in slides.indices { slides[index].themeId = nil }
    }
}

public extension Slide {
    func overrideDesignName(forTheme themeId: String) -> String? {
        overrideDesigns?.first { $0.themeId == themeId }?.themeSlideName
    }

    func rendered(throughOverride theme: Theme) -> Slide {
        guard let design = overrideDesignName(forTheme: theme.id) else { return self }
        var slide = self
        slide.themeSlideName = design
        return slide
    }

    mutating func setOverrideDesign(_ name: String?, forTheme themeId: String) {
        var designs = (overrideDesigns ?? []).filter { $0.themeId != themeId }
        if let name, !name.isEmpty { designs.append(OverrideDesign(themeId: themeId, themeSlideName: name)) }
        overrideDesigns = designs.isEmpty ? nil : designs
    }
}
