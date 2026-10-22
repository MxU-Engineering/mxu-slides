import AppKit
import AudioEngine
import PresenterCore
import SwiftUI

extension TimelineClips.Shape {
    var engine: ClipEnvelope.Shape { ClipEnvelope.Shape(rawValue: rawValue) ?? .linear }

    @MainActor func picture(out: Bool) -> NSImage {
        let key = "\(rawValue)-\(out)"
        if let drawn = Self.pictures[key] { return drawn }
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let fade = ClipEnvelope.Fade(seconds: 1, shape: engine)
            for step in 0 ... 24 {
                let x = Double(step) / 24
                let level = out ? fade.level(1 - x, out: true) : fade.level(x)
                let point = NSPoint(x: rect.minX + 1 + (rect.width - 2) * x, y: rect.minY + 1 + (rect.height - 2) * level)
                step == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        Self.pictures[key] = image
        return image
    }

    @MainActor private static var pictures: [String: NSImage] = [:]
}

struct ClipFadeShapeItems: View {
    var out = false
    var current: TimelineClips.Shape?
    let choose: (TimelineClips.Shape) -> Void

    var body: some View {
        ForEach(TimelineClips.Shape.allCases, id: \.self) { shape in
            Button {
                choose(shape)
            } label: {
                Label { Text(shape == current ? "\(shape.title) ✓" : shape.title) } icon: { Image(nsImage: shape.picture(out: out)) }
            }
        }
    }
}

struct ClipFadesOverlay: View {
    let clips: [TimelineCue]
    let cues: [TimelineCue]
    let x: (Double) -> CGFloat
    let pointsPerSecond: CGFloat
    let editable: Bool

    let set: (_ cueID: String, _ out: Bool, _ fade: ClipFade) -> Void
    @State private var dragging: (id: String, out: Bool, fade: ClipFade)?

    enum Handle { case length, midpoint }

    private func fade(_ clip: TimelineCue, out: Bool) -> ClipFade? {
        if let dragging, dragging.id == clip.id, dragging.out == out { return dragging.fade }
        return out ? clip.fadeOut : clip.fadeIn
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for clip in clips {
                        let end = PresentationTimelines.end(of: clip, in: cues)
                        guard end.isFinite else { continue }
                        for out in [false, true] {
                            guard let fade = fade(clip, out: out), fade.seconds > 0 else { continue }
                            context.drawFade(fade, out: out, start: out ? end - fade.seconds : clip.at, x: x, height: height)
                        }
                    }
                }
                .allowsHitTesting(false)
                if editable {
                    ForEach(clips, id: \.id) { clip in
                        handles(clip, height: height)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func handles(_ clip: TimelineCue, height: CGFloat) -> some View {
        let end = PresentationTimelines.end(of: clip, in: cues)
        if end.isFinite {
            ForEach([false, true], id: \.self) { out in
                if let fade = fade(clip, out: out), fade.seconds > 0 {
                    let start = out ? end - fade.seconds : clip.at
                    let edge = out ? start : start + fade.seconds
                    let mid = fade.midpoint ?? 0.5
                    let engine = ClipEnvelope.Fade(seconds: 1, shape: TimelineClips.Shape(fade.shape).engine, midpoint: mid)
                    let level = out ? engine.level(1 - mid, out: true) : engine.level(mid)
                    handle(.length, at: CGPoint(x: x(edge), y: 4), clip: clip, out: out, fade: fade, end: end)
                    handle(.midpoint, at: CGPoint(x: x(start + fade.seconds * mid), y: 3 + (height - 6) * CGFloat(1 - level)),
                           clip: clip, out: out, fade: fade, end: end)
                }
            }
        }
    }

    private func handle(_ kind: Handle, at point: CGPoint, clip: TimelineCue, out: Bool, fade: ClipFade, end: Double) -> some View {
        let saved = out ? clip.fadeOut : clip.fadeIn
        return Group {
            if kind == .length {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                    .frame(width: 7, height: 7)
            } else {
                Circle().fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                    .frame(width: 7, height: 7)
            }
        }
        .contentShape(Rectangle().inset(by: -4))
        .position(point)
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                guard let saved else { return }
                dragging = (clip.id, out, Self.dragged(saved, kind, out: out, by: Double(drag.translation.width / pointsPerSecond), clip: clip, end: end))
            }
            .onEnded { drag in
                guard let saved else { return }
                dragging = nil
                set(clip.id, out, Self.dragged(saved, kind, out: out, by: Double(drag.translation.width / pointsPerSecond), clip: clip, end: end))
            })
        .help(kind == .length ? "Drag to set the fade's length" : "Drag to bend the fade's curve")
        .accessibilityLabel(kind == .length ? (out ? "Fade out length" : "Fade in length") : "Fade midpoint")
    }

