import PresenterCore
import SwiftUI

struct SongTransitionMenuItems: View {

    let current: SongTransition?
    let apply: (SongTransition?) -> Void

    private var kind: SongTransitions.Kind { SongTransitions.kind(current) }

    var body: some View {
        ForEach(SongTransitions.Kind.allCases, id: \.self) { option in
            Toggle(Self.title(option), isOn: Binding(
                get: { kind == option },
                set: { _ in

                    apply(option == .stop && current?.seconds == nil
                        ? nil : SongTransition(kind: option.rawValue, seconds: current?.seconds))
                }
            ))
        }
        if kind != .stop {
            Divider()
            Menu("Length") {
                Toggle(kind == .overlap ? "Automatic (by sections, up to 5 s)" : "Automatic (5 s)", isOn: Binding(
                    get: { current?.seconds == nil },
                    set: { _ in apply(SongTransition(kind: kind.rawValue)) }
                ))
                Divider()
                ForEach(Self.lengths, id: \.self) { seconds in
                    Toggle("\(Int(seconds)) s", isOn: Binding(
                        get: { current?.seconds == seconds },
                        set: { _ in apply(SongTransition(kind: kind.rawValue, seconds: seconds)) }
                    ))
                }
            }
        }
    }

    static let lengths: [Double] = [1, 2, 3, 5, 8, 10, 15, 20]

    static func title(_ kind: SongTransitions.Kind) -> String {
        switch kind {
        case .stop: "Stop"
        case .fade: "Fade"
        case .overlap: "Overlap"
        case .crossfade: "Crossfade"
        }
    }

    static func help(_ transition: SongTransition?) -> String {
        let kind = SongTransitions.kind(transition)
        let length = transition?.seconds.map { "\(Int($0)) s" }
        switch kind {
        case .stop:
            return "Stop: the song plays to its end and nothing starts by itself"
        case .fade:
            return "Fade: the song fades out over its last \(length ?? "5 s"), then the next item starts"
        case .overlap:
            return "Overlap: the next item starts \(length ?? "a few seconds") before this song ends"
        case .crossfade:
            return "Crossfade: over the last \(length ?? "5 s"), this song fades out as the next item fades in"
        }
    }
}

struct SongTransitionGlyph: View {
    let kind: SongTransitions.Kind
    var size: CGFloat = 13

    var body: some View {
        Mark(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: size + 3, height: size * 0.8)
            .accessibilityLabel(SongTransitionMenuItems.title(kind))
    }

    private struct Mark: Shape {
        let kind: SongTransitions.Kind

        func path(in rect: CGRect) -> Path {
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
            }
            var path = Path()
            switch kind {
            case .stop:
                path.move(to: at(0.15, 0.5)); path.addLine(to: at(0.7, 0.5))
                path.move(to: at(0.85, 0.2)); path.addLine(to: at(0.85, 0.8))
            case .fade:
                path.move(to: at(0.1, 0.2)); path.addLine(to: at(0.9, 0.8)); path.addLine(to: at(0.1, 0.8))
            case .overlap:
                path.move(to: at(0.05, 0.35)); path.addLine(to: at(0.65, 0.35))
                path.move(to: at(0.35, 0.65)); path.addLine(to: at(0.95, 0.65))
            case .crossfade:
                path.move(to: at(0.1, 0.2)); path.addLine(to: at(0.9, 0.8))
                path.move(to: at(0.1, 0.8)); path.addLine(to: at(0.9, 0.2))
            }
            return path
        }
    }
}
