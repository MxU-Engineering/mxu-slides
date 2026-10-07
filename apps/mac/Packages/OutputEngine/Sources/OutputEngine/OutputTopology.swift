import CoreGraphics

public enum OutputTopology {
    public enum Change: Equatable, Sendable {

        case open(DisplayUUID)

        case close(DisplayUUID)

        case reframe(DisplayUUID, CGRect)
    }

    public static func reconcile(
        assigned: Set<DisplayUUID>,
        openWindows: [DisplayUUID: CGRect],
        connected: [DisplaySnapshot]
    ) -> [Change] {
        let connectedByUUID = Dictionary(
            connected.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var changes: [Change] = []

        for uuid in openWindows.keys.sorted()
        where !assigned.contains(uuid) || connectedByUUID[uuid] == nil {
            changes.append(.close(uuid))
        }
        for uuid in assigned.sorted() {
            guard let display = connectedByUUID[uuid] else { continue }
            if let windowFrame = openWindows[uuid] {
                if windowFrame != display.frame {
                    changes.append(.reframe(uuid, display.frame))
                }
            } else {
                changes.append(.open(uuid))
            }
        }
        return changes
    }
}
