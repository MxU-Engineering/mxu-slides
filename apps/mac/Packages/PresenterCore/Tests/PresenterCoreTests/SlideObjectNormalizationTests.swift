import Foundation
import Testing
@testable import PresenterCore

@Test func mediaObjectNormalizesToShapeWithMediaFill() {
    let object = SlideObject(
        id: "o1", objectKind: .media, name: "Loop", text: "",
        x: 10, y: 20, width: 300, height: 200,
        rotationDegrees: 15, opacity: 0.5,
        mediaId: "media-1", mediaScaleMode: .fit,
        mediaSourceRect: MediaSourceRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
        loops: true
    )
    let normalized = SlideObjectNormalization.normalized(object)
    #expect(normalized.objectKind == .shape)
    #expect(normalized.fill?.fillKind == .media)
    #expect(normalized.fill?.mediaId == "media-1")
    #expect(normalized.fill?.mediaScaleMode == .fit)
    #expect(normalized.fill?.mediaSourceRect == MediaSourceRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
    #expect(normalized.fill?.loops == true)

    #expect(normalized.mediaId == nil)
    #expect(normalized.mediaScaleMode == nil)
    #expect(normalized.mediaSourceRect == nil)
    #expect(normalized.loops == nil)
    #expect(normalized.x == 10 && normalized.rotationDegrees == 15 && normalized.opacity == 0.5)

    #expect(SlideObjectNormalization.normalized(normalized) == normalized)
}

@Test func liveInputObjectNormalizesSourcesIntoFill() {
    let named = SlideObject(
        id: "o2", objectKind: .liveInput, name: "Camera", text: "",
        liveInputId: "input-1"
    )
    let normalizedNamed = SlideObjectNormalization.normalized(named)
    #expect(normalizedNamed.objectKind == .shape)
    #expect(normalizedNamed.fill?.fillKind == .media)
    #expect(normalizedNamed.fill?.liveInputId == "input-1")
    #expect(normalizedNamed.liveInputId == nil)

    let legacyDevice = SlideObject(
        id: "o3", objectKind: .liveInput, name: "NDI", text: "",
        mediaScaleMode: .fit,
        captureSourceKind: .ndi, captureSourceId: "cam-9"
    )
    let normalizedDevice = SlideObjectNormalization.normalized(legacyDevice)
    #expect(normalizedDevice.fill?.captureSourceKind == .ndi)
    #expect(normalizedDevice.fill?.captureSourceId == "cam-9")
    #expect(normalizedDevice.fill?.mediaScaleMode == .fit)

    let mirror = SlideObject(
        id: "o4", objectKind: .media, name: "Mirror", text: "",
        screenSourceId: "screen-b"
    )
    #expect(SlideObjectNormalization.normalized(mirror).fill?.screenSourceId == "screen-b")
}

@Test func unassignedLiveInputKeepsThePlaceholderRead() {

    let object = SlideObject(id: "o5", objectKind: .liveInput, name: "Live Input", text: "")
    let normalized = SlideObjectNormalization.normalized(object)
    #expect(normalized.fill?.captureSourceKind == .camera)
    #expect(normalized.fill?.captureSourceId == "")

    #expect(normalized.fill?.mediaSourceRect == nil)
}

@Test func textAndShapeObjectsPassThroughUntouched() {
    let text = SlideObject(id: "t", objectKind: .text, name: "Text", text: "Hi")
    #expect(SlideObjectNormalization.normalized(text) == text)
    let shape = SlideObject(
        id: "s", objectKind: .shape, name: "Shape", text: "",
        fill: ObjectFill(fillKind: .solid, colorHex: "#FF0000FF")
    )
    #expect(SlideObjectNormalization.normalized(shape) == shape)
    #expect(!SlideObjectNormalization.needsNormalization(shape))
}

@LibraryActor private func makeLibrary() throws -> (Library, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try Library(rootURL: root), root)
}

private func legacyPresentation(_ id: String) -> Presentation {
    Presentation(
        id: id, name: "Legacy", presentationKind: .deck, themeId: "",
        slides: [Slide(id: "\(id)-s1", name: "One", objects: [
            SlideObject(id: "\(id)-text", objectKind: .text, name: "Text", text: "Hello"),
            SlideObject(id: "\(id)-media", objectKind: .media, name: "Pic", text: "", mediaId: "m1", loops: true),
            SlideObject(id: "\(id)-live", objectKind: .liveInput, name: "Cam", text: "", liveInputId: "in1"),
        ])]
    )
}

@LibraryActor @Test func migrationNormalizesEverySlideBearingKindOnceAndOnlyOnce() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    try library.create(legacyPresentation("p1"))
    try library.create(Theme(
        id: "th1", name: "Theme", fontFamily: "Helvetica", fontSize: 96,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
        slides: [Slide(id: "th1-s", name: "Alerts", objects: [
            SlideObject(id: "th1-media", objectKind: .media, name: "Decor", text: "", mediaId: "m2"),
        ])]
    ))
    try library.create(Overlay(id: "ov1", name: "Bug", objects: [
        SlideObject(id: "ov1-media", objectKind: .media, name: "Logo", text: "", mediaId: "m3"),
    ]))
    try library.create(ConfidenceLayout(id: "cl1", name: "Stage", objects: [
        SlideObject(id: "cl1-media", objectKind: .media, name: "Motion", text: "", mediaId: "m4"),
    ]))

    try library.create(Presentation(
        id: "p2", name: "Modern", presentationKind: .deck, themeId: "", slides: []
    ))

    #expect(try library.normalizeMediaObjects() == 4)

    let migrated = try library.open(Presentation.self, id: "p1").value
    #expect(migrated.slides[0].objects.allSatisfy { $0.objectKind != .media && $0.objectKind != .liveInput })
    #expect(migrated.slides[0].objects[1].fill?.mediaId == "m1")
    #expect(migrated.slides[0].objects[1].fill?.loops == true)
    #expect(migrated.slides[0].objects[2].fill?.liveInputId == "in1")
    #expect(try library.open(Theme.self, id: "th1").value.slides?[0].objects[0].fill?.mediaId == "m2")
    #expect(try library.open(Overlay.self, id: "ov1").value.objects[0].fill?.mediaId == "m3")
    #expect(try library.open(ConfidenceLayout.self, id: "cl1").value.objects[0].fill?.mediaId == "m4")

    let headsBefore = try library.open(Presentation.self, id: "p1").document.heads()
    #expect(try library.normalizeMediaObjects() == 0)
    #expect(try library.open(Presentation.self, id: "p1").document.heads() == headsBefore)
}
