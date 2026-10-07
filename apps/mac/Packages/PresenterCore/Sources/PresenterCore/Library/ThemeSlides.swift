import Foundation

public extension Theme {

    static func defaultSlides() -> [Slide] {
        ["Lyrics", "Bible", "Announcements", "Sermon Points"].map { category in
            Slide(
                id: UUID().uuidString,
                name: category,
                objects: [
                    SlideObject(
                        id: UUID().uuidString, objectKind: .text,
                        name: "Text Placeholder", text: "Sample \(category)"
                    ),
                ]
            )
        }
    }
}
