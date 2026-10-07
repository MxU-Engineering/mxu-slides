import Foundation

public enum ListMultiSelect {
    public enum Gesture {

        case replace

        case toggle

        case extend
    }

    public struct State: Equatable {
        public var selected: Set<String>

        public var anchor: String?

        public init(selected: Set<String> = [], anchor: String? = nil) {
            self.selected = selected
            self.anchor = anchor
        }
    }

    public static func click(
        _ id: String, gesture: Gesture, in order: [String], state: State
    ) -> State {
        switch gesture {
        case .replace:
            return State(selected: [id], anchor: id)
        case .toggle:
            var selected = state.selected
            if !selected.insert(id).inserted { selected.remove(id) }
            return State(selected: selected, anchor: id)
        case .extend:
            guard let clicked = order.firstIndex(of: id) else { return state }
            let anchor = state.anchor.flatMap { order.firstIndex(of: $0) } ?? clicked
            var selected = state.selected
            selected.formUnion(order[min(anchor, clicked)...max(anchor, clicked)])
            return State(selected: selected, anchor: state.anchor ?? id)
        }
    }

    public static func batch(
        clicked id: String, selection: Set<String>, order: [String]
    ) -> [String] {
        guard selection.count > 1, selection.contains(id) else { return [id] }
        return order.filter(selection.contains)
    }
}
