import CoreGraphics
import Foundation

public enum BlockScrollRoll {

    public enum Pose: Equatable, Sendable {

        case gone

        case offset(Double)
    }

    public static func pose(
        _ scroll: SceneBlockScroll, elapsed: Double, passLength: Double, restOffset: Double, anchored: Bool
    ) -> Pose {
        guard scroll.speed > 0, passLength > 0 else { return .offset(0) }
        let period = passLength / scroll.speed
        let t = max(elapsed, 0)
        if anchored, scroll.passes > 0, t >= period * Double(scroll.passes) {
            return scroll.restAtEnd ? .offset(restOffset) : .gone
        }
        let phase = t / period
        let inPass = phase - phase.rounded(.down)
        return .offset(scroll.ramp.apply(inPass) * passLength)
    }

    public struct Resolved: Equatable, Sendable {
        public var item: RenderItem
        public var translate: CGVector
        public var clip: AnimationMotion.Clip
    }

    public static func resolve(
        _ item: RenderItem, text: StyledText, scroll: SceneBlockScroll,
        blockHeight: CGFloat, elapsed: Double, anchored: Bool
    ) -> Resolved? {
        let frame = item.frame
        guard scroll.speed > 0, frame.width > 0, frame.height > 0 else { return nil }
        var expanded = item
        var content = text
        content.scroll = nil 
        let vertical = scroll.axis == .up || scroll.axis == .down

        let blockH: CGFloat = vertical ? max(frame.height, ceil(blockHeight)) : frame.height
        if vertical, blockH > frame.height {
            content.verticalAlignment = .top
            expanded.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: blockH)
        }
        expanded.content = .text(content)

        let passLength: Double = vertical ? Double(frame.height + blockH) : Double(frame.width * 2)
        let restOffset: Double = vertical ? Double(blockH) : Double(frame.width)
        guard case .offset(let d) = pose(scroll, elapsed: elapsed, passLength: passLength, restOffset: restOffset, anchored: anchored)
        else { return nil }

        var translate = CGVector.zero
        var clip = AnimationMotion.Clip()
        let fade = min(max(scroll.fadeTowardTop, 0), 1)
        switch scroll.axis {
        case .up:
            translate.dy = frame.height - d
            clip.minV = Double(-translate.dy / blockH)
            clip.maxV = clip.minV + Double(frame.height / blockH)
            clip.featherMinV = fade * Double(frame.height / blockH)
        case .down:
            translate.dy = -blockH + d
            clip.minV = Double(-translate.dy / blockH)
            clip.maxV = clip.minV + Double(frame.height / blockH)
            clip.featherMaxV = fade * Double(frame.height / blockH)
        case .left:
            translate.dx = frame.width - d
            clip.minU = Double(-translate.dx / frame.width)
            clip.maxU = clip.minU + 1
            clip.featherMinU = fade
        case .right:
            translate.dx = -frame.width + d
            clip.minU = Double(-translate.dx / frame.width)
            clip.maxU = clip.minU + 1
            clip.featherMaxU = fade
        }

        return Resolved(item: expanded, translate: translate, clip: clip)
    }
}
