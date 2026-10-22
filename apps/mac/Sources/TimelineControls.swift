import PresenterCore
import SlideScene
import SwiftUI

extension AnimationKind {
    var tint: Color {
        switch self {
        case .in: Color(red: 0.16, green: 0.62, blue: 0.36)
        case .out: Color(red: 0.85, green: 0.47, blue: 0.16)
        case .emphasis: Color(red: 0.55, green: 0.38, blue: 0.85)
        case .morph: Color(red: 0.20, green: 0.55, blue: 0.85)
        }
    }
}

struct TimelineTransportButtons: View {
    let playing: Bool
    var startHelp = "Go to the top"
    let playHelp: String
    let stopHelp: String
    let goToStart: () -> Void
    let playOrStop: () -> Void

    var body: some View {
        Button {
            goToStart()
        } label: {
            Image(systemName: "backward.end.fill").frame(width: 14)
        }
        .buttonStyle(.plain)
        .help(startHelp)
        Button {
            playOrStop()
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .help(playing ? stopHelp : playHelp)
    }
}

struct TimelineZoomControls: View {
    let pointsPerSecond: Double
    let zoom: (Double) -> Void
    let fit: () -> Void
    var fitHelp = "Pack the whole timeline into view"
    var range = TimelineZoom.range

    var body: some View {
        Button {
            zoom(TimelineZoom.zoomedOut(pointsPerSecond, in: range))
        } label: {
            Image(systemName: "minus")
        }
        .buttonStyle(.plain)
        .controlSize(.mini)
        Slider(
            value: Binding(
                get: { pointsPerSecond },
                set: { zoom($0) }
            ),
            in: range
        )
        .controlSize(.mini)
        .frame(width: 90)
        Button {
            zoom(TimelineZoom.zoomedIn(pointsPerSecond, in: range))
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .controlSize(.mini)
        Button("Fit") { fit() }
            .controlSize(.mini)
            .help(fitHelp)
    }
}

private struct TimelinePinchZoom: ViewModifier {
    let current: () -> Double
    let zoom: (Double) -> Void
    var range = TimelineZoom.range
    @State private var base: Double?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = base ?? current()
                    base = start
                    zoom(TimelineZoom.pinched(base: start, magnification: value.magnification, in: range))
                }
                .onEnded { _ in base = nil }
        )
    }
}

extension View {

    func timelinePinchZoom(
        current: @escaping () -> Double, range: ClosedRange<Double> = TimelineZoom.range,
        zoom: @escaping (Double) -> Void
    ) -> some View {
        modifier(TimelinePinchZoom(current: current, zoom: zoom, range: range))
    }
}

struct TimelineRuler: View {
    let map: TimelineMap
    var interval: Double = 0.5

    var label: ((Double) -> String)?

    var body: some View {
        ForEach(Array(map.segments.enumerated()), id: \.offset) { index, segment in
            HStack(spacing: 0) {
                let ticks = max(Int(segment.displayDuration / interval), 1)
                ForEach(0..<ticks, id: \.self) { tick in
                    let seconds = Double(tick) * interval
                    Text(tick == 0 ? "0s" : label?(seconds) ?? String(format: "%.1f", seconds))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                        .frame(width: interval * map.pointsPerSecond, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.quaternary).frame(width: 0.5)
                        }
                        .clipped()
                }
                Spacer(minLength: 0)
            }
            .frame(width: segment.width, alignment: .leading)
            .offset(x: map.x(ofSegment: index))
        }
    }
}

struct TimelineScrubStrip<Playhead: View>: View {
    let map: TimelineMap
    var interval: Double = 0.5
    var label: ((Double) -> String)?
    let scrub: (_ time: Double, _ segment: Int) -> Void

    var released: ((_ time: Double) -> Void)?
    @ViewBuilder let playhead: () -> Playhead

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineRuler(map: map, interval: interval, label: label)
            playhead()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let landed = map.locate(x: value.location.x) else { return }
                    scrub(landed.time, landed.segment)
                }
                .onEnded { value in
                    guard let released, let landed = map.locate(x: value.location.x) else { return }
                    released(landed.time)
                }
        )
        .background(Color.primary.opacity(0.04))
    }
}

@MainActor protocol TimelinePlayheadSource: AnyObject {

