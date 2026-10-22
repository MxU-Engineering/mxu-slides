import AppKit
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

    static func summary(_ transition: SongTransition?) -> String {
        let kind = SongTransitions.kind(transition)
        guard kind != .stop else { return title(kind) }
        if let seconds = transition?.seconds { return "\(title(kind)) \(SongTransitionCurves.seconds(seconds))" }
        return kind == .overlap ? "\(title(kind)) · auto" : "\(title(kind)) 5 s"
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
        Image(nsImage: Self.image(kind, size: size))
            .accessibilityLabel(SongTransitionMenuItems.title(kind))
    }

    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor static func image(_ kind: SongTransitions.Kind, size: CGFloat) -> NSImage {
        let key = "\(kind.rawValue)|\(size)"
        if let held = images[key] { return held }
        let image = NSImage(size: NSSize(width: size + 3, height: (size * 0.8).rounded()), flipped: true) { rect in
            func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: rect.minX + 1 + (rect.width - 2) * x, y: rect.minY + 1 + (rect.height - 2) * y)
            }
            let path = NSBezierPath()
            switch kind {
            case .stop:
                path.move(to: at(0.1, 0.5)); path.line(to: at(0.72, 0.5))
                path.move(to: at(0.9, 0.1)); path.line(to: at(0.9, 0.9))
            case .fade:
                path.move(to: at(0.05, 0.1)); path.line(to: at(0.95, 0.9)); path.line(to: at(0.05, 0.9))
            case .overlap:
                path.move(to: at(0.0, 0.3)); path.line(to: at(0.62, 0.3))
                path.move(to: at(0.38, 0.7)); path.line(to: at(1.0, 0.7))
            case .crossfade:
                path.move(to: at(0.05, 0.1)); path.line(to: at(0.95, 0.9))
                path.move(to: at(0.05, 0.9)); path.line(to: at(0.95, 0.1))
            }
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = SongTransitionMenuItems.title(kind)
        images[key] = image
        return image
    }
}
