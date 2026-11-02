import CoreGraphics
import Foundation

public enum MediaLooks {
    public static let backdropZoom = 1.12

    public static let backdropBlurShare = 0.025
    public static let endFadeSeconds = 1.0

    public static func expanding(_ scene: RenderScene, remaining: (String) -> Double?) -> RenderScene {
        guard scene.layers.contains(where: { $0.items.contains(where: needsExpanding) }) else { return scene }
        var out = scene
        for index in out.layers.indices where out.layers[index].items.contains(where: needsExpanding) {
            out.layers[index].items = out.layers[index].items.flatMap { item in
                expanded(item, canvas: scene.canvasSize, remaining: remaining)
            }
        }
        return out
    }

    public static func endFadeAmount(remaining: Double?) -> Double {
        guard let remaining else { return 0 }
        return min(max(1 - remaining / endFadeSeconds, 0), 1)
    }

    static func zoomed(_ crop: SceneSourceRect?) -> SceneSourceRect {
        let base = crop ?? SceneSourceRect(x: 0, y: 0, width: 1, height: 1)
        let width = base.width / backdropZoom, height = base.height / backdropZoom
        return SceneSourceRect(x: base.x + (base.width - width) / 2, y: base.y + (base.height - height) / 2, width: width, height: height)
    }

    private static func needsExpanding(_ item: RenderItem) -> Bool {
        if item.endFade != nil { return true }
        if case .media(_, .scaleAndBlur, _) = item.content { return true }
        if case .shape(let style) = item.content, case .media(_, .scaleAndBlur, _) = style.fill { return true }
        return false
    }

    private static func expanded(_ item: RenderItem, canvas: CGSize, remaining: (String) -> Double?) -> [RenderItem] {
        guard needsExpanding(item) else { return [item] }
        var items = [item]
        if case .media(let id, .scaleAndBlur, let crop) = item.content {
            var backdrop = item
            backdrop.id = item.id + "#scalebg"
            backdrop.content = .media(id: id, scaleMode: .fill, sourceRect: zoomed(crop))
            backdrop.effects = [.blur(radius: canvas.width * backdropBlurShare)] + item.effects
            backdrop.maskedBy = nil
            var picture = item
            picture.content = .media(id: id, scaleMode: .fit, sourceRect: crop)
            items = [backdrop, picture]
        }
        if case .shape(let style) = item.content, case .media(let id, .scaleAndBlur, let crop) = style.fill {
            let group = item.id + "#spotmatte"
            var matte = item
            matte.id = group
            matte.matteGroup = group
            matte.maskedBy = nil
            matte.effects = []
            var outline = style
            outline.fill = .solid(.white)
            outline.stroke = nil
            outline.shadow = nil
            matte.content = .shape(outline)
            var backdrop = item
            backdrop.id = item.id + "#scalebg"
            backdrop.maskedBy = group
            backdrop.effects = [.blur(radius: canvas.width * backdropBlurShare)] + item.effects
            var blurred = outline
            blurred.fill = .media(id: id, scaleMode: .fill, sourceRect: zoomed(crop))
            backdrop.content = .shape(blurred)
            var picture = item
            var fitted = style
            fitted.fill = .media(id: id, scaleMode: .fit, sourceRect: crop)
            picture.content = .shape(fitted)
            items = [matte, backdrop, picture]
        }
        guard let fade = item.endFade, let id = item.content.mediaID else { return items }
        let amount = endFadeAmount(remaining: remaining(id))
        guard amount > 0 else { return items }
        switch fade {
        case .clear:
            return items.map { piece in
                var piece = piece
                piece.opacity *= 1 - amount
                return piece
            }
        case .black:
            let cover = RenderItem(id: item.id + "#endfade", frame: item.frame, content: .solid(.black), opacity: amount)
            return items + [cover]
        }
    }
}
