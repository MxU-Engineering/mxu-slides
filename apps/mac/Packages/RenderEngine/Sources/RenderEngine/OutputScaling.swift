import CoreGraphics

public enum OutputScaleMode: String, Sendable, CaseIterable {

    case fit

    case fill
}

extension RenderScene {

    public func scaled(toScreen screen: CGSize, mode: OutputScaleMode) -> RenderScene {
        let canvas = canvasSize
        if canvas.width > 0, canvas.height > 0, screen.width > 0, screen.height > 0,
           abs(canvas.width / canvas.height - screen.width / screen.height) > 0.001 {
            let screenAspect = screen.width / screen.height
            let wider = screenAspect > canvas.width / canvas.height
            var scene = self
            switch mode {
            case .fit:
                let grown = wider
                    ? CGSize(width: canvas.height * screenAspect, height: canvas.height)
                    : CGSize(width: canvas.width, height: canvas.width / screenAspect)
                let dx = (grown.width - canvas.width) / 2
                let dy = (grown.height - canvas.height) / 2
                let full = CGRect(origin: .zero, size: canvas)
                scene.canvasSize = grown
                for layer in scene.layers.indices {
                    let kind = scene.layers[layer].kind
                    for index in scene.layers[layer].items.indices {
                        let item = scene.layers[layer].items[index]
                        if item.frame == full, Self.bleeds(item, in: kind) {
                            scene.layers[layer].items[index].frame = CGRect(origin: .zero, size: grown)
                        } else {
                            scene.layers[layer].items[index].frame = item.frame.offsetBy(dx: dx, dy: dy)
                        }
                    }
                }
            case .fill:
                let cropped = wider
                    ? CGSize(width: canvas.width, height: canvas.width / screenAspect)
                    : CGSize(width: canvas.height * screenAspect, height: canvas.height)
                let dx = (cropped.width - canvas.width) / 2
                let dy = (cropped.height - canvas.height) / 2
                scene.canvasSize = cropped
                for layer in scene.layers.indices {
                    for index in scene.layers[layer].items.indices {
                        scene.layers[layer].items[index].frame =
                            scene.layers[layer].items[index].frame.offsetBy(dx: dx, dy: dy)
                    }
                }
            }
            return scene
        } else {
            return self
        }
    }

    private static func bleeds(_ item: RenderItem, in kind: LayerKind) -> Bool {
        kind == .loopingVideos || (kind == .slide && item.id.hasSuffix("-backdrop"))
    }
}