    static func dragged(_ fade: ClipFade, _ kind: Handle, out: Bool, by seconds: Double, clip: TimelineCue, end: Double) -> ClipFade {
        TimelineClips.dragged(fade, midpoint: kind == .midpoint, out: out, by: seconds, clip: clip, end: end)
    }
}

private extension GraphicsContext {
    func drawFade(_ fade: ClipFade, out: Bool, start: Double, x: (Double) -> CGFloat, height: CGFloat) {
        let engine = ClipEnvelope.Fade(seconds: fade.seconds, shape: TimelineClips.Shape(fade.shape).engine, midpoint: fade.midpoint ?? 0.5)
        let inset: CGFloat = 3
        let span = max(height - inset * 2, 1)
        func y(_ level: Double) -> CGFloat { inset + span * CGFloat(1 - level) }
        var curve = Path()
        let steps = 32
        for step in 0 ... steps {
            let f = Double(step) / Double(steps)
            let level = out ? engine.level(1 - f, out: true) : engine.level(f)
            let point = CGPoint(x: x(start + fade.seconds * f), y: y(level))
            step == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }

        var taken = curve
        taken.addLine(to: CGPoint(x: x(start + fade.seconds), y: inset))
        taken.addLine(to: CGPoint(x: x(start), y: inset))
        taken.closeSubpath()
        fill(taken, with: .color(.black.opacity(0.28)))
        stroke(curve, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
    }
}

struct TimelineRangeOverlay: View {
    let range: ClosedRange<Double>
    let x: (Double) -> CGFloat

    var body: some View {
        let left = x(range.lowerBound), right = x(range.upperBound)
        Rectangle()
            .fill(Color.accentColor.opacity(0.16))
            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 1) }
            .overlay(alignment: .trailing) { Rectangle().fill(Color.accentColor).frame(width: 1) }
            .frame(width: max(right - left, 1))
            .frame(maxHeight: .infinity)
            .offset(x: left)
            .allowsHitTesting(false)
    }
}

struct TimelineClipKeyMonitor: NSViewRepresentable {
    enum Verb { case split, copy, paste, delete, rippleDelete }

    let active: Bool
    let action: (Verb) -> Void

    final class Coordinator {
        var monitor: Any?
        var action: (Verb) -> Void = { _ in }
        weak var view: NSView?

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let verb = verb(for: event) else { return event }
                action(verb)
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func verb(for event: NSEvent) -> Verb? {
            guard let window = view?.window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            let backspace = event.keyCode == 51 || event.keyCode == 117
            switch (flags, key) {
            case (.command, "b"): return .split
            case (.command, "c"): return .copy
            case (.command, "v"): return .paste
            case ([], _) where backspace: return .delete
            case (.shift, _) where backspace: return .rippleDelete
            default: return nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        sync(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        sync(context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    private func sync(_ coordinator: Coordinator) {
        coordinator.action = action
        if active { coordinator.install() } else { coordinator.remove() }
    }
}
