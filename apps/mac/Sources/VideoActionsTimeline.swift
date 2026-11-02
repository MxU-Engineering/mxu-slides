import AVFoundation
import PresenterCore
import SwiftUI

extension MediaPreviewPlayer: TimelinePlayheadSource {
    var timelinePlayheadTime: Double { elapsed }
}

struct PendingVideoMark: Identifiable {
    let id = UUID()
    var action: SlideAction
    var at: Double
}

struct VideoActionAddMenu: View {
    let model: AppModel
    var title = "Add Video Action"
    let add: (SlideAction?) -> Void
    @Environment(\.actionRouter) private var router

    var body: some View {
        Menu {
            Button("Mark Only") { add(nil) }
                .help("A named point with no actions: a timer can count to it")
            Divider()
            AddActionMenuItems(model: model, timers: router?.timerChoices ?? []) { add($0) }
        } label: {
            Label(title, systemImage: "plus")
        }
        .fixedSize()
    }
}

enum VideoMarkColor {
    static func color(_ hex: String?) -> Color {
        hex.flatMap(GroupColor.color) ?? .yellow
    }

    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

@MainActor func videoMarkSummary(_ mark: VideoMark, model: AppModel) -> String {
    mark.actions.isEmpty
        ? "No actions"
        : mark.actions.map { slideActionLabel($0, model: model) }.joined(separator: " · ")
}

struct VideoActionsCard: View {
    let model: AppModel
    let preview: MediaPreviewPlayer
    let marks: [VideoMark]

    let trim: ClosedRange<Double>?
    let filmstrip: [CGImage]
    let add: (SlideAction?) -> Void
    let move: (_ id: String, _ to: Double) -> Void
    let remove: (_ id: String) -> Void
    let editActions: (_ id: String) -> Void
    let rename: (_ id: String) -> Void

    @State private var pointsPerSecond: Double?
    @State private var viewport: CGFloat = 0
    @State private var drag: (id: String, dx: CGFloat)?

    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 40
    static let laneHeight: CGFloat = 30

    static let zoomRange: ClosedRange<Double> = 0.05...480

    var body: some View {
        let duration = max(preview.duration, 0.01)
        let pps = pointsPerSecond
            ?? TimelineZoom.fit(seconds: duration, viewportWidth: viewport, reserve: 0, in: Self.zoomRange)
            ?? 4
        let map = TimelineMap(
            segments: [TimelineSegment(start: 0, displayDuration: duration, width: CGFloat(duration * pps))],
            pointsPerSecond: CGFloat(pps))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Video Actions")
                    .font(.system(size: 13, weight: .semibold))
                VideoActionsNextReadout(preview: preview, marks: marks, trim: trim)
                Spacer(minLength: 8)
                VideoActionAddMenu(model: model, add: add)
                    .controlSize(.small)
                    .disabled(preview.duration <= 0)

                Button { pointsPerSecond = TimelineZoom.zoomedOut(pps, in: Self.zoomRange) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .help("Zoom out")
                Button { pointsPerSecond = TimelineZoom.zoomedIn(pps, in: Self.zoomRange) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Zoom in")
                Button("Fit") { pointsPerSecond = nil }
                    .controlSize(.mini)
                    .help("Show the whole video")
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    TimelineScrubStrip(
                        map: map, interval: Self.interval(pps), label: { Self.clock($0) },
                        scrub: { time, _ in preview.seek(to: time, final: false) },
                        released: { preview.seek(to: $0, final: true) }
                    ) {
                        TimelinePlayheadHandle(
                            source: preview, segmentStarts: [0], text: PresentationTimelines.playheadClock, width: 44
                        ) { map.x(ofTime: $0) }
                    }
                    .frame(width: map.width, height: Self.rulerHeight, alignment: .topLeading)
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            strip(map)
                            lane(map)
                        }
                        trimShade(map, duration: duration)
                        TimelinePlayheadLine(source: preview) { map.x(ofTime: $0) }
                    }
                    .frame(width: map.width, height: Self.stripHeight + Self.laneHeight + 2, alignment: .topLeading)
                }
                .padding(.bottom, 4)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
            .timelinePinchZoom(current: { pps }, range: Self.zoomRange) { pointsPerSecond = $0 }
            Text("Click a mark to go there, drag it to move it, double-click to edit its actions.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.panel))
    }