    var timelinePlayheadTime: Double { get }
}

struct TimelinePlayheadReadout<Source: TimelinePlayheadSource>: View {
    let source: Source
    let duration: Double

    var text: ((Double) -> String)?

    var body: some View {
        let t = source.timelinePlayheadTime
        Text(text?(t) ?? String(format: "%.1f / %.1fs", t, max(duration, 0.01)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            .frame(width: 84, alignment: .trailing)
    }
}

struct TimelinePlayheadHandle<Source: TimelinePlayheadSource>: View {
    let source: Source
    let segmentStarts: [Double]
    let x: (Double) -> CGFloat

    var body: some View {
        let t = source.timelinePlayheadTime
        let start = segmentStarts.last { $0 <= t } ?? segmentStarts.first
        let within = start.map { max(t - $0, 0) } ?? t
        Text(String(format: "%.2fs", within))
            .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)

            .frame(width: 34)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
            .offset(x: x(t) - 17, y: 2)
    }
}

struct TimelinePlayheadLine<Source: TimelinePlayheadSource>: View {
    let source: Source
    var cap = false
    let x: (Double) -> CGFloat

    var body: some View {
        if cap {

            VStack(spacing: 0) {
                PlayheadCap().fill(Color.accentColor).frame(width: 9, height: 6)
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
            .frame(width: 9)
            .offset(x: x(source.timelinePlayheadTime) - 4.5)
            .allowsHitTesting(false)
        } else {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5)
                .offset(x: x(source.timelinePlayheadTime))
                .allowsHitTesting(false)
        }
    }
}

private struct PlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct TimelinePageFollow<Source: TimelinePlayheadSource>: View {
    let source: Source
    let pageWidth: CGFloat
    let x: (Double) -> CGFloat
    let turned: (Int) -> Void

    var body: some View {
        let page = pageWidth > 0 ? Int(max(x(source.timelinePlayheadTime), 0) / pageWidth) : 0
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: page) { _, page in turned(page) }
    }
}

struct TimelineBlockCard<Content: View>: View {
    let width: CGFloat
    let tint: Color
    let selected: Bool
    var rampIn = false
    var rampOut = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 22, alignment: .leading)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : tint.opacity(0.4),
                        lineWidth: selected ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {

            if rampIn { rampWedge(leading: true) }
        }
        .overlay(alignment: .trailing) {
            if rampOut { rampWedge(leading: false) }
        }
        .overlay(alignment: .trailing) {

            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.55))
                .frame(width: 4, height: 14)
                .padding(.trailing, 2)
                .allowsHitTesting(false)
                .help("Drag to change how long it runs")
        }
        .overlay(alignment: .leading) {

            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.55))
                .frame(width: 4, height: 14)
                .padding(.leading, 2)
                .allowsHitTesting(false)
                .help("Drag to move where it starts; the end stays put")
        }
        .clipped()
    }

    private func rampWedge(leading: Bool) -> some View {
        RampTriangle()
            .fill(tint.opacity(0.35))
            .frame(width: 8, height: 22)
            .scaleEffect(x: leading ? 1 : -1)
    }
}

private struct RampTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct TimelineBlockEditState {
    var id: String?
    var mode: TimelineBlockEdit.Mode?
    var delta: CGFloat = 0
    var pressStart: CGPoint?

    func mode(of id: String) -> TimelineBlockEdit.Mode? {
        self.id == id ? mode : nil
    }

    func delta(_ mode: TimelineBlockEdit.Mode) -> CGFloat {
        self.mode == mode ? delta : 0
    }
}

private struct TimelineBlockGestures<Menu: View>: ViewModifier {
    let id: String
    let anchor: TimelinePointerAnchor
    @Binding var edit: TimelineBlockEditState
    @Binding var frames: [String: CGRect]

    let frame: () -> CGRect?
    let engaged: (TimelineBlockEdit.Mode, _ start: CGPoint, _ frame: CGRect) -> Void
    let moved: (CGFloat) -> Void
    let autoScroll: () -> Void
    let ended: (TimelineBlockEdit.Mode?, CGFloat) -> Void
    let doubleClicked: () -> Void
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        content

