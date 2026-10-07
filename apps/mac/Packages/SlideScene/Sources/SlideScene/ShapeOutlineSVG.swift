import CoreGraphics
import Foundation
import PresenterCore

public enum ShapeOutlineSVG {

    static let kappa = 0.5522847498

    public static func pathData(
        shapeKind: ShapeKind?,
        frame: CGSize,
        cornerRadius: Double?,
        customPathData: String?,
        placement: ShapeTextPlacement
    ) -> String? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let startAtBottom = placement == .edgeInside
        switch shapeKind ?? .rectangle {
        case .rectangle:
            return perimeter(frame: frame, radius: 0, startAtBottom: startAtBottom)
        case .roundedRectangle:
            return perimeter(
                frame: frame, radius: cornerRadius ?? 0, startAtBottom: startAtBottom
            )
        case .ellipse:
            return ellipse(startAtBottom: startAtBottom)
        case .path:

            guard let custom = customPathData, !custom.isEmpty else { return nil }
            return custom
        }
    }

    private static func perimeter(
        frame: CGSize, radius: Double, startAtBottom: Bool
    ) -> String {
        let clamped = min(max(radius, 0), Double(min(frame.width, frame.height)) / 2)
        let rx = clamped / Double(frame.width)
        let ry = clamped / Double(frame.height)
        let kx = kappa * rx
        let ky = kappa * ry

        func f(_ value: Double) -> String { String(format: "%.6f", value) }

        func corner(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, _ x: Double, _ y: Double) -> String {
            "C \(f(c1x)) \(f(c1y)) \(f(c2x)) \(f(c2y)) \(f(x)) \(f(y))"
        }

        var parts: [String] = []
        if startAtBottom {

            parts.append("M 0.5 1")
            parts.append("L \(f(rx)) 1")
            parts.append(corner(rx - kx, 1, 0, 1 - ry + ky, 0, 1 - ry))
            parts.append("L 0 \(f(ry))")
            parts.append(corner(0, ry - ky, rx - kx, 0, rx, 0))
            parts.append("L \(f(1 - rx)) 0")
            parts.append(corner(1 - rx + kx, 0, 1, ry - ky, 1, ry))
            parts.append("L 1 \(f(1 - ry))")
            parts.append(corner(1, 1 - ry + ky, 1 - rx + kx, 1, 1 - rx, 1))
        } else {

            parts.append("M 0.5 0")
            parts.append("L \(f(1 - rx)) 0")
            parts.append(corner(1 - rx + kx, 0, 1, ry - ky, 1, ry))
            parts.append("L 1 \(f(1 - ry))")
            parts.append(corner(1, 1 - ry + ky, 1 - rx + kx, 1, 1 - rx, 1))
            parts.append("L \(f(rx)) 1")
            parts.append(corner(rx - kx, 1, 0, 1 - ry + ky, 0, 1 - ry))
            parts.append("L 0 \(f(ry))")
            parts.append(corner(0, ry - ky, rx - kx, 0, rx, 0))
        }
        parts.append("Z")
        return parts.joined(separator: " ")
    }

    private static func ellipse(startAtBottom: Bool) -> String {
        let k = String(format: "%.6f", 0.5 - kappa * 0.5) 
        let kk = String(format: "%.6f", 0.5 + kappa * 0.5) 
        if startAtBottom {

            return "M 0.5 1 C \(k) 1 0 \(kk) 0 0.5 " +
                "C 0 \(k) \(k) 0 0.5 0 " +
                "C \(kk) 0 1 \(k) 1 0.5 " +
                "C 1 \(kk) \(kk) 1 0.5 1 Z"
        }

        return "M 0.5 0 C \(kk) 0 1 \(k) 1 0.5 " +
            "C 1 \(kk) \(kk) 1 0.5 1 " +
            "C \(k) 1 0 \(kk) 0 0.5 " +
            "C 0 \(k) \(k) 0 0.5 0 Z"
    }
}
