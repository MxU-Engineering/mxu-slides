import Foundation

public enum MediaReferences {
    public static func ids(inObjects objects: [SlideObject]) -> Set<String> {
        var out = Set<String>()
        for object in objects {
            if let id = object.mediaId { out.insert(id) }
            if let id = object.fill?.mediaId { out.insert(id) }
        }
        return out
    }

    public static func ids(inActions actions: [SlideAction]?) -> Set<String> {
        Set((actions ?? []).compactMap(\.mediaId))
    }

    public static func ids(in slide: Slide) -> Set<String> {
        var out = ids(inObjects: slide.objects)
        if let id = slide.background?.mediaId { out.insert(id) }
        if let id = slide.backgroundFill?.mediaId { out.insert(id) }
        out.formUnion(ids(inActions: slide.actions))
        return out
    }

    public static func ids(in presentation: Presentation) -> Set<String> {
        var out = Set<String>()
        if let id = presentation.background?.mediaId { out.insert(id) }
        if let id = presentation.backgroundFill?.mediaId { out.insert(id) }
        for section in presentation.sections ?? [] {
            if let id = section.background?.mediaId { out.insert(id) }
        }
        for slide in presentation.slides { out.formUnion(ids(in: slide)) }
        return out
    }

    public static func ids(in overlay: Overlay) -> Set<String> {
        ids(inObjects: overlay.objects)
    }

    public static func ids(in theme: Theme) -> Set<String> {
        var out = Set<String>()
        for slide in theme.slides ?? [] { out.formUnion(ids(in: slide)) }
        return out
    }

    public static func ids(in layout: ConfidenceLayout) -> Set<String> {
        ids(inObjects: layout.objects)
    }

    public static func ids(in playlist: Playlist) -> Set<String> {
        Set(playlist.entries.filter { $0.refKind == .media }.map(\.refId))
    }

    public static func ids(in service: Service) -> Set<String> {
        Set(ServiceVersions.allItems(service).filter { $0.itemKind == .media }.map(\.refId))
    }

    public static func ids(in combo: ActionCombo) -> Set<String> {
        ids(inActions: combo.actions)
    }

    public static func ids(in trigger: ScheduleTrigger) -> Set<String> {
        ids(inActions: trigger.actions)
    }

    public static func ids(inDocument value: any DocumentEntity) -> Set<String>? {
        switch value {
        case let service as Service: ids(in: service)
        case let presentation as Presentation: ids(in: presentation)
        case let overlay as Overlay: ids(in: overlay)
        case let theme as Theme: ids(in: theme)
        case let layout as ConfidenceLayout: ids(in: layout)
        case let playlist as Playlist: ids(in: playlist)
        case let combo as ActionCombo: ids(in: combo)
        default: nil
        }
    }
}
