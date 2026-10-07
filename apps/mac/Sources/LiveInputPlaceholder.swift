import CoreGraphics
import Foundation
import MediaEngine

enum LiveInputPlaceholder {
    static let cameraID = "placeholder::liveinput::camera"
    static let ndiID = "placeholder::liveinput::ndi"
    static let screenID = "placeholder::screenmirror"

    static func remap(_ id: String) -> String? {
        if id.hasPrefix("screen::") { return screenID }
        guard id.hasPrefix("input::") else { return nil }
        return id.hasPrefix("input::ndi::") ? ndiID : cameraID
    }

    static func register(into media: MediaEngine) async {
        if let camera = image(glyph: .camera) {
            _ = try? await media.showStill(
                image: camera, cacheKey: cameraID, id: cameraID)
        }
        if let ndi = image(glyph: .ndi) {
            _ = try? await media.showStill(
                image: ndi, cacheKey: ndiID, id: ndiID)
        }
        if let screen = image(glyph: .screen) {
            _ = try? await media.showStill(
                image: screen, cacheKey: screenID, id: screenID)
        }
    }

    private enum Glyph {
        case camera
        case ndi
        case screen
    }

    private static func image(glyph: Glyph) -> CGImage? {
        let width = 1920
        let height = 1080
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 0.20))
        context.fill(bounds)

        context.saveGState()
        context.clip(to: bounds)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(22)
        let spacing: CGFloat = 200
        var x = -CGFloat(height)
        while x < CGFloat(width) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x + CGFloat(height), y: CGFloat(height)))
            x += spacing
        }
        context.strokePath()
        context.restoreGState()

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.42))
        context.setLineWidth(12)
        context.stroke(bounds.insetBy(dx: 22, dy: 22))

        let ink = CGColor(gray: 1, alpha: 0.62)
        let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineWidth(18)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch glyph {
        case .ndi:

            let dot = CGRect(
                x: center.x - 130, y: center.y - 22, width: 44, height: 44)
            context.fillEllipse(in: dot)
            for (index, radius) in [90.0, 150.0, 210.0].enumerated() {
                context.setAlpha(1 - CGFloat(index) * 0.18)
                context.addArc(
                    center: CGPoint(x: dot.midX, y: dot.midY), radius: radius,
                    startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
                context.strokePath()
            }
            context.setAlpha(1)
        case .camera:

            let body = CGRect(
                x: center.x - 190, y: center.y - 105, width: 250, height: 210)
            let bodyPath = CGPath(
                roundedRect: body, cornerWidth: 34, cornerHeight: 34, transform: nil)
            context.addPath(bodyPath)
            context.strokePath()

            context.move(to: CGPoint(x: body.maxX + 26, y: center.y - 42))
            context.addLine(to: CGPoint(x: body.maxX + 128, y: center.y - 88))
            context.addLine(to: CGPoint(x: body.maxX + 128, y: center.y + 88))
            context.addLine(to: CGPoint(x: body.maxX + 26, y: center.y + 42))
            context.closePath()
            context.strokePath()
        case .screen:

            let panel = CGRect(
                x: center.x - 220, y: center.y - 60, width: 440, height: 280)
            let panelPath = CGPath(
                roundedRect: panel, cornerWidth: 30, cornerHeight: 30, transform: nil)
            context.addPath(panelPath)
            context.strokePath()

            context.move(to: CGPoint(x: center.x, y: panel.minY))
            context.addLine(to: CGPoint(x: center.x, y: panel.minY - 70))
            context.strokePath()
            context.move(to: CGPoint(x: center.x - 120, y: panel.minY - 90))
            context.addLine(to: CGPoint(x: center.x + 120, y: panel.minY - 90))
            context.strokePath()
        }
        return context.makeImage()
    }
}
