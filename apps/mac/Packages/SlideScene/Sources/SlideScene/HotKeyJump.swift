import Foundation
import PresenterCore

extension SlideSceneBuilder {

    public static func blockSectionNames(
        for presentation: Presentation,
        arrangementId: String? = nil
    ) -> [(start: Int, normalizedName: String)] {
        let sections = presentation.sections ?? []
        func normalized(_ id: String?) -> String {
            guard let id, let section = sections.first(where: { $0.id == id })
            else { return "" }
            return GroupPalette.normalizedName(section.name)
        }
        if let id = arrangementId, !id.isEmpty,
           let arrangement = presentation.arrangements?.first(where: { $0.id == id }),
           !arrangement.sectionIds.isEmpty {
            var result: [(start: Int, normalizedName: String)] = []
            var index = 0
            for sectionId in arrangement.sectionIds {
                result.append((index, normalized(sectionId)))
                index += presentation.slides.count { $0.sectionId == sectionId }
            }
            return result
        }
        var result: [(start: Int, normalizedName: String)] = []
        var lastID: String?
        for (index, slide) in presentation.slides.enumerated() {
            if slide.sectionId != lastID, let id = slide.sectionId,
               sections.contains(where: { $0.id == id }) {
                result.append((index, normalized(id)))
            }
            lastID = slide.sectionId
        }
        return result
    }

    public static func hotKeyJumpStart(
        for presentation: Presentation,
        arrangementId: String? = nil,
        matching normalizedNames: [String],
        liveIndex: Int?
    ) -> Int? {
        let blocks = blockSectionNames(for: presentation, arrangementId: arrangementId)
        let slideCount = arrangedSlides(
            for: presentation, arrangementId: arrangementId).count
        func width(_ index: Int) -> Int {
            let end = index + 1 < blocks.count ? blocks[index + 1].start : slideCount
            return end - blocks[index].start
        }
        let names = Set(normalizedNames)
        let matched = blocks.indices.filter {
            names.contains(blocks[$0].normalizedName) && width($0) > 0
        }
        guard !matched.isEmpty else { return nil }

        var livePill: Int?
        if let liveIndex {
            livePill = blocks.indices.last {
                width($0) > 0 && blocks[$0].start <= liveIndex
                    && liveIndex < blocks[$0].start + width($0)
            }
        }
        if let livePill, let position = matched.firstIndex(of: livePill) {
            return blocks[matched[(position + 1) % matched.count]].start
        }
        return blocks[matched[0]].start
    }
}
