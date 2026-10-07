import Foundation

public enum PreviewTargetLogic {
    public struct Choice: Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public static let layoutPrefix = "layout::"

    public static func layoutTarget(_ layoutID: String) -> String {
        layoutPrefix + layoutID
    }

    public static func layoutID(for target: String) -> String? {
        target.hasPrefix(layoutPrefix) && target.count > layoutPrefix.count
            ? String(target.dropFirst(layoutPrefix.count))
            : nil
    }

    public static func resolve(stored: String, screens: [Choice], layouts: [Choice]) -> Choice? {
        (screens + layouts).first { $0.id == stored } ?? screens.first ?? layouts.first
    }

    public static func aspect(canvasWidth: Int?, canvasHeight: Int?) -> Double {
        if let canvasWidth, let canvasHeight, canvasWidth > 0, canvasHeight > 0 {
            Double(canvasWidth) / Double(canvasHeight)
        } else {
            16.0 / 9.0
        }
    }
}
