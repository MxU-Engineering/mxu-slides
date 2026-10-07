import Foundation

public enum SlideHistory {
    public static let limit = 10

    public static func pushing(_ current: Slide, replacedBy replacement: Slide, reason: String, at now: String) -> Slide {
        var archived = current
        archived.history = nil
        var next = replacement
        next.id = current.id
        next.history = Array(([SlideVersion(at: now, reason: reason, slide: archived)] + (current.history ?? [])).prefix(limit))
        return next
    }

    public static func restoring(_ version: SlideVersion, onto current: Slide, at now: String) -> Slide {
        var restored = version.slide
        restored.keepWords = current.keepWords
        return pushing(current, replacedBy: restored, reason: "Before restore", at: now)
    }
}
