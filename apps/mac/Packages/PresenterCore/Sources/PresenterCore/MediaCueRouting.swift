import Foundation

extension CueMedia {

    public static func dropped(for item: MediaItem) -> CueMedia {
        let layer = firedLayer(kind: item.mediaKind, classification: item.classification)
        var media = CueMedia(mediaId: item.id, layer: layer, classification: item.classification)
        media.mode = layer == .loopingVideos ? .untilReplaced : nil
        return media
    }

    public static func firedLayer(kind: MediaKind, classification: MediaClassification) -> CueMediaLayer {
        if classification == .background {
            .loopingVideos
        } else {
            kind == .image ? .stillGraphics : .videos
        }
    }

    public var resolvedClassification: MediaClassification {
        classification ?? (layer == .videos ? .foreground : .background)
    }

    public static func droppedOnSlide(for item: MediaItem) -> CueMedia {
        CueMedia(
            mediaId: item.id, mode: .untilReplaced, layer: .loopingVideos,
            loops: item.mediaKind == .video ? true : nil, classification: .background)
    }

    public static func droppedAsNewSlide(for item: MediaItem) -> CueMedia {
        CueMedia(
            mediaId: item.id,
            layer: item.mediaKind == .image ? .stillGraphics : .videos,
            loops: item.mediaKind == .video ? false : nil, classification: .foreground)
    }
}

extension Slide {

    public static func droppedMedia(_ item: MediaItem, sectionId: String? = nil) -> Slide {
        Slide(
            id: UUID().uuidString, name: item.name, objects: [],
            background: CueMedia.droppedAsNewSlide(for: item), sectionId: sectionId)
    }
}

extension Presentation {

    public static func droppedMedia(_ items: [MediaItem]) -> Presentation? {
        if let first = items.first {

            Presentation(
                id: UUID().uuidString,
                name: items.count == 1 ? first.name : "Untitled Presentation",
                presentationKind: .deck, themeId: "",
                slides: items.map { Slide.droppedMedia($0) })
        } else {
            nil
        }
    }
}
