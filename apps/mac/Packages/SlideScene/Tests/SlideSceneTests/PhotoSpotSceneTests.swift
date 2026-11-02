import CoreGraphics
import Foundation
import PresenterCore
@testable import RenderEngine
import Testing
@testable import SlideScene

private func spot(_ id: String, x: Double, y: Double, w: Double = 400, h: Double = 300) -> SlideObject {
    SlideObject(
        id: id, objectKind: .shape, name: "Shape \(id)", text: "", x: x, y: y, width: w, height: h,
        shapeKind: .roundedRectangle, cornerRadius: 12, fill: ObjectFill(fillKind: .solid, colorHex: "#333333FF"),
        stroke: ObjectStroke(colorHex: "#FFFFFFFF", width: 4), photoSpot: true)
}

private let design = Slide(id: "d", name: "3 Photos", objects: [
    spot("right", x: 1000, y: 100),
    spot("low", x: 100, y: 700),
    spot("left", x: 100, y: 120),
    SlideObject(id: "plate", objectKind: .shape, name: "Plate", text: "", x: 0, y: 0, width: 1920, height: 80),
])

@Test func picturesFillTheSpotsInReadingOrder() {
    #expect(design.photoSpots.map(\.id) == ["left", "right", "low"])
    let first = SlideObject.photo(mediaId: "m1", scale: .scaleAndBlur)
    let second = SlideObject.photo(mediaId: "m2", scale: .fit)
    let stack = SlideSceneBuilder.composedStack(for: [first, second], in: design)
    let photos = stack.filter { !$0.fromTheme }.map(\.object)
    #expect(photos.map(\.id).sorted() == [first.id, second.id].sorted())
    let byId = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    #expect(byId[first.id]?.x == 100 && byId[first.id]?.y == 120, "the first picture takes the left spot")
    #expect(byId[second.id]?.x == 1000, "the second takes the right one")
    #expect(byId[first.id]?.fill?.mediaId == "m1" && byId[first.id]?.stroke?.width == 4 && byId[first.id]?.cornerRadius == 12)

    #expect(!stack.contains { $0.object.id == "low" })
    #expect(stack.contains { $0.fromTheme && $0.object.id == "plate" })
}

@Test func aPictureMovedByHandKeepsItsFrame() {
    var photo = SlideObject.photo(mediaId: "m1", scale: nil)
    (photo.x, photo.y, photo.width, photo.height) = (5, 6, 7, 8)
    let merged = SlideSceneBuilder.composedStack(for: [photo], in: design).first { !$0.fromTheme }?.object
    #expect(merged?.x == 5 && merged?.height == 8)
}

@Test func detachingKeepsThePicturesWhereTheyDrew() {
    let slide = Slide(id: "s", name: "", objects: [SlideObject.photo(mediaId: "m1", scale: nil)], themeSlideName: "3 Photos")
    let theme = Theme(id: "t", name: "T", fontFamily: "Helvetica", fontSize: 72, textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF", slides: [design])
    let baked = SlideSceneBuilder.bakedSlide(slide, theme: theme)
    let photo = baked.objects.first { $0.fill?.mediaId == "m1" }
    #expect(photo?.x == 100 && photo?.y == 120 && baked.themeSlideName == nil)
}

@Test func aFilledSpotDrawsAsAMediaFilledShape() throws {
    let slide = Slide(id: "s", name: "", objects: [SlideObject.photo(mediaId: "m1", scale: .fit)], themeSlideName: "3 Photos")
    let theme = Theme(id: "t", name: "T", fontFamily: "Helvetica", fontSize: 72, textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF", slides: [design])
    let items = SlideSceneBuilder.scene(for: slide, theme: theme).layers.first { $0.kind == .slide }?.items ?? []
    let shape = try #require(items.first { if case .shape(let style) = $0.content, case .media = style.fill { true } else { false } })
    #expect(shape.frame == CGRect(x: 100, y: 120, width: 400, height: 300))
    if case .shape(let style) = shape.content, case .media(let id, let mode, _) = style.fill {
        #expect(id == "m1" && mode == .fit)
    }
}