            .contentShape(Rectangle().inset(by: -4))
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { frames[id] = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in frames[id] = f }
                }
            )
            .simultaneousGesture(

                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in
                        guard let mouse = anchor.mouseLocal() else { return }
                        let live = edit.mode(of: id) != nil
                        let start = edit.pressStart ?? anchor.pressLocal() ?? mouse
                        if edit.pressStart == nil { edit.pressStart = start }
                        let dx = mouse.x - start.x
                        guard abs(dx) > TimelineBlockEdit.engageDistance || live else { return }
                        if !live {

                            let measured = frame() ?? .zero
                            let mode = TimelineBlockEdit.mode(
                                pressX: start.x, frameMinX: measured.minX, frameWidth: measured.width
                            )
                            edit.id = id
                            edit.mode = mode
                            engaged(mode, start, measured)
                        }
                        edit.delta = dx
                        if edit.mode == .move {
                            moved(dx)
                        } else {
                            autoScroll()
                        }
                        autoScroll()
                    }
                    .onEnded { _ in
                        let mode = edit.mode(of: id)
                        var dx: CGFloat = 0
                        if let start = edit.pressStart, let mouse = anchor.mouseLocal() {
                            dx = mouse.x - start.x
                        }
                        edit = TimelineBlockEditState()
                        ended(mode, dx)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { doubleClicked() }
            )
            .contextMenu { menu() }
    }
}

extension View {

    func timelineBlockGestures<Menu: View>(
        id: String,
        anchor: TimelinePointerAnchor,
        edit: Binding<TimelineBlockEditState>,
        frames: Binding<[String: CGRect]>,
        frame: @escaping () -> CGRect?,
        engaged: @escaping (TimelineBlockEdit.Mode, CGPoint, CGRect) -> Void,
        moved: @escaping (CGFloat) -> Void,
        autoScroll: @escaping () -> Void,
        ended: @escaping (TimelineBlockEdit.Mode?, CGFloat) -> Void,
        doubleClicked: @escaping () -> Void,
        @ViewBuilder menu: @escaping () -> Menu
    ) -> some View {
        modifier(TimelineBlockGestures(
            id: id, anchor: anchor, edit: edit, frames: frames, frame: frame,
            engaged: engaged, moved: moved, autoScroll: autoScroll, ended: ended,
            doubleClicked: doubleClicked, menu: menu
        ))
    }
}

final class TimelinePointerAnchor {
    weak var view: NSView?
    var lastPress: NSPoint = .zero

    @MainActor func mouseLocal() -> CGPoint? {
        local(NSEvent.mouseLocation)
    }

    @MainActor func pressLocal() -> CGPoint? {
        local(lastPress)
    }

    @MainActor private func local(_ screenPoint: NSPoint) -> CGPoint? {
        guard let view, let window = view.window else { return nil }
        let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGPoint(x: screenPoint.x - screenRect.minX, y: screenRect.maxY - screenPoint.y)
    }
}

struct TimelineScreenAnchor: NSViewRepresentable {
    let anchor: TimelinePointerAnchor

    var passesThrough = false

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var monitor: Any?
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = passesThrough ? PassThroughView() : NSView()
        anchor.view = view
        let anchor = anchor
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            anchor.lastPress = NSEvent.mouseLocation
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

@MainActor final class TimelineEdgeAutoScroll {
    private var timer: Timer?

    func arm(_ tick: @escaping @MainActor () -> Void) {
        tick()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 45, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    enum Nudge { case unavailable, idle, scrolled }

    static func nudge(_ anchor: TimelinePointerAnchor) -> Nudge {
        guard let view = anchor.view,
              let window = view.window,
              let scrollView = view.enclosingScrollView else { return .unavailable }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inClip = scrollView.contentView.convert(inWindow, from: nil)
        let visible = scrollView.documentVisibleRect
        let zone: CGFloat = 36
        let step: CGFloat = 14
        var target = visible.origin
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - visible.width)
        if inClip.x > visible.maxX - zone {
            target.x = min(visible.origin.x + step, maxX)
        } else if inClip.x < visible.minX + zone {
            target.x = max(visible.origin.x - step, 0)
        } else {
            return .idle
        }
        guard target.x != visible.origin.x else { return .idle }
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return .scrolled
    }
}
