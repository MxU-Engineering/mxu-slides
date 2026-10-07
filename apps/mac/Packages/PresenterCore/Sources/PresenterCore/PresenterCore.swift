public enum PresenterCore {
    public static let version = "0.1.0"

    public static func sampleSlide() -> Slide {
        Slide(
            id: "slide-1",
            name: "Welcome",
            objects: [
                SlideObject(id: "obj-1", objectKind: .text, name: "Title", text: "Welcome"),
                SlideObject(
                    id: "obj-2", objectKind: .shape, name: "Background loop", text: "",
                    fill: ObjectFill(fillKind: .media)),
            ]
        )
    }
}
