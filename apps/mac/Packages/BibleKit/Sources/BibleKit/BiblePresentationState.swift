/// Selection and live output are separate. A returned index is an explicit request
/// to fire; selecting in preparation mode or rebuilding slides returns no request.
public struct BiblePresentationState: Sendable, Equatable {
    public private(set) var selectedIndex = 0
    public private(set) var isPresenting = false

    public init() {}

    public mutating func select(_ index: Int, slideCount: Int) -> Int? {
        guard slideCount > 0, (0..<slideCount).contains(index) else { return nil }
        selectedIndex = index
        return isPresenting ? index : nil
    }

    public mutating func togglePresentationMode(slideCount: Int) -> Int? {
        if isPresenting { isPresenting = false; return nil }
        guard slideCount > 0, (0..<slideCount).contains(selectedIndex) else { return nil }
        isPresenting = true
        return selectedIndex
    }

    public mutating func resetSelection() { selectedIndex = 0 }

    // Re-entering Bible must never silently arm live clicks from an earlier visit.
    // This disarms future clicks; it deliberately does not clear existing output.
    public mutating func leaveWorkspace() { isPresenting = false }
}