    private func strip(_ map: TimelineMap) -> some View {
        HStack(spacing: 0) {
            ForEach(filmstrip.indices, id: \.self) { index in
                Image(decorative: filmstrip[index], scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: map.width / CGFloat(max(filmstrip.count, 1)), height: Self.stripHeight)
                    .clipped()
            }
        }
        .frame(width: map.width, height: Self.stripHeight, alignment: .leading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }

    private func lane(_ map: TimelineMap) -> some View {
        ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.05)
            let slots = Self.labelSlots(marks, map: map)
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                pin(mark, map: map, slot: slots[index])
            }
        }
        .frame(width: map.width, height: Self.laneHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    struct LabelSlot {
        var leading: Bool
        var row: Int
        var width: CGFloat
    }

    static func labelSlots(_ marks: [VideoMark], map: TimelineMap) -> [LabelSlot] {
        var ends: [CGFloat] = [-.infinity, -.infinity]
        var spans: [(start: CGFloat, end: CGFloat)] = []
        var slots: [LabelSlot] = marks.map { mark in
            let x = map.x(ofTime: mark.at)
            let width = CGFloat(mark.name.count) * 6.6 + 24
            let leading = x + width > map.width
            let span = leading ? (x - width, x) : (x, x + width)
            let row = ends.firstIndex { $0 < span.0 } ?? (ends[0] <= ends[1] ? 0 : 1)
            ends[row] = span.1
            spans.append(span)
            return LabelSlot(leading: leading, row: row, width: width)
        }
        for row in 0..<2 {
            let onRow = slots.indices.filter { slots[$0].row == row }.sorted { spans[$0].start < spans[$1].start }
            for (a, b) in zip(onRow, onRow.dropFirst()) where spans[a].end > spans[b].start - 4 {
                if !slots[a].leading {
                    slots[a].width = spans[b].start - 4 - spans[a].start
                } else {
                    slots[b].width = spans[b].end - spans[a].end - 4
                }
            }
        }
        return slots.map { slot in
            var slot = slot
            if slot.width < 20 { slot.width = 0 }
            return slot
        }
    }

    private func pin(_ mark: VideoMark, map: TimelineMap, slot: LabelSlot) -> some View {
        let dx = drag?.id == mark.id ? drag?.dx ?? 0 : 0
        let x = map.x(ofTime: mark.at) + dx
        let leading = slot.leading
        let live = trim.map { $0.contains(mark.at) } ?? true
        let tint = VideoMarkColor.color(mark.colorHex)
        let label = HStack(spacing: 3) {
            Image(systemName: "bolt.fill").font(.system(size: 9))
            Text(mark.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(live ? tint : Color.secondary)
        .padding(.horizontal, 4)
        .frame(width: slot.width, alignment: slot.leading ? .trailing : .leading)
        .opacity(slot.width > 0 ? 1 : 0)
        .frame(height: Self.laneHeight / 2)
        .offset(y: CGFloat(slot.row) * Self.laneHeight / 2 - Self.laneHeight / 4)
        return HStack(spacing: 0) {
            if leading { label }
            Rectangle().fill(live ? tint : Color.secondary).frame(width: 2, height: Self.laneHeight)
            if !leading { label }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .help("\(Self.clock(mark.at)) · \(videoMarkSummary(mark, model: model))")
        .onTapGesture(count: 2) { editActions(mark.id) }
        .onTapGesture { preview.seek(to: mark.at, final: true) }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { drag = (mark.id, $0.translation.width) }
                .onEnded { value in
                    drag = nil
                    let landed = map.locate(x: max(map.x(ofTime: mark.at) + value.translation.width, 0))?.time
                    if let landed { move(mark.id, landed) }
                }
        )
        .contextMenu {
            Button("Edit Actions\u{2026}") { editActions(mark.id) }
            Button("Rename\u{2026}") { rename(mark.id) }
            Button("Go Here") { preview.seek(to: mark.at, final: true) }
            Divider()
            Button("Nudge 1 Frame Earlier") { move(mark.id, mark.at - frame) }
            Button("Nudge 1 Frame Later") { move(mark.id, mark.at + frame) }
            Divider()
            Button("Remove") { remove(mark.id) }
        }
        .alignmentGuide(.leading) { d in leading ? d.width - x : -x }
    }

    private var frame: Double {
        1 / ((preview.frameRate ?? 0) > 0 ? preview.frameRate! : Double(PresentationTimelines.framesPerSecond))
    }

    private func trimShade(_ map: TimelineMap, duration: Double) -> some View {
        let lower = map.x(ofTime: trim?.lowerBound ?? 0)
        let upper = map.x(ofTime: trim?.upperBound ?? duration)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.5).frame(width: lower)
            Color.black.opacity(0.5).frame(width: max(map.width - upper, 0)).padding(.leading, upper)
        }
        .frame(width: map.width, height: Self.stripHeight + Self.laneHeight + 2, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    static func interval(_ pps: Double) -> Double {
        [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800].first { $0 * pps >= 56 } ?? 3600
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated static func filmstrip(url: URL, count: Int = 24) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        var frames: [CGImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let frame = try? await generator.image(at: time).image { frames.append(frame) }
        }
        return frames
    }
}

private struct VideoActionsNextReadout: View {
    let preview: MediaPreviewPlayer
    let marks: [VideoMark]
    let trim: ClosedRange<Double>?

    var body: some View {
        let position = preview.elapsed
        let next = marks.first { $0.at > position + 0.001 && (trim?.contains($0.at) ?? true) }
        Text(next.map { "Next: \($0.name) in \(VideoActionsCard.clock($0.at - position))" }
            ?? (marks.isEmpty ? "Add a mark at the playhead" : "No more actions"))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct VideoActionsSection: View {
    let model: AppModel
    let marks: [VideoMark]
    let add: (SlideAction?) -> Void

    let rename: (_ id: String) -> Void

    let recolor: (_ id: String, _ hex: String) -> Void
    let remove: (_ id: String) -> Void
    let editActions: (_ id: String) -> Void
    let goTo: (_ at: Double) -> Void

    var body: some View {
        Section {
            ForEach(marks) { mark in
                HStack(alignment: .center, spacing: 8) {
                    ColorPicker("", selection: Binding(
                        get: { VideoMarkColor.color(mark.colorHex) },
                        set: { color in
                            if let hex = VideoMarkColor.hex(of: NSColor(color)) { recolor(mark.id, hex) }
                        }), supportsOpacity: false)
                        .labelsHidden()
                        .help("This action's color on the timeline and Present's transport strip")
                    Button(PresentationTimelines.playheadClock(mark.at)) { goTo(mark.at) }
                        .buttonStyle(.plain)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Go here in the preview")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mark.name)
                            .lineLimit(1)
                        Text(videoMarkSummary(mark, model: model))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Edit Actions\u{2026}") { editActions(mark.id) }
                        Button("Rename\u{2026}") { rename(mark.id) }
                        Button("Go Here") { goTo(mark.at) }
                        Divider()
                        Button("Remove") { remove(mark.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            VideoActionAddMenu(model: model, title: "Add at Playhead", add: add)
        } header: {
            Text("Video Actions")
        } footer: {
            if !marks.isEmpty {
                Text("Each runs when the video plays across it, every time it loops. Scrubbing or jumping past one skips it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
