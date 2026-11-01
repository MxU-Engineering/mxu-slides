public struct DropoutWatch: Sendable {
    private var since: Double?

    public init() {}

    public mutating func update(_ holds: Bool, at seconds: Double) -> (start: Double, seconds: Double)? {
        if holds {
            if since == nil { since = seconds }
            return nil
        }
        guard let start = since else { return nil }
        since = nil
        return (start, seconds - start)
    }
}
