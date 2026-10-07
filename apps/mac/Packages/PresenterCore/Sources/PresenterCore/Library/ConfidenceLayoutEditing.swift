import Foundation

public extension ConfidenceLayout {

    var editorMirror: Presentation {
        var mirror = Presentation(
            id: id, name: name, presentationKind: .deck,
            themeId: "",
            slides: [Slide(id: id, name: name, objects: objects, animationOrder: animationOrder)]
        )
        mirror.canvasWidth = canvasWidth
        mirror.canvasHeight = canvasHeight
        return mirror
    }

    mutating func adopt(editorMirror mirror: Presentation) {
        objects = mirror.slides.first?.objects ?? []
        animationOrder = mirror.slides.first?.animationOrder
        canvasWidth = mirror.canvasWidth
        canvasHeight = mirror.canvasHeight
    }

    mutating func regenerateMultiViewObjects(context: MultiViewTiles.Context) {
        if let multiView {
            objects = MultiViewTiles.objects(
                for: multiView,
                canvasWidth: canvasWidth ?? 1920, canvasHeight: canvasHeight ?? 1080,
                context: context)
        }
    }

    mutating func unlockTiles() {
        multiView = nil
    }

    var isTallCanvas: Bool { (canvasHeight ?? 1080) > (canvasWidth ?? 1920) }

    func multiViewTurnedCopy(context: MultiViewTiles.Context) -> ConfidenceLayout? {
        multiView.map { tree in
            var turned = tree
            for index in turned.nodes.indices {
                turned.nodes[index].axis = turned.nodes[index].axis.map { $0 == .columns ? .rows : .columns }
            }
            let width = canvasHeight ?? 1080
            let height = canvasWidth ?? 1920
            var copy = ConfidenceLayout(
                id: UUID().uuidString,
                name: name + (height > width ? " (Tall)" : " (Wide)"),
                objects: [], folder: folder,

                canvasWidth: width == 1920 && height == 1080 ? nil : width,
                canvasHeight: width == 1920 && height == 1080 ? nil : height,
                multiView: turned
            )
            copy.regenerateMultiViewObjects(context: context)
            return copy
        }
    }
}
