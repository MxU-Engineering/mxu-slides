import RenderEngine
import SwiftUI

struct SceneCanvas: NSViewRepresentable {
    let render: RenderContext

    var transparentBackground = false

    var inset: CGFloat = 0

    func makeNSView(context: Context) -> MetalSceneView {
        let view = MetalSceneView(
            compositor: render.compositor, transparentBackground: transparentBackground
        )
        view.sceneProvider = { [sceneBox = render.sceneBox] in
            sceneBox.value
        }
        view.sceneInset = inset
        render.canvasView = view
        return view
    }

    func updateNSView(_ nsView: MetalSceneView, context: Context) {
        nsView.sceneInset = inset
    }
}
