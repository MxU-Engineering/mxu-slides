import PresenterCore

public enum EmptyTextPlaceholder {
    public static let text = "Text"

    public static let opacityScale = 0.35

    public static func applied(
        to objects: [SlideObject], editingID: String? = nil
    ) -> [SlideObject] {
        objects.map { object in
            guard object.objectKind == .text, object.text.isEmpty,
                  object.textLink == nil, object.id != editingID
            else { return object }
            var placeholder = object
            placeholder.text = text
            placeholder.opacity = (object.opacity ?? 1) * opacityScale
            return placeholder
        }
    }
}
