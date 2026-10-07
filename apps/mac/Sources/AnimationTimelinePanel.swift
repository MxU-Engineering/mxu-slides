import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct AnimationTimelinePanel: View {
    let model: SlideEditorModel

    @State private var zoomGestureBase: Double?

    @State private var draggingStepID: String?
    @State private var dragTranslation: CGFloat = 0

    @State private var resizingStepID: String?
    @State private var resizeDelta: CGFloat = 0

    @State private var trimmingStepID: String?
    @State private var trimDelta: CGFloat = 0

    @State private var effectPickerID: DialsTarget?

    @State private var galleryTarget: GalleryTarget?

    private struct DialsTarget: Identifiable {
        var id: String
    }

    private struct GalleryTarget: Identifiable, Equatable {
        var objectID: String
        var slot: AnimationSequence.GroupSlot
        var id: String { "\(objectID)-\(String(describing: slot))" }
    }

    @State private var hoveredLane: (objectID: String, column: Int)?

    @State private var multiSelection: Set<String> = []

    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?

    @State private var marqueeDeclined = false

    @State private var blockFrames: [String: CGRect] = [:]

    @State private var lanesFrame: CGRect = .zero

    @State private var lanesAnchor = AnchorBox()

    @State private var blockPressStart: CGPoint?

    @State private var resizeContext: (group: SceneAnimationGroup, endSeconds: Double)?

    @State private var dropTargetGroup: SceneAnimationGroup?
    @State private var dropPastEdge = false

    @State private var insertClickAt: (index: Int, x: CGFloat)?

    @State private var headerHovered = false

    static let draftClickIndex = 9_999

    @State private var laneScrollProxy: ScrollViewProxy?

    @State private var dragLaneOverhangX: CGFloat = 0

    @State private var autoScrollTimer: Timer?

    @State private var laneViewportWidth: CGFloat = 0

    @State private var rowsViewportHeight: CGFloat = 0
    @State private var rowsContentHeight: CGFloat = 0
    @State private var rowsViewportMinY: CGFloat = 0
    @State private var rowsContentMinY: CGFloat = 0

    private let labelWidth: CGFloat = 200

    private var rowHeight: CGFloat { CGFloat(model.timelineRowHeight) }

    private var blockY: CGFloat { max((rowHeight - 22) / 2, 2) }
    private let headerHeight: CGFloat = 36
    private let scrubHeight: CGFloat = 22

    private let minColumnPoints: CGFloat = 96

    var body: some View {
        let _ = BodyMeter.tick(.animationTimelinePanel)
        let timeline: AnimationTimelineLayout.Timeline = {
            var timeline = model.timelineLayout
            guard let at = model.timelineDraftClickAt else { return timeline }
            let start = timeline.columns.last?.start ?? 0
            let draft = AnimationTimelineLayout.Column(
                group: .click(Self.draftClickIndex), start: start, duration: 0,
                displayDuration: AnimationTimelineLayout.minimumColumnSeconds
            )

            var clicksSeen = 0
            var insertion = timeline.columns.count
            for (index, column) in timeline.columns.enumerated() {
                if case .click = column.group {
                    if clicksSeen == at { insertion = index; break }
                    clicksSeen += 1
                } else if column.group == .exit {
                    insertion = index
                    break
                }
            }
            timeline.columns.insert(draft, at: insertion)
            return timeline
        }()
        VStack(spacing: 0) {
            transportRow(timeline)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                cornerCell(timeline)
                    .frame(width: labelWidth)
                Divider()
                GeometryReader { strip in
                    VStack(alignment: .leading, spacing: 0) {
                        columnHeaders(timeline)
                            .frame(height: headerHeight)
                        scrubStrip(timeline)
                            .frame(height: scrubHeight)
                    }
                    .frame(width: max(laneWidth(timeline), dragLaneOverhangX) + 120, alignment: .leading)
                    .offset(x: lanesFrame.minX - strip.frame(in: .global).minX)
                }
                .clipped()
            }
            .frame(height: headerHeight + scrubHeight)
            Divider()
            ScrollViewReader { rowsProxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    labelRows(timeline)
                        .frame(width: labelWidth)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            laneColumn(timeline)
                        }

                        .scrollIndicators(.visible)
                        .onAppear { laneScrollProxy = proxy }
                    }

                    .onChange(of: timeline.columns.map(\.displayDuration).reduce(0, +)) { _, _ in
                        autoFitIfNeeded(timeline)
                    }
                    .background(
                        GeometryReader { lanes in
                            Color.clear
                                .onAppear {
                                    laneViewportWidth = lanes.size.width
                                    autoFitIfNeeded(timeline)
                                }
                                .onChange(of: lanes.size.width) { _, width in
                                    laneViewportWidth = width
                                    autoFitIfNeeded(timeline)
                                }
                        }
                    )
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let base = zoomGestureBase ?? model.timelinePointsPerSecond
                                zoomGestureBase = base
                                model.timelineZoomAdjusted = true
                                model.timelinePointsPerSecond =
                                    min(max(base * value.magnification, 24), 480)
                            }
                            .onEnded { _ in zoomGestureBase = nil }
                    )
                }
                .background(
                    GeometryReader { content in
                        Color.clear
                            .onAppear {
                                rowsContentHeight = content.size.height
                                rowsContentMinY = content.frame(in: .global).minY
                            }
                            .onChange(of: content.size.height) { _, h in rowsContentHeight = h }
                            .onChange(of: content.frame(in: .global).minY) { _, y in rowsContentMinY = y }
                    }
                )
                .id("rows.content")
            }
            .background(
                GeometryReader { viewport in
                    Color.clear
                        .onAppear {
                            rowsViewportHeight = viewport.size.height
                            rowsViewportMinY = viewport.frame(in: .global).minY
                        }
                        .onChange(of: viewport.size.height) { _, h in rowsViewportHeight = h }
                        .onChange(of: viewport.frame(in: .global).minY) { _, y in rowsViewportMinY = y }
                }
            )

            .simultaneousGesture(marqueeGesture(rowEntries(timeline), in: timeline))
            .overlay(alignment: .bottom) {
                rowsOverflowHint(.down, proxy: rowsProxy)
            }
            .overlay(alignment: .top) {
                rowsOverflowHint(.up, proxy: rowsProxy)
            }
            }
            Divider()
            footerRow(timeline)
        }
        .font(.caption)

        .focusable(true)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if model.animationPreviewPlaying {
                model.stopAnimationPreview()
            } else {
                model.playPreviewScope()
            }
            return .handled
        }

        .onChange(of: model.selectedSlideID) { _, _ in
            model.timelineDraftClickAt = nil
            autoFitIfNeeded(model.timelineLayout)
        }

        .onChange(of: AnimationSequence.clickCount(
            objects: model.currentSlide?.objects ?? [], order: model.currentSlide?.animationOrder
        )) { old, new in
            if new > old { model.timelineDraftClickAt = nil }
        }

        .onDeleteCommand {
            if let id = model.selectedAnimationStepID { model.removeAnimationStep(id) }
        }
        .background(
            Button("") {
                if let id = model.selectedAnimationStepID { model.duplicateAnimationStep(id) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .opacity(0)
        )
    }

    private var pointsPerSecond: CGFloat { CGFloat(model.timelinePointsPerSecond) }

    private func columnWidth(_ column: AnimationTimelineLayout.Column) -> CGFloat {

        var width = column.duration > 0
            ? CGFloat(column.displayDuration) * pointsPerSecond
            : max(CGFloat(column.displayDuration) * pointsPerSecond, minColumnPoints)
        if let context = resizeContext, context.group == column.group {

            width = max(width, CGFloat(context.endSeconds) * pointsPerSecond + resizeDelta)
        }
        return width
    }

    private func columnX(_ index: Int, in timeline: AnimationTimelineLayout.Timeline) -> CGFloat {
        timeline.columns.prefix(index).reduce(0) { $0 + columnWidth($1) }
    }

    private func laneWidth(_ timeline: AnimationTimelineLayout.Timeline) -> CGFloat {
        timeline.columns.reduce(0) { $0 + columnWidth($1) }
    }

    private func x(ofTime t: Double, in timeline: AnimationTimelineLayout.Timeline) -> CGFloat {
        var x: CGFloat = 0
        for (index, column) in timeline.columns.enumerated() {
            let width = columnWidth(column)
            let next = index + 1 < timeline.columns.count ? timeline.columns[index + 1].start : .infinity
            if t < next {
                let offset = max(t - column.start, 0)
                return x + min(CGFloat(offset) * pointsPerSecond, width)
            }
            x += width
        }
        return x
    }

    private func time(atX x: CGFloat, in timeline: AnimationTimelineLayout.Timeline)
        -> (time: Double, group: SceneAnimationGroup)? {
        var cursor: CGFloat = 0
        for column in timeline.columns {
            let width = columnWidth(column)
            if x < cursor + width || column.group == timeline.columns.last?.group {
                let offset = Double(max(x - cursor, 0) / pointsPerSecond)
                return (column.start + min(offset, column.displayDuration), column.group)
            }
            cursor += width
        }
        return nil
    }

    private var previewActive: Bool { model.animationPreviewActive }

    private func transportRow(_ timeline: AnimationTimelineLayout.Timeline) -> some View {
        HStack(spacing: 10) {
            Button {
                model.setAnimationPreviewTime(0)
            } label: {
                Image(systemName: "backward.end.fill").frame(width: 14)
            }
            .buttonStyle(.plain)
            .help("Go to the top")
            Button {
                if model.animationPreviewPlaying {
                    model.stopAnimationPreview()
                } else {
                    model.playPreviewScope()
                }
            } label: {
                Image(systemName: model.animationPreviewPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(model.animationPreviewPlaying ? "Stop the preview" : "Play the animation on this canvas (never on glass)")
            Picker("Play", selection: Binding(
                get: { model.previewScope },
                set: { model.previewScope = $0 }
            )) {
                ForEach(SlideEditorModel.PreviewScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            Toggle(isOn: Binding(
                get: { model.previewRepeats },
                set: { model.previewRepeats = $0 }
            )) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .controlSize(.small)
            .foregroundStyle(model.previewRepeats ? Color.accentColor : Color.secondary)
            .help("Repeat the play scope until stopped. Off = play once.")
            Spacer()
            PlayheadReadout(model: model, duration: timeline.duration)
            if previewActive {
                Button("Done") { model.stopAnimationPreview() }
                    .controlSize(.small)
                    .help("Leave the preview. The canvas shows everything again.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private struct RowEntry: Identifiable {
        var id: String { objectID }
        var objectID: String
        var name: String
        var icon: String
        var fromTheme: Bool
        var hidden: Bool
        var hasScroll: Bool
        var layout: AnimationTimelineLayout.Row?
    }

    private func rowEntries(_ timeline: AnimationTimelineLayout.Timeline) -> [RowEntry] {
        let layoutByID = Dictionary(uniqueKeysWithValues: timeline.rows.map { ($0.objectID, $0) })
        var entries: [RowEntry] = model.panelStackTopFirst.map { entry in
            RowEntry(
                objectID: entry.object.id,
                name: entry.object.name.isEmpty
                    ? entry.object.objectKind.rawValue.capitalized : entry.object.name,
                icon: SlideEditorView.objectIcon(entry.object),
                fromTheme: entry.fromTheme,
                hidden: entry.object.hidden == true,
                hasScroll: entry.object.textStyle?.scroll != nil,
                layout: entry.fromTheme ? nil : layoutByID[entry.object.id]
            )
        }
        if model.timelineAnimatedOnly {
            entries = entries.filter { entry in
                entry.hasScroll || !(entry.layout?.blocks.isEmpty ?? true)
            }
        }
        return entries
    }

    private var totalObjectCount: Int { model.panelStackTopFirst.count }

    private func cornerCell(_ timeline: AnimationTimelineLayout.Timeline) -> some View {
        let entries = rowEntries(timeline)

        return HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.timelineAnimatedOnly },
                set: { model.timelineAnimatedOnly = $0 }
            )) {
                Text("Animated only")
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            Spacer(minLength: 2)
            Text("\(entries.count) of \(totalObjectCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: headerHeight + scrubHeight)
    }

    private func labelRows(_ timeline: AnimationTimelineLayout.Timeline) -> some View {
        let entries = rowEntries(timeline)
        return VStack(spacing: 0) {
            ForEach(entries) { entry in
                rowLabel(entry)
                    .frame(height: rowHeight)
                Divider().opacity(0.4)
            }
            if let background = cueBackgroundName {
                cueBackgroundLabel(background)
                    .frame(height: rowHeight)
            }
        }
    }

    private func rowLabel(_ entry: RowEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.icon)
                .frame(width: 14)
                .imageScale(.small)
            Text(entry.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if entry.fromTheme {
                Image(systemName: "paintpalette")
                    .imageScale(.small)
            } else if entry.hidden {
                Image(systemName: "eye.slash")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .foregroundStyle(entry.fromTheme ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .opacity(entry.hidden ? 0.5 : 1)
        .contentShape(Rectangle())

        .onDrag {
            NSItemProvider(object: NSString(string: Self.objectDragPrefix + entry.objectID))
        }
        .background(
            model.selectedObjectIDs == [entry.objectID]
                ? Color.accentColor.opacity(0.15) : .clear
        )
        .simultaneousGesture(

            TapGesture().onEnded {
                guard !entry.fromTheme else { return }
                model.setSelection([entry.objectID])
            }
        )
        .contextMenu {
            if !entry.fromTheme {
                Button(entry.hidden ? "Show" : "Hide") {
                    model.updateObject(id: entry.objectID) {
                        $0.hidden = $0.hidden == true ? nil : true
                    }
                }
            }
        }
        .help(entry.fromTheme ? "From the theme — edit it in the theme editor" : entry.name)
    }

    private var cueBackgroundName: String? {
        guard let slide = model.currentSlide, !model.isSingleComposition else { return nil }
        guard let background = SlideSceneBuilder.effectiveBackground(
            slide: slide, presentation: model.presentation, arrangementId: nil
        ) else { return nil }

        return model.appModel.media(background.mediaId)?.name ?? "Background"
    }

    private func cueBackgroundLabel(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .frame(width: 14)
                .imageScale(.small)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            Text("CUE BG")
                .font(.system(size: 8, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 0.5))
        }
        .padding(.horizontal, 10)
        .foregroundStyle(.tertiary)
        .help("The cue background runs underneath the whole slide — it persists across advances and is not part of this slide's animation.")
    }

    private func laneColumn(_ timeline: AnimationTimelineLayout.Timeline) -> some View {
        let entries = rowEntries(timeline)

        let width = max(laneWidth(timeline), dragLaneOverhangX) + 120

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {

                ForEach(Array(timeline.columns.indices.dropFirst()), id: \.self) { index in
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .offset(x: columnX(index, in: timeline))
                }
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        lane(for: entry, in: timeline)
                            .frame(width: width, height: rowHeight, alignment: .topLeading)
                        Divider().opacity(0.4)
                    }
                    if cueBackgroundName != nil {
                        ambientLane(label: "runs the whole slide · persists across advances")
                            .frame(width: width, height: rowHeight, alignment: .leading)
                    }
                }

                let rect = marqueeRect ?? .zero
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(marqueeRect != nil ? 1 : 0)
                    .allowsHitTesting(false)
                PlayheadLine(model: model) { x(ofTime: $0, in: timeline) }
                    .opacity(previewActive ? 1 : 0)

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2.5)
                    .offset(x: (insertClickAt?.x ?? 0) - 1)
                    .opacity(insertClickAt != nil ? 1 : 0)
                    .allowsHitTesting(false)
            }

            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { lanesFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in lanesFrame = f }
                }
            )
            .background(ScreenAnchorView(box: lanesAnchor))
            .onDrop(of: [.plainText], delegate: ObjectDropDelegate(
                columnAt: { x in
                    var cursor: CGFloat = 0
                    for (index, column) in timeline.columns.enumerated() {
                        cursor += columnWidth(column)
                        if x < cursor { return index }
                    }
                    return timeline.columns.indices.last
                },
                open: { objectID, columnIndex in
                    guard timeline.columns.indices.contains(columnIndex) else { return }
                    let group = timeline.columns[columnIndex].group

                    hoveredLane = (objectID, columnIndex)
                    presentGallery(GalleryTarget(objectID: objectID, slot: slot(for: group)))
                }
            ))
        }
        .frame(width: width, alignment: .topLeading)
    }

    static let objectDragPrefix = "mxu.animate.object:"

    private struct HeaderItem: Identifiable {
        var index: Int
        var column: AnimationTimelineLayout.Column
        var id: String
    }

    private func columnHeaders(_ timeline: AnimationTimelineLayout.Timeline) -> some View {

        let items = timeline.columns.enumerated().map { pair in
            HeaderItem(
                index: pair.offset, column: pair.element,
                id: "\(columnTitle(pair.element.group))#\(timeline.columns.count)"
            )
        }
        return HStack(spacing: 0) {
            ForEach(items) { item in
                let index = item.index
                let column = item.column
                let focused = model.timelineFocusColumn == column.group
                let dropping = dropTargetGroup == column.group
                HStack(spacing: 6) {

                    Spacer(minLength: 0)
                    Text(columnTitle(column.group))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(focused || dropping ? Color.accentColor : Color.primary)
                    if focused {
                        Button {
                            model.playColumn(column.group)
                        } label: {

                            Image(systemName: "play.fill")
                                .imageScale(.medium)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Play just this click")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: columnWidth(column), height: headerHeight, alignment: .center)

                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(dropping
                            ? Color.accentColor.opacity(0.16)
                            : focused
                                ? Color.accentColor.opacity(0.10)
                                : Color.primary.opacity(0.05))
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                )
                .contentShape(Rectangle())
                .simultaneousGesture(

                    TapGesture().onEnded {

                        @MainActor func parkDraft(beforeColumn boundaryIndex: Int) {
                            let before = timeline.columns.prefix(boundaryIndex).filter {
                                if case .click = $0.group { return true }
                                return false
                            }.count
                            DiagnosticsStore.shared.note("timeline.plusClick", detail: "between at=\(before)")
                            model.timelineDraftClickAt = before
                        }

                        if model.timelineDraftClickAt == nil, let press = pressLocal() {
                            for boundary in 1..<timeline.columns.count
                            where abs(press.x - columnX(boundary, in: timeline)) <= 13 {
                                parkDraft(beforeColumn: boundary)
                                return
                            }
                        }
                        model.timelineFocusColumn = column.group
                    }
                )
                .contextMenu { columnMenu(column.group, in: timeline) }
            }

            Button {

                let realClicks = model.timelineLayout.columns.filter {
                    if case .click = $0.group { return true }
                    return false
                }.count
                DiagnosticsStore.shared.note("timeline.plusClick", detail: "toggled=\(model.timelineDraftClickAt == nil)")
                model.timelineDraftClickAt = model.timelineDraftClickAt == nil ? realClicks : nil
            } label: {
                Label("Click", systemImage: "plus")
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: headerHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(dropPastEdge || model.timelineDraftClickAt != nil
                ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .help("Add a new click column - it becomes real with its first animation")
        }

        .overlay(alignment: .topLeading) {

            if headerHovered, model.timelineDraftClickAt == nil, timeline.columns.count > 1 {
                ForEach(1..<timeline.columns.count, id: \.self) { boundary in
                    HStack(spacing: 0) {

                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white, Color.accentColor)
                            .background(Circle().fill(.background).padding(-2))
                            .frame(width: 26, height: headerHeight)
                            .allowsHitTesting(false)
                            .help("Add a click here")
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, max(columnX(boundary, in: timeline) - 13, 0))
                }
            }
        }

        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !headerHovered {
                    DiagnosticsStore.shared.note("timeline.headerHover", detail: "true")
                    headerHovered = true
                }
            case .ended:
                headerHovered = false
            }
        }
    }

    @ViewBuilder
    private func columnMenu(_ group: SceneAnimationGroup, in timeline: AnimationTimelineLayout.Timeline) -> some View {
        let source = slot(for: group)
        let clickCount = timeline.columns.filter {
            if case .click(let n) = $0.group { return n != Self.draftClickIndex }
            return false
        }.count

        if group == .click(Self.draftClickIndex) {
            Button("Remove This Click") { model.timelineDraftClickAt = nil }
        } else {
            Section("Move Everything Here") {
                if group != .auto {
                    Button("To With Slide") { model.moveTimelineColumn(from: source, to: .auto) }
                }
                ForEach(0..<clickCount, id: \.self) { n in
                    if group != .click(n) {
                        Button("To Click \(n + 1)") { model.moveTimelineColumn(from: source, to: .click(n)) }
                    }
                }
                if group != .click(clickCount - 1) {

                    Button("To a New Final Click") { model.moveTimelineColumn(from: source, to: .click(clickCount)) }
                }
                if group != .exit {
                    Button("To Final") { model.moveTimelineColumn(from: source, to: .exit) }
                }
            }

            if case .click = group {
                Divider()
                Button("Delete Click and Its Effects", role: .destructive) {
                    model.deleteTimelineColumn(source)
                }
            }
        }
    }

    private func columnTitle(_ group: SceneAnimationGroup) -> String {
        switch group {
        case .auto: "With Slide"
        case .click(Self.draftClickIndex): "New Click"
        case .click(let n): "Click \(n + 1)"
        case .exit: "Final"
        }
    }

    private func scrubStrip(_ timeline: AnimationTimelineLayout.Timeline) -> some View {
        ZStack(alignment: .topLeading) {

            ForEach(Array(timeline.columns.enumerated()), id: \.offset) { index, column in
                let width = columnWidth(column)
                HStack(spacing: 0) {
                    let ticks = max(Int(column.displayDuration / 0.5), 1)
                    ForEach(0..<ticks, id: \.self) { tick in
                        Text(tick == 0 ? "0s" : String(format: "%.1f", Double(tick) * 0.5))
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)
                            .frame(width: 0.5 * pointsPerSecond, alignment: .leading)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(.quaternary).frame(width: 0.5)
                            }
                            .clipped()
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: width, alignment: .leading)
                .offset(x: columnX(index, in: timeline))
            }
            if previewActive {
                PlayheadHandle(model: model, columns: timeline.columns) { x(ofTime: $0, in: timeline) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let landed = time(atX: value.location.x, in: timeline) else { return }

                    if model.timelineFocusColumn != landed.group { model.timelineFocusColumn = landed.group }
                    model.setAnimationPreviewTime(landed.time)
                }
        )
        .background(Color.primary.opacity(0.04))
    }

    private func lane(for entry: RowEntry, in timeline: AnimationTimelineLayout.Timeline) -> some View {
        ZStack(alignment: .topLeading) {
            if entry.hasScroll {
                ambientLane(label: "Block Scroll · runs from the fire")
            } else if let layout = entry.layout {

                laneFloor(entry, layout: layout, in: timeline)
                presenceBar(layout, in: timeline)
                    .allowsHitTesting(false)
                ForEach(layout.blocks, id: \.stepID) { block in
                    blockView(block, in: timeline)
                }

                let hoverColumn: Int? = {
                    guard let hover = hoveredLane, hover.objectID == entry.objectID,
                          timeline.columns.indices.contains(hover.column) else { return nil }
                    return hover.column
                }()
                addButton(entry, layout: layout, columnIndex: hoverColumn ?? 0, in: timeline)
                    .opacity(hoverColumn != nil ? 1 : 0)
                    .allowsHitTesting(hoverColumn != nil)
            } else if entry.fromTheme {

                presenceBarFullSpan(in: timeline).opacity(0.4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        .onContinuousHover { phase in

            guard galleryTarget == nil else { return }
            switch phase {
            case .active(let point):
                let index = columnIndex(atX: point.x, in: timeline)
                if hoveredLane?.objectID != entry.objectID || hoveredLane?.column != index {
                    hoveredLane = (entry.objectID, index)
                }
            case .ended:
                if hoveredLane?.objectID == entry.objectID { hoveredLane = nil }
            }
        }
    }

    private func laneFloor(
        _ entry: RowEntry, layout: AnimationTimelineLayout.Row,
        in timeline: AnimationTimelineLayout.Timeline
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: laneWidth(timeline), height: rowHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(

                TapGesture().onEnded { multiSelection = [] }
            )
            .contextMenu {
                let index = hoveredLane?.objectID == entry.objectID
                    ? (hoveredLane?.column ?? 0) : 0
                if timeline.columns.indices.contains(index) {
                    let column = timeline.columns[index]
                    laneMenu(
                        entry, layout: layout, column: column,
                        target: GalleryTarget(objectID: entry.objectID, slot: slot(for: column.group))
                    )
                }
            }
    }

    private func addButton(
        _ entry: RowEntry, layout: AnimationTimelineLayout.Row,
        columnIndex index: Int, in timeline: AnimationTimelineLayout.Timeline
    ) -> some View {
        let column = timeline.columns[index]
        let target = GalleryTarget(objectID: entry.objectID, slot: slot(for: column.group))
        return Button {
            presentGallery(target)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .offset(x: columnX(index, in: timeline) + columnWidth(column) - 26, y: max((rowHeight - 20) / 2, 2))
        .popover(item: Binding(
            get: { galleryTarget == target ? galleryTarget : nil },
            set: { galleryTarget = $0 }
        ), arrowEdge: .bottom) { _ in
            ScrollView {
                AnimationGallery(model: model)
                    .padding(12)
            }
            .frame(width: 340, height: 320)
        }
        .help("Add an animation here")
    }

    private func columnIndex(atX x: CGFloat, in timeline: AnimationTimelineLayout.Timeline) -> Int {
        var cursor: CGFloat = 0
        for (index, column) in timeline.columns.enumerated() {
            cursor += columnWidth(column)
            if x < cursor { return index }
        }
        return max(timeline.columns.count - 1, 0)
    }

    @ViewBuilder
    private func laneMenu(
        _ entry: RowEntry, layout: AnimationTimelineLayout.Row,
        column: AnimationTimelineLayout.Column, target: GalleryTarget
    ) -> some View {
        let defaultIn = model.appModel.animationDefaultIn
        let defaultOut = model.appModel.animationDefaultOut
        let outFirst = column.group == .exit
            || layout.presenceEnd.map { column.start >= $0 - 0.001 } ?? false
        let inButton = Button("Apply Default In: \(defaultIn.animation.rawValue.capitalized)") {
            model.applyDefaultStep(.in, objectID: entry.objectID, into: target.slot)
        }
        let outButton = Button("Apply Default Out: \(defaultOut.animation.rawValue.capitalized)") {
            model.applyDefaultStep(.out, objectID: entry.objectID, into: target.slot)
        }
        if outFirst { outButton; inButton } else { inButton; outButton }
        Divider()
        Button("Add Animation…") { presentGallery(target) }
    }

    private func presentGallery(_ target: GalleryTarget) {
        model.setSelection([target.objectID])
        model.armStepAdd(into: target.slot)
        galleryTarget = target
    }

    private func presenceBar(
        _ row: AnimationTimelineLayout.Row, in timeline: AnimationTimelineLayout.Timeline
    ) -> some View {
        let startX = row.presenceStart.map { x(ofTime: $0, in: timeline) } ?? 2
        let endX = row.presenceEnd.map { x(ofTime: $0, in: timeline) } ?? (laneWidth(timeline) - 2)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .frame(width: max(endX - startX, 8), height: 24)
            .offset(x: startX, y: blockY)
            .help("On screen for this span — computed from the steps, never authored. The ends take Apply Default In/Out in Stage C.")
    }

    private func presenceBarFullSpan(in timeline: AnimationTimelineLayout.Timeline) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.05))
            .frame(width: max(laneWidth(timeline) - 4, 8), height: 24)
            .offset(x: 2, y: blockY)
    }

    private func ambientLane(label: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(ImagePaint(
                image: Image(systemName: "line.diagonal"), scale: 0.4
            ))
            .opacity(0.12)
            .frame(height: 16)
            .padding(.horizontal, 2)
            .overlay(
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8),
                alignment: .leading
            )
            .offset(y: max((rowHeight - 16) / 2, 2))
            .help("Ambient — display only this stage. It runs on the show's clock, not the click timeline.")
    }

    private func blockView(
        _ block: AnimationTimelineLayout.Block, in timeline: AnimationTimelineLayout.Timeline
    ) -> some View {
        let columnIndex = timeline.columns.firstIndex { $0.group == block.group } ?? 0
        let dragging = draggingStepID == block.stepID

        let groupDragging = !dragging && draggingStepID.map {
            multiSelection.count > 1 && multiSelection.contains($0)
                && multiSelection.contains(block.stepID)
        } ?? false
        let resizing = resizingStepID == block.stepID
        let trimming = trimmingStepID == block.stepID
        let xPos = columnX(columnIndex, in: timeline)
            + CGFloat(block.startOffset) * pointsPerSecond
            + (dragging || groupDragging ? dragTranslation : 0)
            + (trimming ? trimDelta : 0)
        let width = max(
            CGFloat(block.duration) * pointsPerSecond
                + (resizing ? resizeDelta : 0)
                - (trimming ? trimDelta : 0),
            26
        )

        let liveDuration: Double = {
            if resizing {
                return max(((block.duration + Double(resizeDelta / pointsPerSecond)) * 20).rounded() / 20, 0.05)
            }
            if trimming {
                return max(((block.duration - Double(trimDelta / pointsPerSecond)) * 20).rounded() / 20, 0.05)
            }
            return block.duration
        }()
        let adjusting = resizing || trimming
        let selected = model.selectedAnimationStepID == block.stepID
            || multiSelection.contains(block.stepID)
        let warning = model.stepWarnings[block.stepID]
        return HStack(spacing: 4) {

            if let (_, step) = model.animationStep(id: block.stepID) {
                Text(model.animationSentence(step))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(Self.durationLabel(liveDuration))
                    .font(.system(size: 9, weight: adjusting ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(adjusting ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            if warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 22, alignment: .leading)
        .background(block.kind.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : block.kind.tint.opacity(0.4),
                        lineWidth: selected ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {

            if block.rampIn { rampWedge(block.kind.tint, leading: true) }
        }
        .overlay(alignment: .trailing) {
            if block.rampOut { rampWedge(block.kind.tint, leading: false) }
        }
        .overlay(alignment: .trailing) {

            RoundedRectangle(cornerRadius: 2)
                .fill(block.kind.tint.opacity(0.55))
                .frame(width: 4, height: 14)
                .padding(.trailing, 2)
                .allowsHitTesting(false)
                .help("Drag to change how long it runs")
        }
        .overlay(alignment: .leading) {

            RoundedRectangle(cornerRadius: 2)
                .fill(block.kind.tint.opacity(0.55))
                .frame(width: 4, height: 14)
                .padding(.leading, 2)
                .allowsHitTesting(false)
                .help("Drag to move where it starts; the end stays put")
        }
        .clipped()
        .overlay(alignment: .leading) {

            if block.linked {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .offset(x: -8)
                    .help("After Previous — starts when the step before it completes")
            }
        }

        .contentShape(Rectangle().inset(by: -4))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { blockFrames[block.stepID] = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, f in blockFrames[block.stepID] = f }
            }
        )
        .simultaneousGesture(

            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    guard let mouse = mouseLocal() else { return }
                    let engaged = draggingStepID == block.stepID
                        || resizingStepID == block.stepID
                        || trimmingStepID == block.stepID
                    let start = blockPressStart ?? pressLocal() ?? mouse
                    if blockPressStart == nil { blockPressStart = start }
                    let dx = mouse.x - start.x
                    guard abs(dx) > 3 || engaged else { return }
                    if !engaged {

                        let frame = blockLocal(block.stepID) ?? .zero
                        let baseWidth = max(frame.width, 26)
                        let edgeZone = min(12, max(baseWidth / 3, 6))
                        let local = start.x - frame.minX
                        if local > baseWidth - edgeZone {
                            resizingStepID = block.stepID
                            resizeContext = (block.group, block.startOffset + block.duration)
                        } else if local < edgeZone, baseWidth >= 34 {
                            trimmingStepID = block.stepID
                        } else {
                            draggingStepID = block.stepID
                        }
                        DiagnosticsStore.shared.note(
                            "timeline.block.engage",
                            detail: "id=\(block.stepID.suffix(14)) mode=\(resizingStepID != nil ? "resize" : trimmingStepID != nil ? "trim" : "move") start=(\(Int(start.x)),\(Int(start.y))) frame=\(Int(frame.minX))..\(Int(frame.maxX))"
                        )
                    }
                    if resizingStepID == block.stepID {
                        resizeDelta = dx
                        armAutoScroll()
                    } else if trimmingStepID == block.stepID {
                        trimDelta = dx
                        armAutoScroll()
                    } else {
                        dragTranslation = dx

                        let columnIndex = timeline.columns.firstIndex { $0.group == block.group } ?? 0
                        let landedX = columnX(columnIndex, in: timeline)
                            + CGFloat(block.startOffset) * pointsPerSecond + dx
                        dragLaneOverhangX = landedX + CGFloat(block.duration) * pointsPerSecond
                        if let boundary = newClickBoundary(at: landedX, in: timeline) {
                            insertClickAt = boundary
                            dropPastEdge = false
                            dropTargetGroup = nil
                        } else if landedX >= laneWidth(timeline) {
                            insertClickAt = nil
                            dropPastEdge = true
                            dropTargetGroup = nil
                        } else {
                            insertClickAt = nil
                            dropPastEdge = false
                            var cursor: CGFloat = 0
                            var target: SceneAnimationGroup?
                            for column in timeline.columns {
                                let width = columnWidth(column)
                                if landedX < cursor + width { target = column.group; break }
                                cursor += width
                            }
                            dropTargetGroup = target == block.group ? nil : target
                        }
                    }
                    armAutoScroll()
                }
                .onEnded { _ in
                    let resized = resizingStepID == block.stepID
                    let trimmed = trimmingStepID == block.stepID
                    let dragged = draggingStepID == block.stepID
                    let dx: CGFloat
                    if let start = blockPressStart, let mouse = mouseLocal() {
                        dx = mouse.x - start.x
                    } else {
                        dx = 0
                    }
                    blockPressStart = nil
                    DiagnosticsStore.shared.note(
                        "timeline.gesture",
                        detail: "id=\(block.stepID.suffix(12)) dx=\(Int(dx)) resized=\(resized) trimmed=\(trimmed) dragged=\(dragged) sel=\(multiSelection.count) inSel=\(multiSelection.contains(block.stepID))"
                    )
                    resizingStepID = nil
                    resizeDelta = 0
                    resizeContext = nil
                    trimmingStepID = nil
                    trimDelta = 0
                    draggingStepID = nil
                    dragTranslation = 0
                    dropTargetGroup = nil
                    dropPastEdge = false
                    insertClickAt = nil
                    dragLaneOverhangX = 0
                    stopAutoScroll()
                    if resized {
                        let seconds = block.duration + Double(dx / pointsPerSecond)
                        model.resizeTimelineStep(block.stepID, duration: seconds)
                        revealStep(block.stepID)
                        return
                    }
                    if trimmed {
                        model.trimTimelineStepStart(
                            block.stepID,
                            deltaSeconds: Double(dx / pointsPerSecond)
                        )
                        return
                    }
                    if dragged, abs(dx) > 3,
                       multiSelection.count > 1, multiSelection.contains(block.stepID) {
                        commitGroupDrag(block, translation: dx, in: timeline)
                        revealStep(block.stepID)
                        return
                    }
                    model.selectAnimationStep(block.stepID)
                    model.timelineFocusColumn = block.group
                    multiSelection = [block.stepID]
                    if dragged, abs(dx) > 3 {
                        commitDrag(block, translation: dx, in: timeline)
                        revealStep(block.stepID)
                    }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {

                model.selectAnimationStep(block.stepID)
                effectPickerID = DialsTarget(id: block.stepID)
            }
        )
        .contextMenu { blockMenu(block, in: timeline) }
        .popover(item: Binding(
            get: { effectPickerID?.id == block.stepID ? effectPickerID : nil },
            set: { effectPickerID = $0 }
        ), arrowEdge: .bottom) { _ in
            ScrollView {
                AnimationGallery(model: model)
                    .padding(12)
            }
            .frame(width: 340, height: 320)
        }

        .help(warning ?? "")

        .position(x: xPos + width / 2, y: blockY + 11)
        .id(block.stepID)
    }

    private func mouseLocal() -> CGPoint? {
        guard let view = lanesAnchor.view, let window = view.window else { return nil }
        let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - screenRect.minX, y: screenRect.maxY - mouse.y)
    }

    private func pressLocal() -> CGPoint? {
        guard let view = lanesAnchor.view, let window = view.window else { return nil }
        let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let press = lanesAnchor.lastPress
        return CGPoint(x: press.x - screenRect.minX, y: screenRect.maxY - press.y)
    }

    private func blockLocal(_ id: String) -> CGRect? {
        guard let frame = blockFrames[id] else { return nil }
        return frame.offsetBy(dx: -lanesFrame.minX, dy: -lanesFrame.minY)
    }

    static func durationLabel(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        return abs(tenths - seconds) < 0.001
            ? String(format: "%.1fs", seconds)
            : String(format: "%.2fs", seconds)
    }

    private var rowPitch: CGFloat { rowHeight + 1 }

    private func marqueeGesture(
        _ entries: [RowEntry], in timeline: AnimationTimelineLayout.Timeline
    ) -> some Gesture {

        let visible = Set(timeline.rows.flatMap(\.blocks).map(\.stepID))
        return DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { _ in
                guard let mouse = mouseLocal() else { return }
                if marqueeStart == nil {

                    guard !marqueeDeclined,
                          draggingStepID == nil, resizingStepID == nil, trimmingStepID == nil
                    else { return }
                    let press = pressLocal() ?? mouse

                    guard press.x >= -4 else { return }

                    let hit = visible.first {
                        blockLocal($0)?.insetBy(dx: -4, dy: -2).contains(press) == true
                    }
                    DiagnosticsStore.shared.note(
                        "timeline.marquee.start",
                        detail: "start=(\(Int(press.x)),\(Int(press.y))) hit=\(hit.map { String($0.suffix(14)) } ?? "nil")"
                    )
                    if hit != nil {
                        marqueeDeclined = true
                        return
                    }
                    marqueeStart = press
                }
                guard let start = marqueeStart else { return }
                marqueeRect = CGRect(
                    x: min(start.x, mouse.x),
                    y: min(start.y, mouse.y),
                    width: abs(mouse.x - start.x),
                    height: abs(mouse.y - start.y)
                )
                armAutoScroll()
            }
            .onEnded { _ in
                defer {
                    marqueeStart = nil
                    marqueeRect = nil
                    marqueeDeclined = false
                    stopAutoScroll()
                }
                guard let rect = marqueeRect, rect.width > 4 || rect.height > 4 else { return }
                let hits = Set(visible.filter { blockLocal($0)?.intersects(rect) == true })
                multiSelection = hits
                DiagnosticsStore.shared.note(
                    "timeline.marquee",
                    detail: "hits=\(hits.count) rect=(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))) \(hits.map { String($0.suffix(14)) }.sorted().joined(separator: ","))"
                )
                if hits.count == 1, let only = hits.first {
                    model.selectAnimationStep(only)
                } else if !hits.isEmpty {

                    model.selectedAnimationStepID = nil
                }
            }
    }

    private enum OverflowDirection { case up, down }

    @ViewBuilder
    private func rowsOverflowHint(_ direction: OverflowDirection, proxy: ScrollViewProxy) -> some View {
        let hiddenPoints = direction == .down
            ? (rowsContentMinY + rowsContentHeight) - (rowsViewportMinY + rowsViewportHeight)
            : rowsViewportMinY - rowsContentMinY
        if hiddenPoints > 4 {
            let hidden = max(Int((hiddenPoints / rowPitch).rounded(.up)), 1)
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("rows.content", anchor: direction == .down ? .bottom : .top)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: direction == .down ? "chevron.down" : "chevron.up")
                        .imageScale(.small)
                    Text("\(hidden) more")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(direction == .down ? .bottom : .top, 3)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: direction == .down
                        ? [.clear, Color.black.opacity(0.25)]
                        : [Color.black.opacity(0.25), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 26)
                .allowsHitTesting(false),
                alignment: direction == .down ? .bottom : .top
            )
            .help(direction == .down ? "Scroll to the last row" : "Scroll to the first row")
        }
    }

    private func armAutoScroll() {
        autoScrollTick()
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 45, repeats: true) { _ in
            autoScrollTick()
        }

        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func autoScrollTick() {
        let gestureLive = draggingStepID != nil || resizingStepID != nil
            || trimmingStepID != nil || marqueeStart != nil
        guard gestureLive,
              let anchor = lanesAnchor.view,
              let window = anchor.window,
              let scrollView = anchor.enclosingScrollView else {
            stopAutoScroll()
            return
        }
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
            return
        }
        guard target.x != visible.origin.x else { return }
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshLiveDeltas()
    }

    private func refreshLiveDeltas() {
        guard let mouse = mouseLocal() else { return }
        if let start = blockPressStart {
            let dx = mouse.x - start.x
            if resizingStepID != nil {
                resizeDelta = dx
            } else if trimmingStepID != nil {
                trimDelta = dx
            } else if draggingStepID != nil {
                dragTranslation = dx
            }
        }
        if let start = marqueeStart {
            marqueeRect = CGRect(
                x: min(start.x, mouse.x),
                y: min(start.y, mouse.y),
                width: abs(mouse.x - start.x),
                height: abs(mouse.y - start.y)
            )
        }
    }

    private func revealStep(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.2)) {
                laneScrollProxy?.scrollTo(id, anchor: UnitPoint(x: 0.85, y: 0.5))
            }
        }
    }

    private func armAddFromCard(_ block: AnimationTimelineLayout.Block, slot: AnimationSequence.GroupSlot) {
        let stepIDs = multiSelection.count > 1 && multiSelection.contains(block.stepID)
            ? multiSelection : [block.stepID]
        let objectIDs = Set(stepIDs.compactMap { model.animationStep(id: $0)?.objectID })
        guard !objectIDs.isEmpty else { return }
        model.selectedAnimationStepID = nil
        model.setSelection(objectIDs)
        model.armStepAdd(into: slot)
        effectPickerID = DialsTarget(id: block.stepID)
    }

    private func newClickBoundary(
        at landedX: CGFloat, in timeline: AnimationTimelineLayout.Timeline
    ) -> (index: Int, x: CGFloat)? {
        var cursor: CGFloat = 0
        var clicksSeen = 0
        for (index, column) in timeline.columns.enumerated() {
            if case .click = column.group { clicksSeen += 1 }
            cursor += columnWidth(column)
            guard index < timeline.columns.count - 1 else { break }
            if abs(landedX - cursor) <= 12 {
                return (clicksSeen, cursor)
            }
        }
        return nil
    }

    private func commitGroupDrag(
        _ block: AnimationTimelineLayout.Block, translation: CGFloat,
        in timeline: AnimationTimelineLayout.Timeline
    ) {
        let columnIndex = timeline.columns.firstIndex { $0.group == block.group } ?? 0
        let originX = columnX(columnIndex, in: timeline) + CGFloat(block.startOffset) * pointsPerSecond
        let landedX = originX + translation
        if let boundary = newClickBoundary(at: landedX, in: timeline) {

            model.moveTimelineSteps(
                multiSelection, into: .newClick(boundary.index),
                grabbed: block.stepID, atOffset: 0
            )
            return
        }
        if landedX >= laneWidth(timeline) {
            model.moveTimelineSteps(
                multiSelection, into: .click(timeline.columns.count),
                grabbed: block.stepID, atOffset: 0
            )
            return
        }
        var cursor: CGFloat = 0
        for column in timeline.columns {
            let width = columnWidth(column)
            if landedX < cursor + width {
                if column.group == block.group {
                    model.moveTimelineSteps(
                        multiSelection, bySeconds: Double(translation / pointsPerSecond)
                    )
                } else {
                    model.moveTimelineSteps(
                        multiSelection, into: slot(for: column.group),
                        grabbed: block.stepID,
                        atOffset: Double(max(landedX - cursor, 0) / pointsPerSecond)
                    )
                }
                return
            }
            cursor += width
        }
    }

    private func commitDrag(
        _ block: AnimationTimelineLayout.Block, translation: CGFloat,
        in timeline: AnimationTimelineLayout.Timeline
    ) {
        let columnIndex = timeline.columns.firstIndex { $0.group == block.group } ?? 0
        let originX = columnX(columnIndex, in: timeline) + CGFloat(block.startOffset) * pointsPerSecond
        let landedX = originX + translation
        if let boundary = newClickBoundary(at: landedX, in: timeline) {

            model.moveTimelineStep(block.stepID, into: .newClick(boundary.index), atOffset: 0)
            return
        }

        if landedX >= laneWidth(timeline) {
            model.moveTimelineStep(
                block.stepID, into: .click(timeline.columns.count), atOffset: 0
            )
            return
        }
        var cursor: CGFloat = 0
        for column in timeline.columns {
            let width = columnWidth(column)
            if landedX < cursor + width {
                let offset = Double(max(landedX - cursor, 0) / pointsPerSecond)
                if column.group == block.group {
                    model.placeTimelineStep(block.stepID, atOffset: offset)
                } else {
                    model.moveTimelineStep(block.stepID, into: slot(for: column.group), atOffset: offset)
                }
                return
            }
            cursor += width
        }
    }

    private func slot(for group: SceneAnimationGroup) -> AnimationSequence.GroupSlot {
        if case .click(Self.draftClickIndex) = group {
            return .newClick(model.timelineDraftClickAt ?? Int.max)
        }
        return concreteSlot(for: group)
    }

    private func concreteSlot(for group: SceneAnimationGroup) -> AnimationSequence.GroupSlot {
        switch group {
        case .auto: .auto
        case .click(let n): .click(n)
        case .exit: .exit
        }
    }

    @ViewBuilder
    private func blockMenu(
        _ block: AnimationTimelineLayout.Block, in timeline: AnimationTimelineLayout.Timeline
    ) -> some View {
        if let warning = model.stepWarnings[block.stepID], let fix = model.stepWarningFix(block.stepID) {
            Text(warning)
            Button(fix.label) { fix.apply() }
            Divider()
        }
        if let (_, step) = model.animationStep(id: block.stepID) {
            Menu("Plays") {
                ForEach(Array(timeline.columns.enumerated()), id: \.offset) { _, column in
                    Button {
                        model.moveTimelineStep(
                            block.stepID, into: slot(for: column.group), atOffset: block.startOffset
                        )
                    } label: {
                        if column.group == block.group {
                            Label(columnTitle(column.group), systemImage: "checkmark")
                        } else {
                            Text(columnTitle(column.group))
                        }
                    }
                }
                Button("New Click") {
                    model.moveTimelineStep(
                        block.stepID, into: .click(timeline.columns.count), atOffset: 0
                    )
                }
            }
            Menu("Speed") {
                ForEach(SlideEditorModel.AnimationSpeed.allCases, id: \.self) { speed in
                    if let seconds = speed.seconds {
                        Button {
                            model.resizeTimelineStep(block.stepID, duration: seconds)
                        } label: {
                            let current = SlideEditorModel.AnimationSpeed.of(step.durationSeconds) == speed
                            if current {
                                Label(speed.rawValue.capitalized + String(format: " · %.1fs", seconds), systemImage: "checkmark")
                            } else {
                                Text(speed.rawValue.capitalized + String(format: " · %.1fs", seconds))
                            }
                        }
                    }
                }
                Text(String(format: "Custom · %.1fs (drag the grip)", step.durationSeconds))
            }
            Menu("Delay") {
                ForEach([0.0, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button {
                        model.updateAnimationStep(block.stepID) {
                            $0.delaySeconds = value == 0 ? nil : value
                        }
                    } label: {
                        let title = value == 0 ? "None" : String(format: "%gs", value)
                        if abs((step.delaySeconds ?? 0) - value) < 0.01 {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
                Text(String(format: "Custom · %.2fs (drag the card)", step.delaySeconds ?? 0))
            }
            Menu("Ramp") {
                ramp(nil, "Default", step)
                ramp(AnimationRamp.none, "Linear", step)
                ramp(.in, "Ease In", step)
                ramp(.out, "Ease Out", step)
                ramp(.both, "Ease In · Out", step)
            }
            if step.animation == .move || step.animation == .wipe {
                Menu(step.kind == .out ? "Leaves To" : "Enters From") {
                    ForEach([AnimationEdge.left, .right, .top, .bottom], id: \.self) { edge in
                        Button {
                            model.updateAnimationStep(block.stepID) { $0.edge = edge }
                        } label: {
                            if step.edge == edge {
                                Label(edge.displayName, systemImage: "checkmark")
                            } else {
                                Text(edge.displayName)
                            }
                        }
                    }
                }
            }
            Menu("With Fade") {
                Button {
                    model.updateAnimationStep(block.stepID) { $0.withFade = true }
                } label: {
                    if step.withFade == true { Label("On", systemImage: "checkmark") } else { Text("On") }
                }
                Button {
                    model.updateAnimationStep(block.stepID) { $0.withFade = nil }
                } label: {
                    if step.withFade != true { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
            }
            Menu("Camera Push") {
                Button {
                    model.updateAnimationStep(block.stepID) { $0.videoPush = nil }
                } label: {
                    if step.videoPush == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                Button {
                    model.updateAnimationStep(block.stepID) {
                        var push = $0.videoPush ?? VideoPush()
                        push.mode = .fill
                        $0.videoPush = push
                    }
                } label: {
                    if step.videoPush != nil, (step.videoPush?.mode ?? .fill) == .fill {
                        Label("Push (crop in)", systemImage: "checkmark")
                    } else { Text("Push (crop in)") }
                }
                Button {
                    model.updateAnimationStep(block.stepID) {
                        var push = $0.videoPush ?? VideoPush()
                        push.mode = .fit
                        $0.videoPush = push
                    }
                } label: {
                    if step.videoPush?.mode == .fit {
                        Label("Push (letterbox)", systemImage: "checkmark")
                    } else { Text("Push (letterbox)") }
                }
                Button {
                    model.updateAnimationStep(block.stepID) {
                        var push = $0.videoPush ?? VideoPush()
                        push.mode = .blurBackground
                        $0.videoPush = push
                    }
                } label: {
                    if step.videoPush?.mode == .blurBackground {
                        Label("Blur Background", systemImage: "checkmark")
                    } else { Text("Blur Background") }
                }
                if let push = step.videoPush, (push.mode ?? .fill) != .blurBackground {
                    Menu("Video Sits") {
                        ForEach([VideoPushAlignment.center, .left, .right, .top, .bottom], id: \.self) { side in
                            Button {
                                model.updateAnimationStep(block.stepID) { $0.videoPush?.alignment = side }
                            } label: {
                                let title = String(describing: side).capitalized
                                if (push.alignment ?? .center) == side {
                                    Label(title, systemImage: "checkmark")
                                } else { Text(title) }
                            }
                        }
                    }
                }
            }
            if step.kind == .in {
                Button {
                    model.setInCustomStart(block.stepID, enabled: step.fromObject == nil)
                } label: {
                    if step.fromObject != nil {
                        Label("Manual Enter Position", systemImage: "checkmark")
                    } else {
                        Text("Set Manual Enter Position…")
                    }
                }
            }
            if block.linked || model.stepEntries.first(where: { $0.step.id == block.stepID })?.step.trigger == .withPrevious {
                Button(block.linked ? "Unlink (a plain delay)" : "Link After Previous") {
                    model.toggleStepLink(block.stepID)
                }
            }
            Divider()
        }
        Button("Change Effect…") {
            model.selectAnimationStep(block.stepID)
            effectPickerID = DialsTarget(id: block.stepID)
        }
        Menu("Add Effect To") {

            ForEach(Array(timeline.columns.enumerated()), id: \.offset) { _, column in
                Button(columnTitle(column.group)) {
                    armAddFromCard(block, slot: slot(for: column.group))
                }
            }
            Button("New Click") {
                armAddFromCard(block, slot: .click(timeline.columns.count))
            }
        }
        Button("Preview from Here") {
            if let start = previewStart(of: block, in: timeline) {
                model.playAnimationPreview(from: max(start - 0.15, 0))
            }
        }
        Divider()
        Button("Duplicate") { model.duplicateAnimationStep(block.stepID) }
        Button("Remove", role: .destructive) { model.removeAnimationStep(block.stepID) }
    }

    @ViewBuilder
    private func ramp(_ value: AnimationRamp?, _ title: String, _ step: AnimationStep) -> some View {
        Button {
            model.updateAnimationStep(step.id) { $0.ramp = value }
        } label: {
            if step.ramp == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func rampWedge(_ tint: Color, leading: Bool) -> some View {
        Triangle(pointsUp: leading)
            .fill(tint.opacity(0.35))
            .frame(width: 8, height: 22)
            .scaleEffect(x: leading ? 1 : -1)
    }

    private func previewStart(
        of block: AnimationTimelineLayout.Block, in timeline: AnimationTimelineLayout.Timeline
    ) -> Double? {
        guard let column = timeline.columns.first(where: { $0.group == block.group }) else { return nil }
        return column.start + block.startOffset
    }

    private func footerRow(_ timeline: AnimationTimelineLayout.Timeline) -> some View {
        HStack(spacing: 8) {

            Button {
                model.timelineRowHeight = max(model.timelineRowHeight - 4, 24)
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(.plain)
            .controlSize(.mini)
            .help("Shorter rows")
            Slider(
                value: Binding(
                    get: { model.timelineRowHeight },
                    set: { model.timelineRowHeight = $0 }
                ),
                in: 24...52
            )
            .controlSize(.mini)
            .frame(width: 70)
            .help("Row height")
            Button {
                model.timelineRowHeight = min(model.timelineRowHeight + 4, 52)
            } label: {
                Image(systemName: "rectangle.expand.vertical")
            }
            .buttonStyle(.plain)
            .controlSize(.mini)
            .help("Taller rows")
            Spacer()
            Button {
                model.timelineZoomAdjusted = true
                model.timelinePointsPerSecond = max(model.timelinePointsPerSecond / 1.3, 24)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            .controlSize(.mini)
            Slider(
                value: Binding(
                    get: { model.timelinePointsPerSecond },
                    set: {
                        model.timelineZoomAdjusted = true
                        model.timelinePointsPerSecond = $0
                    }
                ),
                in: 24...480
            )
            .controlSize(.mini)
            .frame(width: 90)
            Button {
                model.timelineZoomAdjusted = true
                model.timelinePointsPerSecond = min(model.timelinePointsPerSecond * 1.3, 480)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .controlSize(.mini)
            Button("Fit") {

                model.timelineZoomAdjusted = false
                fitZoom(timeline)
            }
            .controlSize(.mini)
            .help("Pack the whole animation into view (and keep fitting as slides change)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
    }

    private func fitZoom(_ timeline: AnimationTimelineLayout.Timeline) {
        let seconds = timeline.columns.reduce(0.0) { $0 + $1.displayDuration }
        guard seconds > 0, laneViewportWidth > 140 else { return }

        model.timelinePointsPerSecond = min(max(Double(laneViewportWidth - 116) / seconds, 24), 480)
    }

    private func autoFitIfNeeded(_ timeline: AnimationTimelineLayout.Timeline) {
        guard !model.timelineZoomAdjusted else { return }
        fitZoom(timeline)
    }
}

private struct PlayheadReadout: View {
    let model: SlideEditorModel
    let duration: Double

    var body: some View {
        Text(String(format: "%.1f / %.1fs", model.animationPreviewShownTime, max(duration, 0.01)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            .frame(width: 84, alignment: .trailing)
    }
}

private struct PlayheadHandle: View {
    let model: SlideEditorModel
    let columns: [AnimationTimelineLayout.Column]
    let x: (Double) -> CGFloat

    var body: some View {
        let t = model.animationPreviewShownTime
        let column = columns.last { $0.start <= t } ?? columns.first
        let within = column.map { max(t - $0.start, 0) } ?? t
        Text(String(format: "%.2fs", within))
            .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)

            .frame(width: 34)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
            .offset(x: x(t) - 17, y: 2)
    }
}

private struct PlayheadLine: View {
    let model: SlideEditorModel
    let x: (Double) -> CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .offset(x: x(model.animationPreviewShownTime))
            .allowsHitTesting(false)
    }
}

private struct Triangle: Shape {
    var pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

final class AnchorBox {
    weak var view: NSView?
    var lastPress: NSPoint = .zero
}

private struct ScreenAnchorView: NSViewRepresentable {
    let box: AnchorBox

    final class Coordinator {
        var monitor: Any?
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        let box = box
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { event in
            box.lastPress = NSEvent.mouseLocation
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

private struct ObjectDropDelegate: DropDelegate {
    let columnAt: (CGFloat) -> Int?
    let open: (String, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first,
              let columnIndex = columnAt(info.location.x) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  text.hasPrefix(AnimationTimelinePanel.objectDragPrefix) else { return }
            let objectID = String(text.dropFirst(AnimationTimelinePanel.objectDragPrefix.count))
            DispatchQueue.main.async { open(objectID, columnIndex) }
        }
        return true
    }
}
