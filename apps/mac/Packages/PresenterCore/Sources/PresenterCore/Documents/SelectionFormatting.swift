import Foundation

public enum SelectionFormatting {

    public static func selectedObjects(in objects: [SlideObject], ids: Set<String>) -> [SlideObject] {
        objects.filter { ids.contains($0.id) }.map(SlideObjectNormalization.normalized)
    }

    public static func primary(in objects: [SlideObject], ids: Set<String>) -> SlideObject? {
        selectedObjects(in: objects, ids: ids).first
    }

    public static func sharesKind(_ objects: [SlideObject]) -> Bool {
        let textCount = objects.filter { $0.objectKind == .text }.count
        return textCount == 0 || textCount == objects.count
    }

    public static func isMixed<T: Equatable>(_ objects: [SlideObject], _ read: (SlideObject) -> T) -> Bool {
        let values = objects.map(read)
        return values.contains { $0 != values.first }
    }
}
