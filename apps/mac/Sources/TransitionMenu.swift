import PresenterCore
import SlideScene
import SwiftUI

struct TransitionMenu: View {
    let current: MediaTransition?
    var mixed = false
    var inherited: MediaTransition?
    var prefix = "Transition: "
    let apply: (@escaping @Sendable (MediaTransition?) -> MediaTransition?) -> Void

    private static let kinds: [TransitionKind] = [.cut, .dissolve, .fadeBlack, .fadeWhite, .fadeColor, .blurDissolve, .filmBurn]

    var body: some View {
        Menu(prefix + TransitionEdit.menuValue(current: current, mixed: mixed, inherited: inherited)) {
            Toggle(inherited == nil ? "Room Default" : "Presentation Default", isOn: Binding(
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
}
