import AppKit
import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PresentationTimelineCards {
    static let shared = PresentationTimelineCards()
    var open: Set<String> = []
    var expanded: Set<String> = []

    var addedLanes: [String: Set<TimelineLane>] = [:]

    var addedTracks: Set<String> = []

    var addedTrackRows: [String: Set<String>] = [:]
}

struct PresentationTimelineButton: View {
    let itemID: String
    let hasTimeline: Bool

    var body: some View {
        let cards = PresentationTimelineCards.shared
        let shown = cards.open.contains(itemID)
        Button {
            if shown {
                cards.open.remove(itemID)
                cards.expanded.remove(itemID)
            } else {
                cards.open.insert(itemID)
            }
        } label: {
            Image(systemName: "timeline.selection")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(shown || hasTimeline ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 20)
                .background(
                    shown ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timeline")
        .help(shown ? "Hide timeline" : hasTimeline ? "Show timeline" : "Show timeline (none recorded yet)")
    }
}

@MainActor
struct PresentationTimelineContext {
    let model: AppModel
    let controls: ServiceControls
    let serviceID: String
    let item: ServiceItem
    let presentation: Presentation

    var clock: PresentationTimelineController { controls.timeline }
    var timeline: PresentationTimeline? {
        PresentationTimelines.timeline(for: item.arrangementId, in: presentation)
    }
    var blocks: [TimelinePlayedBlock] {
        SlideSceneBuilder.timelineBlocks(for: presentation, arrangementId: item.arrangementId)
    }
    var isCurrent: Bool { clock.isCurrent(item.id) }

    var shownLength: Double {
        let length = max(timeline.map(PresentationTimelines.length) ?? 0, 1)
        return timeline?.length ?? length + max(2, length * 0.08)
    }
    var isPlaying: Bool { isCurrent && clock.playing }

    func play() { clock.play(itemID: item.id, presentation: presentation, arrangementId: item.arrangementId) }

    func seek(to time: Double) {
        clock.seek(to: time, itemID: item.id, presentation: presentation, arrangementId: item.arrangementId)
    }

    func record() {
        clock.record(
            itemID: item.id, presentation: presentation, arrangementId: item.arrangementId,
            newStart: suggestedStart(length: 0), start: start)
    }

    var byOrder: Bool { (try? model.service(serviceID))?.timecodeByOrder == true }

    func setByOrder(_ on: Bool) {
        model.updateService(serviceID) { $0.timecodeByOrder = on ? true : nil }
    }

    var start: Int? { (try? model.service(serviceID)).flatMap { TimecodeFollower.starts(model, service: $0)[item.id] } }

    func windows() -> [(window: PresentationTimelines.Window, name: String)] {
        guard let service = try? model.service(serviceID) else { return [] }
        let starts = TimecodeFollower.starts(model, service: service)
        return model.runOfShow(service).compactMap { other in
            guard other.itemKind == .presentation, other.id != item.id,
                  let deck = model.presentation(other.refId),
                  let timeline = PresentationTimelines.timeline(for: other.arrangementId, in: deck)
            else { return nil }
            let length = PresentationTimelines.frames(seconds: PresentationTimelines.length(timeline))
            return (
                PresentationTimelines.Window(
                    id: other.id, start: starts[other.id] ?? timeline.timecodeStart, length: length),
                other.name)
        }
    }

    var window: PresentationTimelines.Window? {
        timeline.map {
            PresentationTimelines.Window(
                id: item.id, start: start ?? $0.timecodeStart,
                length: PresentationTimelines.frames(seconds: PresentationTimelines.length($0)))
        }
    }

    func suggestedStart(length: Double) -> Int {
        PresentationTimelines.suggestedStart(
            length: PresentationTimelines.frames(seconds: length), avoiding: windows().map(\.window), id: item.id)
    }

    func edit(_ undoLabel: String, _ change: (inout PresentationTimeline) -> Void) {
        let current = model.presentation(presentation.id) ?? presentation
        var timeline = PresentationTimelines.timeline(for: item.arrangementId, in: current) ?? PresentationTimeline(
            id: UUID().uuidString, arrangementId: item.arrangementId.flatMap { $0.isEmpty ? nil : $0 },
            timecodeEnabled: false, timecodeStart: suggestedStart(length: 0), cues: [])
        change(&timeline)
        timeline.cues.sort { $0.at < $1.at }
        clock.save(timeline, presentationID: presentation.id, undoLabel: undoLabel)
    }
}

struct PresentationTimelineStrip: View {
    let context: PresentationTimelineContext
    @Environment(\.runOnly) private var runOnly
    @State private var viewport: CGFloat = 0

    @State private var pointsPerSecond: Double?
    @State private var startShown = false

    static let defaultWindow = 60.0

    var body: some View {
        let clock = context.clock
        let timeline = context.timeline
        let length = max(timeline.map(PresentationTimelines.length) ?? 0, 1)
        let shown = context.shownLength
        let start = context.start ?? timeline?.timecodeStart ?? 0
        let clashes = context.window.map { mine in
            context.windows().filter { mine.overlaps($0.window) }
        } ?? []
        let expanded = PresentationTimelineCards.shared.expanded.contains(context.item.id)
        HStack(spacing: 8) {
            TimelineTransportButtons(
                playing: context.isPlaying,
                startHelp: "Go to the start of the song",
                playHelp: "Play the timeline on its own clock",
                stopHelp: "Stop the timeline (what's on screen stays)",
                goToStart: { context.seek(to: 0) },
                playOrStop: { context.isPlaying ? clock.stop() : context.play() })
            if !runOnly {
                let recording = context.isCurrent && clock.recording
                Button {
                    recording ? clock.stop() : context.record()
                } label: {
                    Image(systemName: recording ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(recording ? Color.red : Color.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recording ? "Stop Recording" : "Record")
                .help(recording
                    ? "Stop recording"
                    : "Record: plays from the playhead and makes each slide you click a cue (its actions stay on the slide)")
            }

            if expanded {
                Spacer(minLength: 0)
            } else {
                sections(length: shown)
            }
            if context.isCurrent {
                TimelinePlayheadReadout(source: clock, duration: length) { t in
                    PresentationTimelines.timecode(frames: start + Int((t * Double(PresentationTimelines.framesPerSecond)).rounded(.down)))
                }
            } else {
                Text(PresentationTimelines.timecode(frames: start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .trailing)
            }
            Button {
                startShown = true
            } label: {
                Image(systemName: clashes.isEmpty ? "clock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(clashes.isEmpty ? Color.secondary : Color.orange)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timecode Start")
            .help(clashes.isEmpty
                ? "Timecode start"
                : "This start overlaps \(clashes.map(\.name).joined(separator: ", "))")
            .popover(isPresented: $startShown, arrowEdge: .bottom) {
                PresentationTimelineStartPopover(context: context)
            }
            Button {
                if expanded {
                    PresentationTimelineCards.shared.expanded.remove(context.item.id)
                } else {
                    PresentationTimelineCards.shared.expanded.insert(context.item.id)
                }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide Lanes" : "Show Lanes")
            .help(expanded ? "Hide the lanes" : "Show the lanes")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func sections(length: Double) -> some View {
        let pps = pointsPerSecond
            ?? TimelineZoom.clamped(Double(max(viewport, 1)) / min(length, Self.defaultWindow), in: TimelineZoom.songRange)

        let inset: CGFloat = 7
        let x: (Double) -> CGFloat = { inset + CGFloat(min(max($0, 0), length) * pps) }
        let time: (CGFloat) -> Double = { Double(max($0 - inset, 0)) / pps }
        let contentWidth = max(CGFloat(length * pps) + inset * 2, viewport)
        return HStack(spacing: 4) {
            PresentationTimelineFollowScroll(
                context: context, contentWidth: contentWidth, viewport: viewport, x: x
            ) {
                VStack(spacing: 2) {
                    PresentationTimelineSlideDots(context: context, x: x)
                        .frame(width: contentWidth, height: 8, alignment: .leading)
                    PresentationTimelineSectionsBar(context: context, length: length, page: viewport * 0.85, x: x)
                        .frame(width: contentWidth, height: 18, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    PresentationTimelineStepsRow(context: context, x: x)
                        .frame(width: contentWidth, height: 12, alignment: .leading)
                }
                .overlay(alignment: .topLeading) {
                    if context.isCurrent {
                        TimelinePlayheadLine(source: context.clock, cap: true, x: x)
                            .frame(height: 42, alignment: .top)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !context.isPlaying { context.seek(to: time(value.location.x)) }
                        }
                        .onEnded { value in
                            if context.isPlaying { context.seek(to: time(value.location.x)) }
                        }
                )
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
            .timelinePinchZoom(current: { pps }, range: TimelineZoom.songRange) { pointsPerSecond = $0 }
            Button {
                pointsPerSecond = TimelineZoom.zoomedOut(pps, in: TimelineZoom.songRange)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Zoom out")
            Button {
                pointsPerSecond = TimelineZoom.zoomedIn(pps, in: TimelineZoom.songRange)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Zoom in")
        }
    }
}

struct PresentationTimelineFollowScroll<Content: View>: View {
    let context: PresentationTimelineContext
    let contentWidth: CGFloat
    let viewport: CGFloat
    let x: (Double) -> CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {

        let page = max(viewport * 0.85, 1)
        let pages = Int((contentWidth / page).rounded(.up))
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .background(alignment: .topLeading) {

                        HStack(spacing: 0) {
                            ForEach(0..<max(pages, 1), id: \.self) { index in
                                Color.clear
                                    .frame(width: page, height: 1)
                                    .id("page-\(index)")
                            }
                        }
                    }
            }
            .background {
                if context.isCurrent {
                    TimelinePageFollow(source: context.clock, pageWidth: page, x: x) { index in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("page-\(index)", anchor: .leading)
                        }
                    }
                }
            }
        }
    }
}

struct PresentationTimelineSlideDots: View {
    let context: PresentationTimelineContext
    let x: (Double) -> CGFloat

    var body: some View {
        let blocks = context.blocks
        let slides = (context.timeline?.cues ?? [])
            .filter { $0.kind == .slide && PresentationTimelines.occurrence(of: $0, in: blocks) != nil }
        ZStack(alignment: .leading) {
            ForEach(slides, id: \.id) { cue in
                Circle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .help(context.label(cue))
                    .position(x: x(cue.at), y: 4)
            }
        }
    }
}

struct PresentationTimelineStepsRow: View {
    let context: PresentationTimelineContext
    let x: (Double) -> CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Self.placed(context.timeline?.cues ?? [], x: x), id: \.cue.id) { step in
                let lane = step.cue.kind ?? .actions
                Image(systemName: lane.symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .help("\(lane.title): \(context.label(step.cue))")
                    .position(x: step.x, y: 6)
            }
        }
    }

    static func placed(_ cues: [TimelineCue], x: (Double) -> CGFloat) -> [(cue: TimelineCue, x: CGFloat)] {
        var last = -CGFloat.infinity
        return cues.filter { $0.kind != nil && $0.kind != .slide }.sorted { $0.at < $1.at }.map { cue in
            last = max(x(cue.at), last + 13)
            return (cue, last)
        }
    }
}

struct PresentationTimelineSectionsBar: View {
    let context: PresentationTimelineContext
    let length: Double

    var flat = false

    var page: CGFloat?
    let x: (Double) -> CGFloat

    private func namePositions(left: CGFloat, width: CGFloat) -> [CGFloat] {
        guard let page, page > 0 else { return [left] }
        let pages = stride(from: (left / page).rounded(.up) * page, to: left + width - 40, by: page)
        return [left] + pages.filter { $0 > left + 60 }
    }

    var body: some View {
        let timeline = context.timeline
        let blocks = context.blocks
        let spans = timeline.map {
            PresentationTimelines.sectionSpans($0.cues, blocks: blocks, length: length)
        } ?? []
        let palette = context.model.groupColors
        ZStack(alignment: .leading) {
            if spans.isEmpty {
                Text(context.runOnlyHint(timeline))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 6)
            }
            ForEach(spans, id: \.block) { span in
                let section = context.presentation.sections?.first { $0.id == span.sectionId }
                let left = x(span.start)
                let spanWidth = max(x(span.end) - left - 1, 1)
                let color = GroupColor.fill(section, palette: palette) ?? Color.secondary
                if flat {
                    Rectangle()
                        .fill(color.opacity(0.8))
                        .frame(width: spanWidth, height: 3)
                        .position(x: left + spanWidth / 2, y: 16.5)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.35))
                        .frame(width: spanWidth, height: 16)
                        .position(x: left + spanWidth / 2, y: 9)
                }
                ForEach(namePositions(left: left, width: spanWidth), id: \.self) { at in
                    let room = min(left + spanWidth - at - 6, 140)
                    if room > 8 {
                        Text(section?.name ?? "")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(flat ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(width: room, alignment: .leading)
                            .position(x: at + 3 + room / 2, y: flat ? 6 : 9)
                    }
                }
            }
            if context.isCurrent, flat {
                TimelinePlayheadLine(source: context.clock, x: x)
            }
        }
    }

}

extension PresentationTimelineContext {
    func runOnlyHint(_ timeline: PresentationTimeline?) -> String {
        timeline?.cues.isEmpty == false
            ? "No slide cues yet"
            : "Press Record, then click the slides as the song plays"
    }
}

struct PresentationTimelineStartPopover: View {
    let context: PresentationTimelineContext
    @Environment(\.runOnly) private var runOnly
    @State private var text = ""

    var body: some View {
        let typed = PresentationTimelines.frames(timecode: text)
        let length = context.timeline.map(PresentationTimelines.length) ?? 0
        let others = context.windows()
        let byOrder = context.byOrder

        let ordered = byOrder ? context.start : nil
        let mine = PresentationTimelines.Window(
            id: context.item.id, start: ordered ?? typed ?? context.timeline?.timecodeStart ?? 0,
            length: PresentationTimelines.frames(seconds: length))
        let clashes = others.filter { mine.overlaps($0.window) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Timecode Start")
                .font(.headline)
            if byOrder {
                HStack(spacing: 6) {
                    Text(ordered.map(Self.hours) ?? "--:--")
                        .font(.body.monospacedDigit())
                    Text("· by order in this service")
                        .foregroundStyle(.secondary)
                }
                Button("Use saved times") { context.setByOrder(false) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .disabled(runOnly)
                    .help("Start times for this service: By saved times")
            }
            HStack {
                TextField("HH:MM:SS:FF", text: $text)
                    .font(.body.monospacedDigit())
                    .frame(width: 130)
                    .onSubmit { if let typed { set(typed) } }
                Button("Set") { if let typed { set(typed) } }
                    .disabled(typed == nil)
            }
            .disabled(runOnly)
            Text("Frames at 30 fps. Give each song in the service its own start, so incoming timecode says which song is playing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("This song plays from timecode", isOn: Binding(
                get: { context.timeline?.timecodeEnabled ?? false },
                set: { on in context.edit(on ? "Play from Timecode" : "Stop Playing from Timecode") { $0.timecodeEnabled = on } }))
                .disabled(runOnly)
            if !clashes.isEmpty {
                Label(
                    "Overlaps " + clashes.map {
                        "\($0.name) (\(PresentationTimelines.timecode(frames: $0.window.start)))"
                    }.joined(separator: ", "),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                if !byOrder {
                    let free = PresentationTimelines.suggestedStart(
                        length: mine.length, avoiding: others.map(\.window), id: mine.id)
                    HStack(spacing: 10) {
                        Button("Use \(PresentationTimelines.timecode(frames: free))") { set(free) }
                        Button("Use service order") { context.setByOrder(true) }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .help("Start times for this service: By service order (01:00, 02:00, … in run order)")
                    }
                    .disabled(runOnly)
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear {
            text = PresentationTimelines.timecode(
                frames: context.timeline?.timecodeStart ?? context.suggestedStart(length: 0))
        }
    }

    static func hours(_ frames: Int) -> String {
        let minutes = frames / PresentationTimelines.framesPerSecond / 60
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func set(_ frames: Int) {
        text = PresentationTimelines.timecode(frames: frames)
        context.edit("Timecode Start") { $0.timecodeStart = frames }
    }
}

struct PresentationTimelineLanes: View {
    let context: PresentationTimelineContext
    @Environment(\.runOnly) private var runOnly

    @State private var pointsPerSecond: Double?
    @State private var viewport: CGFloat = 0
    @State private var selection: String?
    @State private var edit = TimelineBlockEditState()
    @State private var frames: [String: CGRect] = [:]
    @State private var lanesFrame: CGRect = .zero
    @State private var anchor = TimelinePointerAnchor()
    @State private var autoScroll = TimelineEdgeAutoScroll()
    @State private var dropTargeted = false
    @Environment(\.actionRouter) private var router

    @State private var placing: PlacingAction?

    @State private var editingActions: String?

    @AppStorage("timeline.tracksExpanded") private var tracksExpanded = false

    @State private var newTrackName: String?

    private struct PlacingAction: Identifiable {
        var action: SlideAction
        var at: Double
        var id: String { action.id }
    }

    static let lanes: [TimelineLane] = TimelineLane.allCases

    static let standingLanes: Set<TimelineLane> = [.slide, .loopingVideos]
    static let laneHeight: CGFloat = 26
    static let rulerHeight: CGFloat = 16
    static let sectionsHeight: CGFloat = 18

    private func visibleLanes(_ cues: [TimelineCue]) -> [TimelineLane] {
        let added = PresentationTimelineCards.shared.addedLanes[context.item.id] ?? []
        return Self.lanes.filter { lane in
            Self.standingLanes.contains(lane) || added.contains(lane) || cues.contains { $0.kind == lane }
        }
    }

    var body: some View {
        let cues = context.timeline?.cues ?? []

        let display = cues.isEmpty ? 30 : context.shownLength
        let pps = pointsPerSecond
            ?? TimelineZoom.fit(seconds: min(display, 45), viewportWidth: viewport, reserve: 0, in: TimelineZoom.songRange)
            ?? 12
        let map = TimelineMap(
            segments: [TimelineSegment(start: 0, displayDuration: display, width: CGFloat(display * pps))],
            pointsPerSecond: CGFloat(pps))
        let visible = visibleLanes(cues)
        VStack(alignment: .leading, spacing: 6) {
            toolbar(cues, pps: pps, display: display)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {

                    Color.clear.frame(height: Self.rulerHeight + Self.sectionsHeight + 1)
                    ForEach(visible, id: \.self) { lane in
                        HStack(spacing: 2) {
                            Text(lane.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if !runOnly { addMenu(lane) }
                        }
                        .frame(height: Self.laneHeight)
                    }
                    if showsTracks(cues) { trackLabels(cues) }
                    addLaneMenu(visible, cues)
                }

                .frame(width: 104, alignment: .leading)
                PresentationTimelineFollowScroll(
                    context: context, contentWidth: map.width, viewport: viewport, x: { map.x(ofTime: $0) }
                ) {
                    lanes(cues, visible: visible, map: map)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
                .timelinePinchZoom(current: { pps }, range: TimelineZoom.songRange) { pointsPerSecond = $0 }
            }

            .dropDestination(for: String.self) { payloads, _ in
                let pointer = anchor.mouseLocal()
                return drop(
                    payloads, at: pointer.flatMap { map.locate(x: max($0.x, 0))?.time } ?? 0,
                    track: trackRow(atY: pointer?.y, visible: visible, cues: cues))
            } isTargeted: { dropTargeted = $0 }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle.standard(CornerStandard.element))

        .sheet(item: $placing) { placing in
            ActionPlacementSheet(model: context.model, draft: placing.action) { action in
                let cue = TimelineCue(
                    id: UUID().uuidString, lane: TimelineLane.actions.rawValue, at: placing.at, actions: [action])
                context.edit("Add Action") { $0.cues.append(cue) }
                selection = cue.id
            }
        }
        .sheet(isPresented: Binding(get: { editingActions != nil }, set: { if !$0 { editingActions = nil } })) {
            if let id = editingActions {
                SlideActionsSheet(
                    model: context.model, slideName: "",
                    actions: Binding(
                        get: {

                            let deck = context.model.presentation(context.presentation.id) ?? context.presentation
                            return PresentationTimelines.timeline(for: context.item.arrangementId, in: deck)?
                                .cues.first { $0.id == id }?.actions ?? []
                        },
                        set: { actions in
                            context.edit("Timeline Actions") { timeline in
                                guard let index = timeline.cues.firstIndex(where: { $0.id == id }) else { return }
                                timeline.cues[index].actions = actions
                            }
                        }),
                    title: "Timeline Actions")
            }
        }
    }

    private func toolbar(_ cues: [TimelineCue], pps: Double, display: Double) -> some View {
        HStack(spacing: 8) {
            if let cue = cues.first(where: { $0.id == selection }) {
                Text(context.label(cue))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(PresentationTimelines.timecode(frames: Int((cue.at * Double(PresentationTimelines.framesPerSecond)).rounded())))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !runOnly {
                    nudgeButton("chevron.left.2", "1 second earlier", cue, by: -1)
                    nudgeButton("chevron.left", "1 frame earlier", cue, by: -PresentationTimelines.frame)
                    nudgeButton("chevron.right", "1 frame later", cue, by: PresentationTimelines.frame)
                    nudgeButton("chevron.right.2", "1 second later", cue, by: 1)
                    Button {
                        delete(cue)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Remove from the timeline")
                }
            } else {
                Text(runOnly ? "Timeline" : "Drag from the library onto the lanes, or + on a lane adds at the playhead")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            TimelineZoomControls(
                pointsPerSecond: pps, zoom: { pointsPerSecond = $0 },
                fit: {
                    pointsPerSecond = TimelineZoom.fit(
                        seconds: display, viewportWidth: viewport, reserve: 0, in: TimelineZoom.songRange)
                },
                fitHelp: "Fit the song to the width", range: TimelineZoom.songRange)
        }
        .foregroundStyle(.secondary)
    }

    private func nudgeButton(_ symbol: String, _ help: String, _ cue: TimelineCue, by seconds: Double) -> some View {
        Button {
            move(cue, mode: .move, by: seconds, label: "Nudge Cue")
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .help("Nudge \(help)")
    }

    @ViewBuilder
    private func addMenu(_ lane: TimelineLane) -> some View {
        let model = context.model
        let at = { context.clock.insertionTime(for: context.item.id) }
        let block = { (id: String) in TimelineCue(id: id, lane: lane.rawValue, at: at(), duration: 10) }
        let menu: AnyView? = switch lane {
        case .actions:
            AnyView(AddActionMenuItems(model: model, timers: router?.timerChoices ?? []) { action in
                placing = PlacingAction(action: action, at: at())
            })
        case .overlays:
            AnyView(ForEach(model.entries(of: .overlay), id: \.id) { entry in
                Button(entry.name) { var cue = block(UUID().uuidString); cue.overlayId = entry.id; add(cue) }
            })
        case .alerts:
            AnyView(ForEach(model.entries(of: .alertPreset), id: \.id) { entry in
                Button(entry.name) { var cue = block(UUID().uuidString); cue.alertId = entry.id; add(cue) }
            })
        case .videoInput:
            AnyView(Group {
                let inputs = LiveInputCatalog.choices
                if inputs.isEmpty { Button("No video inputs set up") {}.disabled(true) }
                ForEach(inputs) { input in
                    Button(input.name) { var cue = block(UUID().uuidString); cue.liveInputId = input.id; add(cue) }
                }
            })
        case .audio:
            AnyView(ForEach(model.entries(of: .audio), id: \.id) { entry in
                Button(entry.name) {
                    var cue = block(UUID().uuidString)
                    cue.mediaId = entry.id
                    cue.duration = model.audio(entry.id)?.durationSeconds
                    add(cue)
                }
            })
        case .slide, .videos, .stillGraphics, .loopingVideos:
            nil
        }
        if let menu {
            Menu { menu } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .controlSize(.mini)
                .help("Add to \(lane.title) at the playhead")
        }
    }

    @ViewBuilder
    private func addLaneMenu(_ visible: [TimelineLane], _ cues: [TimelineCue]) -> some View {
        let hidden = Self.lanes.filter { !visible.contains($0) }
        if !hidden.isEmpty || !showsTracks(cues), !runOnly {
            Menu {
                ForEach(hidden, id: \.self) { lane in
                    Button(lane.title) {
                        PresentationTimelineCards.shared.addedLanes[context.item.id, default: []].insert(lane)
                    }
                }
                if !showsTracks(cues) {
                    Button("Tracks") { PresentationTimelineCards.shared.addedTracks.insert(context.item.id) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show another lane")
            .padding(.top, 4)
        }
    }

    private func lanes(_ cues: [TimelineCue], visible: [TimelineLane], map: TimelineMap) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            TimelineScrubStrip(
                map: map, interval: Self.interval(Double(map.pointsPerSecond)), label: Self.clock,
                scrub: { time, _ in if !context.isPlaying { context.seek(to: time) } },
                released: { time in if context.isPlaying { context.seek(to: time) } }
            ) {
                if context.isCurrent {
                    TimelinePlayheadHandle(source: context.clock, segmentStarts: [0]) { map.x(ofTime: $0) }
                }
            }
            .frame(width: map.width, height: Self.rulerHeight, alignment: .topLeading)
            PresentationTimelineSectionsBar(
                context: context, length: context.shownLength, flat: true, page: viewport * 0.85
            ) { map.x(ofTime: $0) }
                .frame(width: map.width, height: Self.sectionsHeight, alignment: .leading)
                .allowsHitTesting(false)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible, id: \.self) { lane in
                        laneRow(lane, cues, map: map)
                    }
                    if showsTracks(cues) { trackRows(cues, map: map) }
                }
                if context.isCurrent {
                    TimelinePlayheadLine(source: context.clock) { map.x(ofTime: $0) }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { lanesFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in lanesFrame = f }
                }
            )
            .background(TimelineScreenAnchor(anchor: anchor, passesThrough: true))
        }
        .frame(width: map.width, alignment: .topLeading)
    }

    private func laneRow(_ lane: TimelineLane, _ cues: [TimelineCue], map: TimelineMap) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(dropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
            ForEach(cues.filter { $0.kind == lane }, id: \.id) { cue in
                card(cue, cues, map: map)
            }
        }
        .frame(width: map.width, height: Self.laneHeight)
    }

    private func card(_ cue: TimelineCue, _ cues: [TimelineCue], map: TimelineMap, title: String? = nil) -> some View {
        let isBlock = cue.isBlock
        let left = map.x(ofTime: cue.at)
        let end = PresentationTimelines.end(of: cue, in: cues)

        let next = cues.filter { $0.kind == cue.kind && $0.at > cue.at }.map(\.at).min()

        let pin = cue.kind == .actions
        let gap = (next.map { map.x(ofTime: $0) } ?? left + 140) - left
        let width: CGFloat = isBlock
            ? (end.isFinite ? map.x(ofTime: end) - left : max(map.width - left, TimelineBlockEdit.minimumWidth))
            : pin ? min(max(gap - 4, 16), 140) : min(max(gap - 1, 10), 90)

        let mode = edit.mode(of: cue.id).map { isBlock ? $0 : .move }
        let span = TimelineBlockEdit.liveSpan(x: left, width: width, mode: mode, delta: edit.delta)
        let orphan = cue.kind == .slide && PresentationTimelines.occurrence(of: cue, in: context.blocks) == nil

        let section = cue.kind == .slide ? context.presentation.sections?.first { $0.id == cue.sectionId } : nil
        let tint = orphan ? .red : GroupColor.fill(section, palette: context.model.groupColors)
            ?? cue.kind?.tint ?? (cue.trackChannelId != nil ? Self.tracksTint : .gray)
        let face: AnyView = pin
            ? AnyView(actionPin(cue, width: span.width, selected: selection == cue.id))
            : AnyView(TimelineBlockCard(width: span.width, tint: tint, selected: selection == cue.id) {
                Text(title ?? (cue.kind == .slide ? context.slideBadge(cue, width: span.width) : context.label(cue)))
                    .font(.system(size: 10, weight: cue.kind == .slide ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1)
            })
        return face
        .help(orphan ? "This slide is no longer in the arrangement: the cue won't fire" : title ?? context.label(cue))
        .timelineBlockGestures(
            id: cue.id, anchor: anchor, edit: $edit, frames: $frames,
            frame: { frames[cue.id]?.offsetBy(dx: -lanesFrame.minX, dy: -lanesFrame.minY) },
            engaged: { _, _, _ in selection = cue.id },
            moved: { _ in },
            autoScroll: { autoScroll.arm { _ = TimelineEdgeAutoScroll.nudge(anchor) } },
            ended: { mode, dx in
                autoScroll.stop()
                selection = cue.id
                guard let mode, !runOnly, dx != 0 else { return }
                move(
                    cue, mode: mode, by: Double(dx / map.pointsPerSecond), label: "Move Cue",
                    openEnd: map.locate(x: left + width)?.time)
            },
            doubleClicked: {
                if cue.kind == .actions, !runOnly { editingActions = cue.id } else { context.seek(to: cue.at) }
            }
        ) {
            Button("Go Here") { context.seek(to: cue.at) }
            if !runOnly {
                if cue.kind == .actions {
                    Button("Edit Actions\u{2026}") { editingActions = cue.id }
                }
                Divider()
                Button("Nudge 1 Frame Earlier") { move(cue, mode: .move, by: -PresentationTimelines.frame, label: "Nudge Cue") }
                Button("Nudge 1 Frame Later") { move(cue, mode: .move, by: PresentationTimelines.frame, label: "Nudge Cue") }
                Divider()
                Button("Remove from Timeline") { delete(cue) }
                if cue.trackChannelId != nil {
                    Button("Remove These Stems") {
                        let group = Set(TimelineTracks.group(of: cue, in: cues).map(\.id))
                        selection = nil
                        context.edit("Remove Stems") { $0.cues.removeAll { group.contains($0.id) } }
                    }
                }
            }
        }

        .position(x: span.x + span.width / 2 - (pin ? Self.pinSize / 2 : 0), y: Self.laneHeight / 2)
    }

    static let pinSize: CGFloat = 16

    private func actionPin(_ cue: TimelineCue, width: CGFloat, selected: Bool) -> some View {
        HStack(spacing: 3) {

            Rectangle()
                .fill(selected ? Color.accentColor : Color.secondary)
                .frame(width: selected ? 2 : 1, height: Self.laneHeight - 4)
                .frame(width: Self.pinSize)
            Image(systemName: TimelineLane.actions.symbol)
                .font(.system(size: 9))
            Text(context.label(cue))
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .frame(width: width, height: Self.laneHeight, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
    }

    private func move(
        _ cue: TimelineCue, mode: TimelineBlockEdit.Mode, by seconds: Double, label: String, openEnd: Double? = nil
    ) {
        context.edit(label) { timeline in
            guard let index = timeline.cues.firstIndex(where: { $0.id == cue.id }) else { return }

            let together = mode == .move || cue.trackChannelId != nil && mode == .trim
                ? Set(TimelineTracks.group(of: timeline.cues[index], in: timeline.cues).map(\.id)) : [cue.id]
            let before = timeline.cues
            for (at, each) in before.enumerated() where together.contains(each.id) {
                timeline.cues[at] = PresentationTimelines.edited(
                    each, in: before, mode: mode, by: seconds, openEnd: each.id == cue.id ? openEnd : nil)
            }
        }
    }

    private func delete(_ cue: TimelineCue) {
        selection = nil
        context.edit("Remove Cue") { $0.cues.removeAll { $0.id == cue.id } }
    }

    private func drop(_ payloads: [String], at time: Double, track: TrackRow? = nil) -> Bool {
        DiagnosticsStore.shared.note("timeline.drop.offered", detail: payloads.first ?? "none")
        guard !runOnly, let id = payloads.first, let entry = context.model.indexEntry(id) else { return false }
        let at = PresentationTimelines.snappedToFrame(time)
        let cue: TimelineCue
        switch entry.kind {
        case .overlay:
            cue = TimelineCue(id: UUID().uuidString, lane: TimelineLane.overlays.rawValue, at: at, duration: 10, overlayId: id)
        case .alertPreset:
            cue = TimelineCue(id: UUID().uuidString, lane: TimelineLane.alerts.rawValue, at: at, duration: 10, alertId: id)
        case .audio where track != nil:

            let channel = if case .channel(let id) = track { id } else { String?.none }
            let item = context.model.audio(id)
            placeStems([TimelineStemImport(fileName: item?.fileName ?? entry.name, audioID: id, seconds: item?.durationSeconds)],
                       at: at, channel: channel)
            return true
        case .audio:
            cue = TimelineCue(
                id: UUID().uuidString, lane: TimelineLane.audio.rawValue, at: at,
                duration: context.model.audio(id)?.durationSeconds, mediaId: id)
        case .media:
            guard let media = context.model.media(id) else { return false }

            let layer = SlideSceneBuilder.layerKind(CueMedia.dropped(for: media).layer)
            let lane = TimelineLane(id: layer.rawValue) ?? .videos
            cue = TimelineCue(
                id: UUID().uuidString, lane: lane.rawValue, at: at,
                duration: lane == .loopingVideos ? nil : media.durationSeconds ?? 10, mediaId: id)
        case .actionCombo:
            cue = TimelineCue(
                id: UUID().uuidString, lane: TimelineLane.actions.rawValue, at: at,
                actions: [SlideAction(id: UUID().uuidString, kind: .fireCombo, comboId: id)])
        default:
            return false
        }
        add(cue)
        DiagnosticsStore.shared.note("timeline.drop", detail: "\(cue.lane) at \(at)")
        return true
    }

    private func add(_ cue: TimelineCue) {
        context.edit("Add to Timeline") { $0.cues.append(cue) }
        selection = cue.id
    }

    static let tracksTint = Color.purple

    enum TrackRow: Equatable {
        case folded
        case channel(String)
    }

    private func showsTracks(_ cues: [TimelineCue]) -> Bool {
        !TimelineTracks.stems(cues).isEmpty || PresentationTimelineCards.shared.addedTracks.contains(context.item.id)
    }

    private func trackChannels(_ cues: [TimelineCue]) -> [TrackChannel] {
        TimelineTracks.rows(
            channels: context.model.trackChannels, cues: cues,
            added: PresentationTimelineCards.shared.addedTrackRows[context.item.id] ?? [])
    }

    private func addTrackRow(_ channel: String) {
        let cards = PresentationTimelineCards.shared
        cards.addedTracks.insert(context.item.id)
        cards.addedTrackRows[context.item.id, default: []].insert(channel)
        tracksExpanded = true
    }

    private func makeTrack(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let role = TimelineTracks.role(forName: trimmed)
        let made = TrackChannel(id: UUID().uuidString, name: trimmed, role: role == .music ? nil : role.rawValue)
        context.model.updateTrackChannels { $0.channels.append(made) }
        addTrackRow(made.id)
    }

    private func trackRow(atY y: CGFloat?, visible: [TimelineLane], cues: [TimelineCue]) -> TrackRow? {
        guard let y, showsTracks(cues) else { return nil }
        let row = Int(floor((y - CGFloat(visible.count) * (Self.laneHeight + 1)) / (Self.laneHeight + 1)))
        guard row >= 0 else { return nil }
        let channels = trackChannels(cues)
        return tracksExpanded && row >= 1 && row <= channels.count ? .channel(channels[row - 1].id) : .folded
    }

    private func trackLabels(_ cues: [TimelineCue]) -> some View {
        let stems = TimelineTracks.stems(cues)
        let rows = trackChannels(cues)

        let addable = context.model.trackChannels.filter { channel in !rows.contains { $0.id == channel.id } }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Button {
                    tracksExpanded.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tracksExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(stems.isEmpty ? "Tracks" : "Tracks · \(stems.count)")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tracksExpanded ? "Fold this song's tracks into one row" : "Show this song's tracks")
                Spacer(minLength: 0)
                if !runOnly {
                    Menu {
                        Button("Add Stems\u{2026}") { addStems() }
                        Divider()

                        Menu("Add Track") {
                            ForEach(addable) { channel in
                                Button(channel.name) { addTrackRow(channel.id) }
                            }
                            if !addable.isEmpty { Divider() }
                            Button("New Track\u{2026}") { newTrackName = "" }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.mini)
                    .help("Add a song's stems at the playhead (each lands on the channel its name says), or a blank track to drop one stem onto")
                    .popover(isPresented: Binding(get: { newTrackName != nil }, set: { if !$0 { newTrackName = nil } })) {
                        TextField("Track name", text: Binding(get: { newTrackName ?? "" }, set: { newTrackName = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .padding(10)
                            .onSubmit {
                                makeTrack(named: newTrackName ?? "")
                                newTrackName = nil
                            }
                    }
                }
            }
            .frame(height: Self.laneHeight)
            if tracksExpanded {
                ForEach(rows) { channel in
                    HStack(spacing: 3) {
                        Text(channel.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if channel.trackRole != .music {
                            Image(systemName: "metronome")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                                .help("\(channel.trackRole == .click ? "Click" : "Guide"): starts on no mix, so it never reaches the house unless you send it there")
                        }
                    }
                    .padding(.leading, 11)
                    .frame(height: Self.laneHeight)
                }
            }
        }
    }

    private func trackRows(_ cues: [TimelineCue], map: TimelineMap) -> some View {
        let stems = TimelineTracks.stems(cues)

        let leaders = stems.reduce(into: [TimelineCue]()) { leaders, stem in
            if !leaders.contains(where: { abs($0.at - stem.at) < PresentationTimelines.frame / 2 }) { leaders.append(stem) }
        }
        return VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(dropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
                if !tracksExpanded {
                    ForEach(leaders, id: \.id) { leader in
                        let group = TimelineTracks.group(of: leader, in: cues)
                        let longest = group.max { ($0.duration ?? 0) < ($1.duration ?? 0) } ?? leader
                        card(longest, cues, map: map, title: group.count == 1 ? nil : "\(group.count) stems")
                    }
                }
            }
            .frame(width: map.width, height: Self.laneHeight)
            if tracksExpanded {
                ForEach(trackChannels(cues)) { channel in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(dropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
                        ForEach(stems.filter { $0.trackChannelId == channel.id }, id: \.id) { stem in
                            card(stem, cues, map: map)
                        }
                    }
                    .frame(width: map.width, height: Self.laneHeight)
                }
            }
        }
    }

    private func addStems() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = "Choose a song's stems, or the folder they're in"
        panel.prompt = "Add Stems"
        let at = context.clock.insertionTime(for: context.item.id)
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                let stems = await context.model.importStems(urls, song: context.presentation.name)
                placeStems(stems, at: at)
            }
        }
    }

    private func placeStems(_ stems: [TimelineStemImport], at: Double, channel: String? = nil) {
        guard !stems.isEmpty else { return }
        let channels = context.model.trackChannels
        var made: [TrackChannel] = []
        context.edit("Add Stems") { timeline in
            made = TimelineTracks.place(stems, at: at, channel: channel, channels: channels, into: &timeline.cues)
        }
        if !made.isEmpty {
            let adding = made
            context.model.updateTrackChannels { list in
                list.channels += adding.filter { new in !list.channels.contains { $0.id == new.id } }
            }
        }
        DiagnosticsStore.shared.note("timeline.stems", detail: "\(stems.count) at \(at), \(made.count) new channels")
    }

    static func interval(_ pointsPerSecond: Double) -> Double {
        [1, 2, 5, 10, 15, 30, 60].first { $0 * pointsPerSecond >= 44 } ?? 120
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension TimelineLane {
    var title: String {
        switch self {
        case .alerts: "Alerts"
        case .overlays: "Overlays"
        case .slide: "Slides"
        case .videos: "Foreground Videos"
        case .stillGraphics: "Still Graphics"
        case .loopingVideos: "Background Media"
        case .videoInput: "Video Input"

        case .audio: "Music"
        case .actions: "Actions"
        }
    }

    var tint: Color {
        switch self {
        case .alerts: .yellow
        case .overlays: AnimationKind.emphasis.tint
        case .slide: AnimationKind.morph.tint
        case .videos: AnimationKind.out.tint
        case .stillGraphics: .teal
        case .loopingVideos: AnimationKind.in.tint
        case .videoInput: .pink
        case .audio: .indigo
        case .actions: .gray
        }
    }

    var symbol: String {
        switch self {
        case .alerts: "exclamationmark.bubble"
        case .overlays: "rectangle.bottomthird.inset.filled"
        case .slide: "rectangle"
        case .videos: "play.rectangle"
        case .stillGraphics: "photo"
        case .loopingVideos: "film"
        case .videoInput: "video"
        case .audio: "music.note"
        case .actions: "bolt"
        }
    }
}

extension PresentationTimelineContext {

    func slideBadge(_ cue: TimelineCue, width: CGFloat) -> String {
        guard let occurrence = PresentationTimelines.occurrence(of: cue, in: blocks) else { return "?" }
        let number = "\(occurrence + 1)"
        let section = presentation.sections?.first { $0.id == cue.sectionId }?.name ?? ""
        if width >= 76, !section.isEmpty { return "\(number) \(section)" }
        if width >= 32, let initial = section.first { return number + String(initial).uppercased() }
        return number
    }

    func label(_ cue: TimelineCue) -> String {
        switch cue.kind {
        case .slide:
            let section = presentation.sections?.first { $0.id == cue.sectionId }?.name
            guard let occurrence = PresentationTimelines.occurrence(of: cue, in: blocks) else {
                return "Missing slide" + (section.map { " · \($0)" } ?? "")
            }
            return "Slide \(occurrence + 1)" + (section.map { " · \($0)" } ?? "")
        case .overlays:
            return cue.overlayId.flatMap { model.overlay($0)?.name } ?? "Overlay"
        case .alerts:
            return cue.alertId.flatMap { model.indexEntry($0)?.name } ?? "Alert"
        case .videoInput:
            return LiveInputCatalog.choices.first { $0.id == cue.liveInputId }?.name ?? "Video Input"
        case .audio:
            return cue.mediaId.flatMap { model.audio($0)?.name } ?? "Music"
        case .videos, .stillGraphics, .loopingVideos:
            return cue.mediaId.flatMap { model.media($0)?.name } ?? "Media"
        case .actions:
            let actions = cue.actions ?? []
            guard let first = actions.first else { return "No actions" }
            return first.kind.displayName + (actions.count > 1 ? " +\(actions.count - 1)" : "")
        case nil:
            guard cue.trackChannelId != nil else { return "Unknown lane" }
            return cue.mediaId.flatMap { model.audio($0)?.name } ?? "Stem"
        }
    }
}
