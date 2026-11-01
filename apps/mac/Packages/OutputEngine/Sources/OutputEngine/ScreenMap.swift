import CoreGraphics
import Foundation

public struct ScreenMap: Codable, Equatable, Sendable {
    public var name: String

    public var screens: [String: CGRect]

    public init(name: String = "Main Room", screens: [String: CGRect] = [:]) {
        self.name = name
        self.screens = screens
    }

    public func rect(for screenID: UUID) -> CGRect? { screens[screenID.uuidString] }

    public mutating func place(_ screenID: UUID, at rect: CGRect?) {
        if let rect { screens[screenID.uuidString] = rect } else { screens.removeValue(forKey: screenID.uuidString) }
    }

    public var bounds: CGRect {
        screens.values.reduce(CGRect.zero) { $0.union($1) }
    }
}

public struct MapPlacement: Equatable, Sendable {
    public var rect: CGRect
    public var fill: Bool

    public init(rect: CGRect, fill: Bool = false) {
        self.rect = rect
        self.fill = fill
    }
}

public struct ResolvedPlacement: Equatable, Sendable {
    public var frame: CGRect
    public var fill: Bool

    public init(frame: CGRect, fill: Bool) {
        self.frame = frame
        self.fill = fill
    }
}

public enum ScreenMapResolver {
    public static func resolve(placements: [MapPlacement], screen: CGRect?) -> [ResolvedPlacement]? {
        guard !placements.isEmpty, let screen, screen.width > 0, screen.height > 0 else { return nil }
        return placements.compactMap { placement in
            let overlap = placement.rect.intersection(screen)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            return ResolvedPlacement(
                frame: CGRect(
                    x: (placement.rect.minX - screen.minX) / screen.width,
                    y: (placement.rect.minY - screen.minY) / screen.height,
                    width: placement.rect.width / screen.width,
                    height: placement.rect.height / screen.height),
                fill: placement.fill)
        }
    }

    public static func onePerScreen(_ screens: [CGRect]) -> [MapPlacement] {
        screens.map { MapPlacement(rect: $0) }
    }

    public static func acrossScreens(_ screens: [CGRect]) -> [MapPlacement] {
        guard let first = screens.first else { return [] }
        return [MapPlacement(rect: screens.dropFirst().reduce(first) { $0.union($1) })]
    }
}
