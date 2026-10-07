import CoreGraphics
import Foundation
import RenderEngine

public enum OutputLayoutKind: String, CaseIterable, Sendable {
    case single
    case mirror
    case grouped
    case edgeBlend
    case ledWall
    case custom

    public var displayName: String {
        switch self {
        case .single: "Single"
        case .mirror: "Mirror"
        case .grouped: "Grouped"
        case .edgeBlend: "Edge Blend"
        case .ledWall: "LED Wall"
        case .custom: "Custom"
        }
    }
}

public enum OutputLayout {

    static let epsilon = 0.001

    public static func classify(
        slices: [OutputSliceState], hasBlends: (UUID) -> Bool,
        hasPlacement: (UUID) -> Bool = { _ in false }
    ) -> OutputLayoutKind {

        if slices.count == 1, let only = slices.first, hasPlacement(only.id) {
            return .ledWall
        }
        if slices.contains(where: { hasPlacement($0.id) }) { return .custom }
        guard slices.count > 1 else { return .single }
        let full = Compositor.fullSourceRect
        func isFull(_ rect: CGRect) -> Bool {
            abs(rect.minX) < Self.epsilon && abs(rect.minY) < Self.epsilon
                && abs(rect.width - 1) < Self.epsilon && abs(rect.height - 1) < Self.epsilon
        }
        _ = full
        if slices.allSatisfy({ isFull($0.sourceRect) }) {
            return slices.contains(where: { hasBlends($0.id) }) ? .custom : .mirror
        }

        let extras = Array(slices.dropFirst()).sorted { $0.sourceRect.minX < $1.sourceRect.minX }
        guard isFull(slices[0].sourceRect), extras.count >= 2,
              extras.allSatisfy({
                  abs($0.sourceRect.minY) < Self.epsilon
                      && abs($0.sourceRect.height - 1) < Self.epsilon
              })
        else { return .custom }
        var overlapping = false
        for index in 1..<extras.count {
            let gap = extras[index].sourceRect.minX - extras[index - 1].sourceRect.maxX
            if gap > Self.epsilon { return .custom }  
            if gap < -Self.epsilon { overlapping = true }
        }
        let spansCanvas = abs(extras[0].sourceRect.minX) < Self.epsilon
            && abs(extras[extras.count - 1].sourceRect.maxX - 1) < Self.epsilon
        guard spansCanvas else { return .custom }
        if overlapping || extras.contains(where: { hasBlends($0.id) }) {
            return .edgeBlend
        }
        return .grouped
    }

    public static func tiles(columns: Int, overlap: Double) -> [CGRect] {
        let count = max(1, columns)
        let clamped = count > 1 ? min(max(overlap, 0), 0.2) : 0
        let width = (1 + Double(count - 1) * clamped) / Double(count)
        return (0..<count).map { index in
            CGRect(x: Double(index) * (width - clamped), y: 0, width: width, height: 1)
        }
    }

    public static func tileName(_ index: Int, of count: Int) -> String {
        switch (count, index) {
        case (2, 0): "Left"
        case (2, 1): "Right"
        case (3, 0): "Left"
        case (3, 1): "Center"
        case (3, 2): "Right"
        default: "Output \(index + 1)"
        }
    }
}

extension OutputManager {

    public func applyLayout(
        _ kind: OutputLayoutKind, outputCount: Int, overlap: Double,
        forScreen id: UUID, releasingCarries release: (UUID) -> Void = { _ in }
    ) {
        guard placeholderScreens.contains(where: { $0.id == id }) else { return }
        for slice in screenSlices[id] ?? [] {
            release(slice.id)
            removeSlice(id: slice.id)
        }

        if kind != .ledWall, kind != .custom {
            setPlacement(nil, forSlice: id)
        }
        switch kind {
        case .single, .custom:
            return
        case .ledWall:
            guard placement(forSlice: id) == nil,
                  let screen = placeholderScreens.first(where: { $0.id == id })
            else { return }

            let frameWidth = screen.width <= 1920 && screen.height <= 1080 ? 1920 : 3840
            let frameHeight = frameWidth == 1920 ? 1080 : 2160
            setPlacement(
                OutputPlacement(
                    frameWidth: frameWidth, frameHeight: frameHeight,
                    x: 0, y: 0,
                    width: Double(min(screen.width, frameWidth)),
                    height: Double(min(screen.height, frameHeight))
                ),
                forSlice: id
            )
            return
        case .mirror:

            for index in 1..<max(2, outputCount) {
                addSlice(toScreen: id, name: "Mirror \(index + 1)")
            }
        case .grouped, .edgeBlend:

            release(id)
            assignPlaceholderDevice(placeholderID: id, displayUUID: nil)
            let columns = max(2, outputCount)
            let spread = kind == .edgeBlend ? min(max(overlap, 0), 0.2) : 0
            let rects = OutputLayout.tiles(columns: columns, overlap: spread)
            for (index, rect) in rects.enumerated() {
                guard let slice = addSlice(
                    toScreen: id,
                    name: OutputLayout.tileName(index, of: columns),
                    sourceRect: rect
                ) else { continue }
                guard kind == .edgeBlend, spread > 0 else { continue }
                var adjustments = OutputAdjustments()
                let rampWidth = spread / rect.width
                if index > 0 { adjustments.blendLeft = OutputEdgeBlend(width: rampWidth) }
                if index < columns - 1 {
                    adjustments.blendRight = OutputEdgeBlend(width: rampWidth)
                }
                setAdjustments(adjustments, forScreen: slice.id)
            }
        }
    }
}
