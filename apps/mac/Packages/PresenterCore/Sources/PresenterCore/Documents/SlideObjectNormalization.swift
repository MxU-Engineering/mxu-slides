import Foundation

public enum SlideObjectNormalization {

    public static func needsNormalization(_ object: SlideObject) -> Bool {
        object.objectKind == .media || object.objectKind == .liveInput
            || object.builds != nil
            || object.textLink?.includeBuilds != nil
    }

    public static func normalized(_ object: SlideObject) -> SlideObject {
        guard needsNormalization(object) else { return object }
        var normalized = object

        if let legacySteps = normalized.builds {
            normalized.animationSteps = normalized.animationSteps ?? legacySteps
            normalized.builds = nil
        }
        if var link = normalized.textLink, let legacyInclude = link.includeBuilds {
            link.includeSteps = link.includeSteps ?? legacyInclude
            link.includeBuilds = nil
            normalized.textLink = link
        }
        guard object.objectKind == .media || object.objectKind == .liveInput else {
            return normalized
        }
        let wasLiveInput = object.objectKind == .liveInput
        normalized.objectKind = .shape

        if normalized.fill == nil {
            var fill = ObjectFill(fillKind: .media)
            fill.mediaId = object.mediaId
            fill.mediaScaleMode = object.mediaScaleMode

            fill.mediaSourceRect = wasLiveInput ? nil : object.mediaSourceRect
            fill.loops = object.loops
            fill.captureSourceKind = object.captureSourceKind
            fill.captureSourceId = object.captureSourceId
            fill.screenSourceId = object.screenSourceId
            fill.liveInputId = object.liveInputId
            if wasLiveInput, !hasLiveSource(fill), fill.mediaId?.isEmpty != false {

                fill.captureSourceKind = fill.captureSourceKind ?? .camera
                fill.captureSourceId = fill.captureSourceId ?? ""
            }
            normalized.fill = fill
        }
        normalized.mediaId = nil
        normalized.mediaScaleMode = nil
        normalized.mediaSourceRect = nil
        normalized.loops = nil
        normalized.captureSourceKind = nil
        normalized.captureSourceId = nil
        normalized.screenSourceId = nil
        normalized.liveInputId = nil
        return normalized
    }

    private static func hasLiveSource(_ fill: ObjectFill) -> Bool {
        fill.liveInputId?.isEmpty == false
            || fill.captureSourceId?.isEmpty == false
            || fill.captureSourceKind != nil
            || fill.screenSourceId?.isEmpty == false
    }

    public static func normalized(_ objects: [SlideObject]) -> [SlideObject] {
        objects.map(normalized)
    }

    public static func animationSteps(of object: SlideObject) -> [AnimationStep]? {
        object.animationSteps ?? object.builds
    }

    public static func normalized(_ slide: Slide) -> Slide {
        var slide = slide
        slide.objects = normalized(slide.objects)
        if let legacy = slide.buildOrder {
            slide.animationOrder = slide.animationOrder ?? legacy
            slide.buildOrder = nil
        }
        return slide
    }

    public static func needsNormalization(_ slide: Slide) -> Bool {
        slide.buildOrder != nil || slide.objects.contains(where: needsNormalization)
    }

    public static func normalized(_ overlay: Overlay) -> Overlay {
        var overlay = overlay
        overlay.objects = normalized(overlay.objects)
        if let legacy = overlay.buildOrder {
            overlay.animationOrder = overlay.animationOrder ?? legacy
            overlay.buildOrder = nil
        }
        return overlay
    }

    public static func needsNormalization(_ overlay: Overlay) -> Bool {
        overlay.buildOrder != nil || overlay.objects.contains(where: needsNormalization)
    }

    public static func normalized(_ layout: ConfidenceLayout) -> ConfidenceLayout {
        var layout = layout
        layout.objects = normalized(layout.objects)
        if let legacy = layout.buildOrder {
            layout.animationOrder = layout.animationOrder ?? legacy
            layout.buildOrder = nil
        }
        return layout
    }

    public static func needsNormalization(_ layout: ConfidenceLayout) -> Bool {
        layout.buildOrder != nil || layout.objects.contains(where: needsNormalization)
    }
}
