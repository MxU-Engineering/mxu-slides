import PresenterCore
import SlideScene
import SwiftUI

@MainActor
@Observable
final class PresentationTimelineCards {
    static let shared = PresentationTimelineCards()
    var open: Set<String> = []
    var expanded: Set<String> = []

    var addedLanes: [String: Set<TimelineLane>] = [:]
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
            newStart: suggestedStart(length: 0))
    }

    func windows() -> [(window: PresentationTimelines.Window, name: String)] {
        guard let service = try? model.service(serviceID) else { return [] }
        return model.runOfShow(service).compactMap { other in
            guard other.itemKind == .presentation, other.id != item.id,
                  let deck = model.presentation(other.refId),
                  let timeline = PresentationTimelines.timeline(for: other.arrangementId, in: deck)
            else { return nil }
            let length = PresentationTimelines.frames(seconds: PresentationTimelines.length(timeline))
            return (PresentationTimelines.Window(id: other.id, start: timeline.timecodeStart, length: length), other.name)
        }
    }

    var window: PresentationTimelines.Window? {
        timeline.map {
            PresentationTimelines.Window(
                id: item.id, start: $0.timecodeStart,
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
    @State private var width: CGFloat = 0
    @State private var startShown = false

    var body: some View {
        let clock = context.clock
        let timeline = context.timeline
        let length = max(timeline.map(PresentationTimelines.length) ?? 0, 1)
        let shown = context.shownLength
        let start = timeline?.timecodeStart ?? 0
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
        PresentationTimelineSectionsBar(context: context, length: length, markers: true) {
            CGFloat(min(max($0 / length, 0), 1)) * width
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !context.isPlaying { context.seek(to: Double(value.location.x / max(width, 1)) * length) }
                }
                .onEnded { value in
                    if context.isPlaying { context.seek(to: Double(value.location.x / max(width, 1)) * length) }
                }
        )
    }
}

struct PresentationTimelineSectionsBar: View {
    let context: PresentationTimelineContext
    let length: Double

    var markers = false

    var flat = false
    let x: (Double) -> CGFloat

    var body: some View {
        let timeline = context.timeline
        let blocks = context.blocks
        let spans = timeline.map {
            PresentationTimelines.sectionSpans($0.cues, blocks: blocks, length: length)
        } ?? []
        let ticks = (timeline?.cues ?? [])
            .filter { $0.kind == .slide && PresentationTimelines.occurrence(of: $0, in: blocks) != nil }
            .map(\.at)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section?.name ?? "")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Rectangle().fill(color.opacity(0.8)).frame(height: 3)
                    }
                    .frame(width: spanWidth, height: 18, alignment: .bottomLeading)
                    .clipped()
                    .position(x: left + spanWidth / 2, y: 9)
                } else {
                    Text(section?.name ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                        .frame(width: spanWidth, height: 16, alignment: .leading)
                        .background(color.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
                        .clipped()
                        .position(x: left + spanWidth / 2, y: 9)
                }
            }
            ForEach(ticks, id: \.self) { at in
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: flat ? 6 : 12)
                    .position(x: x(at), y: flat ? 15 : 9)
                    .allowsHitTesting(false)
            }
            if markers {
                ForEach(markerSteps(timeline), id: \.key) { step in
                    let lane = step.cue.kind ?? .actions
                    Image(systemName: lane.symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(lane.tint.opacity(step.out ? 0.35 : 0.9), in: Circle())
                        .help(context.label(step.cue) + (step.out ? " ends" : ""))
                        .position(x: x(step.at), y: 9)
                }
            }
            if context.isCurrent {
                TimelinePlayheadLine(source: context.clock, x: x)
            }
        }
    }

    private func markerSteps(_ timeline: PresentationTimeline?) -> [(key: String, cue: TimelineCue, at: Double, out: Bool)] {
        let cues = timeline?.cues ?? []
        return cues.filter { $0.kind != .slide && $0.kind != nil }.flatMap { cue in
            let end = PresentationTimelines.end(of: cue, in: cues)
            let out = (cue.kind?.clearsAtOut ?? false) && end.isFinite
            return [(cue.id, cue, cue.at, false)] + (out ? [(cue.id + ".out", cue, end, true)] : [])
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
        let mine = PresentationTimelines.Window(
            id: context.item.id, start: typed ?? context.timeline?.timecodeStart ?? 0,
            length: PresentationTimelines.frames(seconds: length))
        let clashes = others.filter { mine.overlaps($0.window) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Timecode Start")
                .font(.headline)
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
                let free = PresentationTimelines.suggestedStart(
                    length: mine.length, avoiding: others.map(\.window), id: mine.id)
                Button("Use \(PresentationTimelines.timecode(frames: free))") { set(free) }
                    .disabled(runOnly)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear {
            text = PresentationTimelines.timecode(
                frames: context.timeline?.timecodeStart ?? context.suggestedStart(length: 0))
        }
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
            ?? TimelineZoom.fit(seconds: display, viewportWidth: viewport, reserve: 0, in: TimelineZoom.songRange)
            ?? 12
        let map = TimelineMap(
            segments: [TimelineSegment(start: 0, displayDuration: display, width: CGFloat(display * pps))],
            pointsPerSecond: CGFloat(pps))
        let visible = visibleLanes(cues)
        VStack(alignment: .leading, spacing: 6) {
            toolbar(cues, pps: pps)
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
                    addLaneMenu(visible)
                }

                .frame(width: 104, alignment: .leading)
                ScrollView(.horizontal) {
                    lanes(cues, visible: visible, map: map)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
                .timelinePinchZoom(current: { pps }, range: TimelineZoom.songRange) { pointsPerSecond = $0 }
            }

            .dropDestination(for: String.self) { payloads, _ in
                drop(payloads, at: anchor.mouseLocal().flatMap { map.locate(x: max($0.x, 0))?.time } ?? 0)
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

    private func toolbar(_ cues: [TimelineCue], pps: Double) -> some View {
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
                pointsPerSecond: pps, zoom: { pointsPerSecond = $0 }, fit: { pointsPerSecond = nil },
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
    private func addLaneMenu(_ visible: [TimelineLane]) -> some View {
        let hidden = Self.lanes.filter { !visible.contains($0) }
        if !hidden.isEmpty, !runOnly {
            Menu {
                ForEach(hidden, id: \.self) { lane in
                    Button(lane.title) {
                        PresentationTimelineCards.shared.addedLanes[context.item.id, default: []].insert(lane)
                    }
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
            PresentationTimelineSectionsBar(context: context, length: context.shownLength, flat: true) { map.x(ofTime: $0) }
                .frame(width: map.width, height: Self.sectionsHeight, alignment: .leading)
                .allowsHitTesting(false)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible, id: \.self) { lane in
                        laneRow(lane, cues, map: map)
                    }
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

    private func card(_ cue: TimelineCue, _ cues: [TimelineCue], map: TimelineMap) -> some View {
        let isBlock = cue.kind?.isBlock ?? false
        let left = map.x(ofTime: cue.at)
        let end = PresentationTimelines.end(of: cue, in: cues)

        let next = cues.filter { $0.kind == cue.kind && $0.at > cue.at }.map(\.at).min()
        let width: CGFloat = isBlock
            ? (end.isFinite ? map.x(ofTime: end) - left : max(map.width - left, TimelineBlockEdit.minimumWidth))
            : min(max((next.map { map.x(ofTime: $0) } ?? left + 90) - left - 1, 10), 90)

        let mode = edit.mode(of: cue.id).map { isBlock ? $0 : .move }
        let span = TimelineBlockEdit.liveSpan(x: left, width: width, mode: mode, delta: edit.delta)
        let orphan = cue.kind == .slide && PresentationTimelines.occurrence(of: cue, in: context.blocks) == nil

        let section = cue.kind == .slide ? context.presentation.sections?.first { $0.id == cue.sectionId } : nil
        let tint = orphan ? .red : GroupColor.fill(section, palette: context.model.groupColors) ?? (cue.kind?.tint ?? .gray)
        return TimelineBlockCard(
            width: span.width, tint: tint, selected: selection == cue.id
        ) {
            Text(cue.kind == .slide ? context.slideBadge(cue, width: span.width) : context.label(cue))
                .font(.system(size: 10, weight: cue.kind == .slide ? .semibold : .regular).monospacedDigit())
                .lineLimit(1)
        }
        .help(orphan ? "This slide is no longer in the arrangement: the cue won't fire" : context.label(cue))
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
            }
        }

        .position(x: span.x + span.width / 2, y: Self.laneHeight / 2)
    }

    private func move(
        _ cue: TimelineCue, mode: TimelineBlockEdit.Mode, by seconds: Double, label: String, openEnd: Double? = nil
    ) {
        context.edit(label) { timeline in
            guard let index = timeline.cues.firstIndex(where: { $0.id == cue.id }) else { return }
            timeline.cues[index] = PresentationTimelines.edited(
                timeline.cues[index], in: timeline.cues, mode: mode, by: seconds, openEnd: openEnd)
        }
    }

    private func delete(_ cue: TimelineCue) {
        selection = nil
        context.edit("Remove Cue") { $0.cues.removeAll { $0.id == cue.id } }
    }

    private func drop(_ payloads: [String], at time: Double) -> Bool {
        DiagnosticsStore.shared.note("timeline.drop.offered", detail: payloads.first ?? "none")
        guard !runOnly, let id = payloads.first, let entry = context.model.indexEntry(id) else { return false }
        let at = PresentationTimelines.snappedToFrame(time)
        let cue: TimelineCue
        switch entry.kind {
        case .overlay:
            cue = TimelineCue(id: UUID().uuidString, lane: TimelineLane.overlays.rawValue, at: at, duration: 10, overlayId: id)
        case .alertPreset:
            cue = TimelineCue(id: UUID().uuidString, lane: TimelineLane.alerts.rawValue, at: at, duration: 10, alertId: id)
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
        case .audio: "Audio"
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
        case .alerts: "exclamationmark.bubble.fill"
        case .overlays: "rectangle.bottomthird.inset.filled"
        case .slide: "rectangle.fill"
        case .videos: "play.rectangle.fill"
        case .stillGraphics: "photo.fill"
        case .loopingVideos: "film.fill"
        case .videoInput: "video.fill"
        case .audio: "music.note"
        case .actions: "bolt.fill"
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
            return cue.mediaId.flatMap { model.audio($0)?.name } ?? "Audio"
        case .videos, .stillGraphics, .loopingVideos:
            return cue.mediaId.flatMap { model.media($0)?.name } ?? "Media"
        case .actions:
            let actions = cue.actions ?? []
            guard let first = actions.first else { return "No actions" }
            return first.kind.displayName + (actions.count > 1 ? " +\(actions.count - 1)" : "")
        case nil:
            return "Unknown lane"
        }
    }
}
