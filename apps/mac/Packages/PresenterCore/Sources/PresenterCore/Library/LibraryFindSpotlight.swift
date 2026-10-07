import Foundation

public struct LibraryFindSpotlight: Equatable {
    public private(set) var active = false

    public init() {}

    public mutating func invoke() {
        active = true
    }

    public mutating func clicked(insideLibrary: Bool) {
        if !insideLibrary { active = false }
    }
}
