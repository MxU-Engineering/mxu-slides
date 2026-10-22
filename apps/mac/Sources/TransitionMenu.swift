import PresenterCore
import SlideScene
import SwiftUI

struct TransitionMenu: View {
    let current: MediaTransition?
    var mixed = false
    let apply: (@escaping @Sendable (MediaTransition?) -> MediaTransition?) -> Void

    private static let kinds: [TransitionKind] = [.cut, .dissolve, .fadeBlack, .fadeWhite, .fadeColor, .blurDissolve, .filmBurn]

    var body: some View {
        Menu(title) {
            Toggle("Room Default", isOn: Binding(
                get: { !mixed && current == nil },
                set: { _ in apply { _ in nil } }
            ))
            Divider()
            ForEach(Self.kinds, id: \.self) { kind in
                Toggle(kind.menuName, isOn: Binding(
                    get: { !mixed && current?.transitionKind == kind },
                    set: { _ in apply { TransitionEdit.withKind(kind, from: $0) } }
                ))
            }
            if !mixed, let current, current.transitionKind != .cut {
                Divider()
                ForEach(TransitionEdit.durationChoices(current: current), id: \.self) { seconds in
                    Toggle(TransitionEdit.label(seconds: seconds), isOn: Binding(
                        get: { abs(TransitionEdit.seconds(current) - seconds) < 0.005 },
                        set: { _ in apply { TransitionEdit.withDuration(seconds, from: $0) } }
                    ))
                }
            }
        }
    }

    private var title: String {
        if mixed {
            "Transition: Mixed"
        } else if let current, current.transitionKind != .cut {
            "Transition: \(current.transitionKind.menuName) \(TransitionEdit.label(seconds: TransitionEdit.seconds(current)))"
        } else if current != nil {
            "Transition: Cut"
        } else {
            "Transition: Room Default"
        }
    }
}

extension TransitionKind {
    var menuName: String {
        switch self {
        case .cut: "Cut"
        case .dissolve: "Dissolve"
        case .fadeBlack: "Fade Black"
        case .fadeWhite: "Fade White"
        case .fadeColor: "Fade Color"
        case .blurDissolve: "Blur Dissolve"
        case .filmBurn: "Film Burn"
        }
    }
}
