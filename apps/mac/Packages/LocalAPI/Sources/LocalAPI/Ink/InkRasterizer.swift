import CoreGraphics
import CoreVideo
import Foundation

public final class InkRasterizer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mxu.ink.raster", qos: .userInteractive)
    private var latest: CVPixelBuffer?
    private var pending: InkBoard?
    private var inFlight = false
    private var size: (width: Int, height: Int)

    public init(width: Int = 1920, height: Int = 1080) {
        size = (max(16, width), max(16, height))
    }

    public func frame() -> CVPixelBuffer? {
        lock.withLock { latest }
    }

    public func setSize(width: Int, height: Int) {
        let next = (max(16, width), max(16, height))
        lock.withLock {
            guard size != next else { return }
            size = next
        }
    }

    public func update(_ board: InkBoard) {
        let start: Bool = lock.withLock {
            pending = board
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let job: (InkBoard, (width: Int, height: Int))? = lock.withLock {
                guard let board = pending else {
                    inFlight = false
                    return nil
                }
                pending = nil
                return (board, size)
            }
            guard let (board, size) = job else { return }
            let buffer = Self.render(board, width: size.width, height: size.height)
            lock.withLock { latest = buffer }
        }
    }

    public static func render(_ board: InkBoard, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        guard !board.hidden else { return buffer }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for stroke in board.strokes { draw(stroke, in: context, width: CGFloat(width), height: CGFloat(height)) }
        return buffer
    }

    static func color(_ hex: String, alpha: Double) -> CGColor {
        let digits = hex.dropFirst()
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }

    static func draw(_ stroke: InkStroke, in context: CGContext, width: CGFloat, height: CGFloat) {
        let count = stroke.points.count / 2
        guard count > 0 else { return }
        let lineWidth = CGFloat(stroke.width) * width
        func point(_ index: Int) -> CGPoint {
            CGPoint(x: CGFloat(stroke.points[2 * index]) * width, y: CGFloat(stroke.points[2 * index + 1]) * height)
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(stroke.roundCap ? .round : .butt)
        context.setLineJoin(.round)
        context.setLineWidth(lineWidth)
        let paint = color(stroke.colorHex, alpha: stroke.erase ? 1 : stroke.alpha)
        context.setStrokeColor(paint)
        context.setFillColor(paint)
        if stroke.erase {
            context.setBlendMode(.destinationOut)
            context.setLineCap(.round)
        } else if stroke.glow > 0 {
            context.setShadow(
                offset: .zero, blur: CGFloat(stroke.glow) * width,
                color: color(stroke.colorHex, alpha: stroke.alpha)
            )
        }
        if count == 1 {
            let p = point(0)
            context.fillEllipse(in: CGRect(
                x: p.x - lineWidth / 2, y: p.y - lineWidth / 2, width: lineWidth, height: lineWidth))
            return
        }
        let path = CGMutablePath()
        path.move(to: point(0))
        if count > 2 {
            for index in 1 ..< count - 1 {
                let control = point(index), next = point(index + 1)
                path.addQuadCurve(
                    to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2),
                    control: control
                )
            }
        }
        path.addLine(to: point(count - 1))
        context.addPath(path)
        context.strokePath()
    }
}
