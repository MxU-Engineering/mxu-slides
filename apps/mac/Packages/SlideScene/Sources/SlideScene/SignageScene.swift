import CoreGraphics
import Foundation
import RenderEngine

public enum SignageSceneBuilder {
    public static func scene(mediaID: String, canvasSize: CGSize) -> RenderScene {
        var scene = RenderScene(canvasSize: canvasSize)
        scene.addItem(
            RenderItem(
                id: "signage-\(mediaID)",
                frame: CGRect(origin: .zero, size: canvasSize),
                content: .media(id: mediaID, scaleMode: .fill)
            ),
            to: .videos
        )
        return scene
    }
}
