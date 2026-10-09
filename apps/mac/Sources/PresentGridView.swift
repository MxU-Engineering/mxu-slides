import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct PresentGridView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let presentationID: String
    let arrangementId: String?

    var contextID: String? = nil

    var serviceID: String? = nil
    var serviceItem: ServiceItem? = nil

    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @AppStorage("slideGrid.legibleText") private var legibleText = false
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback
    @FocusState private var focused: Bool

    @State private var deleteRequests = 0

    @State private var clipboardRequests = SlideClipboardRequests()

    @State private var previewArrangementID: String?

    private var fireContext: String { contextID ?? presentationID }

    private var effectiveArrangementID: String? {
        serviceItem != nil ? arrangementId : previewArrangementID
    }

    private var stripSelection: Binding<String?> {
        Binding(
            get: { effectiveArrangementID },
            set: { newValue in
                if let serviceID, let serviceItem {
                    model.setServiceItemArrangement(
                        serviceID, itemID: serviceItem.id, arrangementID: newValue
                    )
                } else {
                    previewArrangementID = newValue
                }
            }
        )
    }

    var body: some View {
        let _ = model.listVersion

        if let presentation = model.presentation(presentationID) {
            let theme = model.theme(presentation.themeId)

            let slides = model.arrangedSlides(presentation, arrangementId: effectiveArrangementID)
            ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header(presentation)
                if presentation.sections?.isEmpty == false {
                    ArrangementStrip(
                        model: model, presentation: presentation,
                        selection: stripSelection,
                        onJump: { pill in
                            let starts = SlideSceneBuilder.arrangementBlockStarts(
                                for: presentation, arrangementId: effectiveArrangementID
                            )
                            guard starts.indices.contains(pill),
                                  starts[pill] < slides.count else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(
                                    SlideGridBody.tileAnchor(
                                        contextID: fireContext, index: starts[pill]
                                    ),
                                    anchor: .top
                                )
                            }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                Divider()
                ScrollView {
                    SlideGridBody(
                        model: model, render: render, controls: controls,
                        presentation: presentation, theme: theme,
                        slides: slides, arrangementId: effectiveArrangementID,
                        contextID: fireContext,
                        roundedCorners: roundedCorners,
                        hideScopedBackgrounds: hideScopedBackgrounds,
                        legibleText: legibleText,
                        slidesAcross: slidesAcross,
                        deleteRequests: deleteRequests,
                        clipboardRequests: clipboardRequests,
                        pastesAtEnd: true,
                        marqueeMargin: 12
                    )
                    .padding(12)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()

                .onPresentFireKeys {
                    fireStep($0, slides, presentation)
                    controls?.noteKeyboardFire()
                }

                .background(KeyboardFireFollow(controls: controls) { revealLive(proxy) })

                .onDeleteCommand { deleteRequests += 1 }

                .onSlideClipboardKeys(active: focused) { clipboardRequests.take($0) }
            }
            }
            .onAppear { focused = true }
        } else if model.presentationExists(presentationID) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Presentation not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func header(_ presentation: Presentation) -> some View {
        HStack {
            Text(presentation.name)
                .font(.headline)
            if let arrangementId = effectiveArrangementID,
               let name = presentation.arrangements?.first(where: { $0.id == arrangementId })?.name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            SongKeyChip(model: model, controls: controls, presentation: presentation)
            SlideShowChip(model: model, controls: controls, presentation: presentation)
            Spacer()

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }


    private func revealLive(_ proxy: ScrollViewProxy) {
        if let controls, controls.liveContextID == fireContext, let occurrence = controls.liveOccurrence {
            proxy.scrollTo(SlideGridBody.tileAnchor(contextID: fireContext, index: occurrence), anchor: .center)
        }
    }

    private func fireStep(_ delta: Int, _ slides: [Slide], _ presentation: Presentation) {
        guard let controls, !slides.isEmpty else { return }

        let settled = delta > 0 && NSEvent.modifierFlags.contains(.option)
        controls.advance(steps: delta, settled: settled) {
            let current = controls.liveContextID == fireContext ? (controls.liveOccurrence ?? -1) : -1
            let next = current < 0 ? (delta > 0 ? 0 : slides.count - 1) : current + delta
            guard slides.indices.contains(next) else { return }
            controls.fire(
                slide: slides[next], in: presentation, arrangementId: effectiveArrangementID,
                contextID: fireContext, occurrence: next
            )
        }
    }
}

@MainActor
enum SlideGridMetrics {
    static let spacing: CGFloat = 12

    static var lastWidths: [String: CGFloat] = [:]

    static var continuousWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: continuousWidthKey)) }
        set {
            if abs(newValue - continuousWidth) >= 1 {
                UserDefaults.standard.set(Double(newValue), forKey: continuousWidthKey)
            }
        }
    }
    static let continuousWidthKey = "slideGrid.continuousWidth"

    static let labelHeight: CGFloat = 14

    static let labelGap: CGFloat = 4

    static func tileAspect(for presentation: Presentation) -> CGFloat {
        SlidesAcross.tileAspect(canvas: SlideSceneBuilder.canvasSize(for: presentation))
    }

    static func columns(across count: Int, cellWidth: CGFloat? = nil) -> [GridItem] {
        Array(
            repeating: cellWidth.map { GridItem(.fixed($0), spacing: spacing) }
                ?? GridItem(.flexible(), spacing: spacing),
            count: SlidesAcross.clamped(count)
        )
    }

    static func cell(width: CGFloat, across: Int, aspect: CGFloat) -> CGSize? {
        SlidesAcross.cell(
            width: width, across: across, spacing: spacing,
            aspect: aspect, labelGap: labelGap, labelHeight: labelHeight)
    }
}

@MainActor
enum SlidePasteboard {
    static let type = NSPasteboard.PasteboardType(EditorPaste.slideType)

    static let slidesType = NSPasteboard.PasteboardType(EditorPaste.slidesType)

    static func copy(_ slide: Slide) {
        copy([slide])
    }

    static func copy(_ slides: [Slide]) {
        if let first = slides.first, let data = try? JSONEncoder().encode(first),
           let all = try? JSONEncoder().encode(slides) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: type)
            NSPasteboard.general.setData(all, forType: slidesType)
            SlidePasteboardChanges.shared.count += 1
        }
    }

    static func pasteAll() -> [Slide] {
        if let data = NSPasteboard.general.data(forType: slidesType),
           let slides = try? JSONDecoder().decode([Slide].self, from: data) {
            return slides.map { $0.freshIDCopy() }
        } else {
            return paste().map { [$0] } ?? []
        }
    }

    static var hasSlide: Bool {
        NSPasteboard.general.data(forType: type) != nil
    }

    static func paste() -> Slide? {
        guard let data = NSPasteboard.general.data(forType: type),
              let slide = try? JSONDecoder().decode(Slide.self, from: data)
        else { return nil }
        return slide.freshIDCopy()
    }
}

@MainActor
@Observable
final class SlidePasteboardChanges {
    static let shared = SlidePasteboardChanges()
    var count = 0
}

struct SlideClipboardRequests: Equatable {
    enum Verb { case copy, cut, paste, selectAll }

    var copies = 0
    var cuts = 0
    var pastes = 0
    var selectAlls = 0

    mutating func take(_ verb: Verb) {
        switch verb {
        case .copy: copies += 1
        case .cut: cuts += 1
        case .paste: pastes += 1
        case .selectAll: selectAlls += 1
        }
    }
}

struct KeyboardFireFollow: View {
    let controls: ServiceControls?
    let reveal: () -> Void

    var body: some View {
        Color.clear.onChange(of: controls?.keyboardFires) { _, _ in reveal() }
    }
}

extension View {

    func onPresentFireKeys(_ step: @escaping (Int) -> Void) -> some View {
        let fire: (Int) -> KeyPress.Result = { direction in
            if NSApp.keyWindow?.firstResponder is NSText {
                return .ignored
            } else {
                step(direction)
                return .handled
            }
        }
        return onKeyPress(.leftArrow) { fire(-1) }
            .onKeyPress(.rightArrow) { fire(1) }
            .onKeyPress(.return) { fire(1) }
            .onKeyPress(.space) { fire(1) }
    }

    func onSlideClipboardKeys(
        active: Bool, perform action: @escaping (SlideClipboardRequests.Verb) -> Void
    ) -> some View {
        background(SlideClipboardKeyMonitor(active: active, action: action))
    }
}

private struct SlideClipboardKeyMonitor: NSViewRepresentable {
    let active: Bool
    let action: (SlideClipboardRequests.Verb) -> Void

    final class Coordinator {
        var monitor: Any?
        var action: (SlideClipboardRequests.Verb) -> Void = { _ in }
        weak var view: NSView?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let self, let verb = verb(for: event) {
                    action(verb)
                    return nil
                } else {
                    return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func verb(for event: NSEvent) -> SlideClipboardRequests.Verb? {
            let typing = event.window?.firstResponder is NSText
            if let window = view?.window, event.window === window, window.isKeyWindow,
               window.attachedSheet == nil, !typing,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": return .copy
                case "x": return .cut
                case "v": return .paste
                case "a": return .selectAll
                default: return nil
                }
            } else {
                return nil
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    private func sync(_ coordinator: Coordinator) {
        coordinator.action = action
        if active { coordinator.install() } else { coordinator.remove() }
    }
}

struct SlideGridBody: View {

    static func tileAnchor(contextID: String, index: Int) -> String {
        "slideTile|\(contextID)|\(index)"
    }

    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let presentation: Presentation
    let theme: Theme?
    let slides: [Slide]
    let arrangementId: String?
    let contextID: String
    let roundedCorners: Bool
    let hideScopedBackgrounds: Bool
    let legibleText: Bool

    let slidesAcross: Int

    var deleteRequests = 0

    var clipboardRequests = SlideClipboardRequests()

    var pastesAtEnd = false

    var newSlideContexts: [String] = []

    var buildsRowsNearView = false

    var marqueeMargin: CGFloat = 0

    @State private var gridWidth: CGFloat = 0

    @State private var builtRows: Set<Int> = []

    private var cell: CGSize? {
        SlideGridMetrics.cell(
            width: measuredWidth, across: slidesAcross, aspect: SlideGridMetrics.tileAspect(for: presentation))
    }

    private func tileRows(aspect: CGFloat, cell: CGSize?) -> some View {
        let across = SlidesAcross.clamped(slidesAcross)
        return VStack(alignment: .leading, spacing: SlideGridMetrics.spacing) {
            ForEach(SlidesAcross.rows(count: slides.count, across: across), id: \.indices.lowerBound) { row in
                let built = cell != nil && builtRows.contains(row.indices.lowerBound / across)
                HStack(alignment: .top, spacing: SlideGridMetrics.spacing) {
                    ForEach(row.indices, id: \.self) { index in
                        if built, let cell {
                            gridTile(index: index, slide: slides[index], aspect: aspect)
                                .frame(width: cell.width, height: cell.height, alignment: .top)
                        } else {
                            placeholderCell(cell: cell, aspect: aspect)
                                .id(Self.tileAnchor(contextID: contextID, index: index))
                        }
                    }

                    if cell == nil {
                        ForEach(0 ..< row.fillers, id: \.self) { _ in
                            placeholderCell(cell: nil, aspect: aspect)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func placeholderCell(cell: CGSize?, aspect: CGFloat) -> some View {
        if let cell {
            Color.clear.frame(width: cell.width, height: cell.height)
        } else {
            VStack(spacing: SlideGridMetrics.labelGap) {
                Color.clear.aspectRatio(aspect, contentMode: .fit)
                Color.clear.frame(height: SlideGridMetrics.labelHeight)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var measuredWidth: CGFloat {
        gridWidth > 0
            ? gridWidth
            : (SlideGridMetrics.lastWidths[contextID] ?? (buildsRowsNearView ? SlideGridMetrics.continuousWidth : 0))
    }

    private func nearRows(top: CGFloat) -> Range<Int> {
        if buildsRowsNearView, let cell {
            let across = SlidesAcross.clamped(slidesAcross)
            let viewport = PresentCardFrames.shared.scrollView?.contentView.bounds.height ?? 900
            return SlidesAcross.nearRows(
                gridTop: top, rowPitch: cell.height + SlideGridMetrics.spacing,
                rowCount: (slides.count + across - 1) / across, viewport: viewport, margin: viewport)
        } else {
            return 0 ..< 0
        }
    }

    private func buildRows(_ rows: Range<Int>) {
        if !rows.isEmpty, !builtRows.isSuperset(of: rows) {
            builtRows.formUnion(rows)
        }
    }

    private func measured(_ width: CGFloat) {
        if gridWidth != width { gridWidth = width }
        if SlideGridMetrics.lastWidths[contextID] != width { SlideGridMetrics.lastWidths[contextID] = width }
        if buildsRowsNearView { SlideGridMetrics.continuousWidth = width }
    }

    private struct PendingSectionEdit {
        let sectionNames: [String]
        let apply: () -> Void
    }

    @Environment(\.runOnly) private var runOnly

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    @State private var pendingEdit: PendingSectionEdit?

    @State private var dropTargetIndex: Int?

    @State private var dropTargetAfterIndex: Int?
    @State private var renamingSlide: Slide?
    @State private var renameText = ""

    @State private var quickEditSlide: Slide?

    @State private var backgroundDropIndex: Int?

    @State private var mediaActionTarget: MediaActionTarget?

    @State private var actionEditorSlide: Slide?

    @State private var actionPlacement: ActionPlacement?

    @State private var autoAdvanceTarget: AutoAdvanceTarget?

    @State private var dropSettleUntil = Date.distantPast

    @State private var selectedOccurrences: Set<Int> = []

    @State private var selectionAnchor: Int?

    @State private var tileFrames: [Int: CGRect] = [:]

    @State private var marqueeRect: CGRect?
    @Environment(\.actionRouter) private var actionRouter

    private struct MediaActionTarget: Identifiable {
        let pairs: [(slideID: String, actionID: String)]

        var kind: DocumentKind = .media
        var id: String { pairs.map(\.actionID).joined(separator: "|") }
    }

    private struct AutoAdvanceTarget: Identifiable {
        let slideIDs: [String]
        let name: String
        var id: String { slideIDs.joined(separator: "|") }
    }

    private struct ActionPlacement: Identifiable {
        let slideIDs: [String]
        let draft: SlideAction
        var id: String { draft.id }
    }

    @State private var slideShowPresented = false

    @State private var newSlideTarget: NewSlideTarget?

    @State private var applyThemeTarget: ApplyThemeTarget?

    @State private var mediaMenuState = MediaCueMenuState()

    private func presentationAutoAdvanceBinding() -> Binding<AutoAdvance?> {
        Binding(
            get: { model.presentation(presentation.id)?.autoAdvance },
            set: { advance in
                model.updatePresentationField(
                    presentation.id, \.autoAdvance, key: "autoAdvance", to: advance, undoLabel: "Slide Show")
                controls?.presentationEdited(presentation.id)
            }
        )
    }

    private var effectiveArrangement: Arrangement? {
        guard let arrangementId, !arrangementId.isEmpty else { return nil }
        return presentation.arrangements?.first { $0.id == arrangementId }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {

            Color.clear
                .contentShape(Rectangle())
                .padding(-marqueeMargin)
                .onTapGesture {
                    clearSelection()
                    NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID)
                }
                .gesture(marqueeGesture)

                .onDrop(of: [.plainText, .fileURL], delegate: appendDropDelegate(enabled: !runOnly))
            let aspect = SlideGridMetrics.tileAspect(for: presentation)
            let cell = self.cell
            if buildsRowsNearView {
                tileRows(aspect: aspect, cell: cell)
            } else {
                LazyVGrid(columns: SlideGridMetrics.columns(across: slidesAcross, cellWidth: cell?.width), alignment: .leading, spacing: SlideGridMetrics.spacing) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        gridTile(index: index, slide: slide, aspect: aspect)
                            .frame(width: cell?.width, height: cell?.height, alignment: .top)
                    }
                }
            }
            if let rect = marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "slideGrid")

        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .background {
            GeometryReader { proxy in

                let top = proxy.frame(in: .named(ServiceContinuousView.scrollSpace)).minY
                let _ = cell.map { cell in
                    PresentCardFrames.shared.noteGrid(PresentLanding.Grid(
                        id: contextID, top: top,
                        rowPitch: cell.height + SlideGridMetrics.spacing,
                        across: SlidesAcross.clamped(slidesAcross), count: slides.count))
                    PresentCardFrames.shared.noteDocGrid(PresentLanding.Grid(
                        id: contextID, top: proxy.frame(in: .named(ServiceContinuousView.contentSpace)).minY,
                        rowPitch: cell.height + SlideGridMetrics.spacing,
                        across: SlidesAcross.clamped(slidesAcross), count: slides.count))
                }
                let near = nearRows(top: top)
                Color.clear
                    .onAppear { buildRows(near) }
                    .onChange(of: near) { _, rows in buildRows(rows) }
                    .onAppear { measured(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in measured(width) }

                    .onChange(of: proxy.size.height) { old, height in
                        if abs(height - old) > 300 {
                            DiagnosticsStore.shared.note(
                                "present.grid",
                                detail: "\(contextID) \(Int(old)) → \(Int(height)) pt, \(slides.count) slides, width \(Int(measuredWidth))")
                        }
                    }
            }
        }

        .onChange(of: slides.count) { _, _ in
            clearSelection()
            DropLatency.relaid(count: slides.count)
        }
        .onChange(of: arrangementId) { _, _ in clearSelection() }
        .onChange(of: deleteRequests) { _, _ in deleteSelectedSlides() }
        .onChange(of: clipboardRequests.copies) { _, _ in copySelectedSlides() }
        .onChange(of: clipboardRequests.cuts) { _, _ in
            if copySelectedSlides() { deleteSelectedSlides() }
        }
        .onChange(of: clipboardRequests.pastes) { _, _ in pasteFromKeyboard() }
        .onChange(of: clipboardRequests.selectAlls) { _, _ in selectAllFromKeyboard() }
        .onChange(of: NewSlideRouter.shared.requests) { _, _ in newSlideFromMenu() }
        .sheet(item: $newSlideTarget) { target in
            NewSlideSheet(appModel: model, render: render, deckThemeId: presentation.themeId) { choice in
                insertNewSlide(choice, after: target.after)
            }
        }
        .sheet(item: $applyThemeTarget) { target in
            ApplyThemeSheet(
                appModel: model, render: render, deckThemeId: presentation.themeId,
                scope: applyThemeScope(target.slideIDs ?? [])
            ) { themeId, design in
                let slideIDs = target.slideIDs ?? []

                if Set(slideIDs).isSuperset(of: presentation.slides.map(\.id)) {
                    model.applyTheme(to: presentation.id, themeID: themeId, design: design)
                } else {
                    model.applyTheme(to: presentation.id, slideIDs: slideIDs, themeID: themeId, design: design)
                }
            }
        }
        .sheet(item: $quickEditSlide) { target in
            QuickEditView(
                slide: {
                    model.presentation(presentation.id)?.slides
                        .first { $0.id == target.id }
                },
                write: { objectID, text in
                    model.quickEditText(
                        presentationID: presentation.id, slideID: target.id,
                        objectID: objectID, text: text)
                }
            )
        }
        .sheet(item: $mediaActionTarget) { target in
            LibraryPickerSheet(appModel: model, kind: target.kind) { entry in
                model.updateSlides(presentationID: presentation.id, undoLabel: "Choose Media") { presentation in
                    for pair in target.pairs {
                        guard let slideIndex = presentation.slides.firstIndex(
                            where: { $0.id == pair.slideID }),
                            var actions = presentation.slides[slideIndex].actions,
                            let actionIndex = actions.firstIndex(
                                where: { $0.id == pair.actionID })
                        else { continue }
                        if target.kind == .audio {
                            actions[actionIndex].audioItemId = entry.id
                        } else {
                            actions[actionIndex].mediaId = entry.id
                        }
                        presentation.slides[slideIndex].actions = actions
                    }
                }
                mediaActionTarget = nil
            }
        }
        .sheet(item: $actionEditorSlide) { target in
            SlideActionsSheet(
                model: model, slideName: target.name,
                actions: slideActionsBinding(target.id)
            )
        }
        .sheet(item: $actionPlacement) { placement in
            ActionPlacementSheet(model: model, draft: placement.draft) { action in
                addAction(action, to: placement.slideIDs)
            }
        }
        .sheet(item: $autoAdvanceTarget) { target in
            AutoAdvanceSheet(
                slideName: target.name,
                advance: autoAdvanceBinding(target.slideIDs)
            )
        }
        .sheet(isPresented: $slideShowPresented) {
            AutoAdvanceSheet(
                slideName: presentation.name,
                advance: presentationAutoAdvanceBinding(),
                presentationScope: true
            )
        }
        .mediaCueSheets(model: model, state: mediaMenuState)
        .alert(
            "Edit a Repeated Section?",
            isPresented: Binding(
                get: { pendingEdit != nil }, set: { if !$0 { pendingEdit = nil } }
            ),
            presenting: pendingEdit
        ) { edit in
            Button("Apply") {
                edit.apply()
                pendingEdit = nil
            }
            Button("Cancel", role: .cancel) { pendingEdit = nil }
        } message: { edit in
            Text(
                "This will affect every "
                    + edit.sectionNames.map { "“\($0)”" }.joined(separator: " and ")
                    + " instance in the arrangement."
            )
        }
        .alert(
            "Rename Slide",
            isPresented: Binding(
                get: { renamingSlide != nil }, set: { if !$0 { renamingSlide = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let slide = renamingSlide {
                    model.renameSlide(presentation.id, slideID: slide.id, to: renameText)
                }
                renamingSlide = nil
            }
            Button("Cancel", role: .cancel) { renamingSlide = nil }
        } message: {
            Text("Leave empty for no name — slides don't need one.")
        }
    }

    private func clearSelection() {
        selectedOccurrences.removeAll()
        selectionAnchor = nil
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("slideGrid"))
            .onChanged { value in
                guard !runOnly else { return }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marqueeRect = rect
                NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID)
                selectedOccurrences = Set(
                    tileFrames.filter { $0.value.intersects(rect) }.map(\.key))
            }
            .onEnded { _ in marqueeRect = nil }
    }

    private func handleTap(index: Int, slide: Slide) {
        let modifiers = NSEvent.modifierFlags

        NewSlideRouter.shared.route = NewSlideRoute(contextID: contextID, occurrence: index)
        if !runOnly, modifiers.contains(.command) {
            if selectedOccurrences.contains(index) {
                selectedOccurrences.remove(index)
            } else {
                selectedOccurrences.insert(index)
            }
            selectionAnchor = index
        } else if !runOnly, modifiers.contains(.shift) {
            let anchor = selectionAnchor ?? index
            selectedOccurrences.formUnion(min(anchor, index)...max(anchor, index))
        } else {
            clearSelection()

            let isLiveTile = controls?.liveContextID == contextID && controls?.liveOccurrence == index
            if isLiveTile, let controls, controls.slideAnimationStep.map({ $0.consumed < $0.total }) == true {
                controls.advance(steps: 1) {}
            } else {
                controls?.fire(
                    slide: slide, in: presentation, arrangementId: arrangementId,
                    contextID: contextID, occurrence: index
                )
            }
        }
    }

    private func menuTargetIDs(clicked index: Int, slide: Slide) -> [String] {
        guard selectedOccurrences.contains(index) else { return [slide.id] }
        return SlideBulkEdit.slideIDs(occurrences: selectedOccurrences, slides: slides)
    }

    @ViewBuilder
    private func tileMenu(index: Int, slide: Slide) -> some View {
        if !runOnly {
            let targetIDs = menuTargetIDs(clicked: index, slide: slide)
            if targetIDs.count > 1 {
                bulkMenu(slideIDs: targetIDs)
            } else {
                singleMenu(slide: slide)
            }
        }
    }

    @ViewBuilder
    private func bulkMenu(slideIDs: [String]) -> some View {
        Text("\(slideIDs.count) Slides")
        Menu("Add Action") {
            AddActionMenuItems(
                model: model,
                timers: actionRouter?.timerChoices ?? []
            ) { action in

                actionPlacement = ActionPlacement(slideIDs: slideIDs, draft: action)
            }
        }
        let kinds = SlideBulkEdit.actionKinds(on: slideIDs, in: presentation.slides)
        if !kinds.isEmpty {
            Menu("Remove Action") {
                ForEach(kinds, id: \.rawValue) { kind in
                    Button(kind.displayName, role: .destructive) {
                        model.updateSlides(presentationID: presentation.id, undoLabel: "Remove Action") {
                            SlideBulkEdit.removeActions(
                                ofKind: kind, from: slideIDs, in: &$0)
                        }
                    }
                }
                Divider()
                Button("All Actions", role: .destructive) {
                    model.updateSlides(presentationID: presentation.id, undoLabel: "Remove Actions") {
                        SlideBulkEdit.removeActions(
                            ofKind: nil, from: slideIDs, in: &$0)
                    }
                }
            }
        }
        Button(anyHasAutoAdvance(slideIDs) ? "Auto Advance… ✓" : "Auto Advance…") {
            autoAdvanceTarget = AutoAdvanceTarget(
                slideIDs: slideIDs, name: "\(slideIDs.count) Slides")
        }
        Button(presentation.autoAdvance == nil ? "Slide Show…" : "Slide Show… ✓") {
            slideShowPresented = true
        }
        Button("Apply Theme…") {
            applyThemeTarget = ApplyThemeTarget(presentationID: presentation.id, slideIDs: slideIDs)
        }
        Divider()
        Button("Duplicate \(slideIDs.count) Slides") {
            confirmingRepeatedSectionEdit(sections: sectionIDs(of: slideIDs)) {

                var copied = presentation.slides
                SlideBulkEdit.duplicateSlides(slideIDs, in: &copied)
                if let insertion = ListInsertion(before: presentation.slides, after: copied, id: { $0.id }) {
                    model.updatePresentation(presentation.id, value: { insertion.restore(into: &$0.slides) }, op: { document in
                        try document.updateSlideList { insertion.restore(into: &$0) }
                    })
                }
                clearSelection()
            }
        }
        Button("Copy \(slideIDs.count) Slides") { copySlides(slideIDs) }
        Button("Delete \(slideIDs.count) Slides", role: .destructive) {
            deleteSlides(slideIDs)
        }
        .disabled(slideIDs.count >= presentation.slides.count)
    }

    private func copySlides(_ slideIDs: [String]) {
        SlidePasteboard.copy(presentation.slides.filter { slideIDs.contains($0.id) })
    }

    @discardableResult
    private func copySelectedSlides() -> Bool {
        let slideIDs = SlideBulkEdit.slideIDs(occurrences: selectedOccurrences, slides: slides)
        if !runOnly, !slideIDs.isEmpty {
            copySlides(slideIDs)
            return true
        } else {
            return false
        }
    }

    private func pasteFromKeyboard() {
        let liveIndex = controls?.liveContextID == contextID ? controls?.liveOccurrence : nil
        let anchorIndex = selectedOccurrences.max() ?? liveIndex
        if !runOnly, let anchorIndex, slides.indices.contains(anchorIndex) {
            pasteSlides(after: slides[anchorIndex])
        } else if !runOnly, pastesAtEnd {
            pasteSlides(after: presentation.slides.last)
        }
    }

    private func selectAllFromKeyboard() {
        let contexts = newSlideContexts.isEmpty ? [contextID] : newSlideContexts
        if !runOnly, NewSlideRouter.shared.route.answers(contextID, contexts: contexts, isHostTarget: pastesAtEnd) {
            selectedOccurrences = Set(slides.indices)
            selectionAnchor = nil
        } else if !runOnly {
            clearSelection()
        }
    }

    private func pasteSlides(after anchor: Slide?) {
        let pasted = SlidePasteboard.pasteAll()
        if !pasted.isEmpty {
            confirmingRepeatedSectionEdit(sections: [anchor?.sectionId]) {
                model.insertSlides(presentation.id, slides: pasted, afterSlideID: anchor?.id)
            }
        }
    }

    private func newSlideFromMenu() {
        let route = NewSlideRouter.shared.route
        let contexts = newSlideContexts.isEmpty ? [contextID] : newSlideContexts
        if !runOnly, route.answers(contextID, contexts: contexts, isHostTarget: pastesAtEnd) {
            let anchor = route.anchor(in: contextID, selected: selectedOccurrences, count: slides.count)
            newSlideTarget = NewSlideTarget(after: anchor.map { slides[$0] } ?? presentation.slides.last)
        }
    }

    private func insertNewSlide(_ choice: NewSlideChoice, after anchor: Slide?) {
        let slide = choice.slide(sectionId: anchor?.sectionId, deckThemeId: presentation.themeId)
        confirmingRepeatedSectionEdit(sections: [anchor?.sectionId]) {
            model.insertSlide(presentation.id, slide: slide, afterSlideID: anchor?.id)
        }
    }

    private func deleteSelectedSlides() {
        guard !runOnly, !selectedOccurrences.isEmpty else { return }
        let slideIDs = SlideBulkEdit.slideIDs(occurrences: selectedOccurrences, slides: slides)
        guard !slideIDs.isEmpty, slideIDs.count < presentation.slides.count else { return }
        deleteSlides(slideIDs)
    }

    private func deleteSlides(_ slideIDs: [String]) {
        confirmingRepeatedSectionEdit(sections: sectionIDs(of: slideIDs)) {

            model.updatePresentation(presentation.id, value: { SlideBulkEdit.deleteSlides(slideIDs, in: &$0.slides) }, op: { document in
                try document.updateSlideList { SlideBulkEdit.deleteSlides(slideIDs, in: &$0) }
            })
            clearSelection()
        }
    }

    private func anyHasAutoAdvance(_ slideIDs: [String]) -> Bool {
        presentation.slides.contains { slideIDs.contains($0.id) && $0.autoAdvance != nil }
    }

    private func cueMediaIDs(of slide: Slide) -> [String] {
        var ids: [String] = []
        if let id = slide.background?.mediaId, !id.isEmpty, !id.contains("::") {
            ids.append(id)
        }
        for action in slide.actions ?? [] where action.kind == .fireMedia {
            guard let id = action.mediaId, !id.isEmpty, !id.contains("::"),
                  !ids.contains(id) else { continue }
            ids.append(id)
        }
        return ids
    }

    private func sectionIDs(of slideIDs: [String]) -> [String?] {
        presentation.slides.filter { slideIDs.contains($0.id) }.map(\.sectionId)
    }

    private func addAction(_ action: SlideAction, to slideIDs: [String]) {

        let ids = Dictionary(Set(slideIDs).map { ($0, UUID().uuidString) }, uniquingKeysWith: { first, _ in first })
        var preview = presentation
        let pairs = SlideBulkEdit.addAction(action, to: slideIDs, in: &preview, actionIDs: ids)
        model.updateSlides(presentationID: presentation.id, undoLabel: "Add Action") {
            SlideBulkEdit.addAction(action, to: slideIDs, in: &$0, actionIDs: ids)
        }
        if action.kind == .fireMedia, action.mediaId == nil, !pairs.isEmpty {
            mediaActionTarget = MediaActionTarget(pairs: pairs)
        }
        if action.kind == .fireAudio, action.audioItemId == nil, !pairs.isEmpty {
            mediaActionTarget = MediaActionTarget(pairs: pairs, kind: .audio)
        }
    }

    private func missingMedia(of slide: Slide) -> [String] {
        MediaReferences.ids(in: slide).sorted().filter(model.isMediaMissing(mediaID:))
    }

    @ViewBuilder
    private func singleMenu(slide: Slide) -> some View {

        Button("Edit…") {
            model.openInEditor(
                entryID: presentation.id, slideID: slide.id
            )
            appModeRaw = AppMode.edit.rawValue
        }
        Button("Quick Edit…") { quickEditSlide = slide }
        Button("Rename Slide…") {
            renameText = slide.name
            renamingSlide = slide
        }

        ForEach(cueMediaIDs(of: slide), id: \.self) { mediaID in
            Menu(model.media(mediaID)?.name ?? "Media") {

                MediaCueMenuItems(
                    model: model, actionRouter: actionRouter,
                    mediaID: mediaID, state: mediaMenuState,
                    includesCueGrammar: false
                )
            }
        }

        Menu("Add Action") {
            AddActionMenuItems(
                model: model,
                timers: actionRouter?.timerChoices ?? []
            ) { action in
                actionPlacement = ActionPlacement(slideIDs: [slide.id], draft: action)
            }
        }

        let slideActions = slide.actions ?? []
        if !slideActions.isEmpty {

            let timers = actionRouter?.timerChoices ?? []
            Menu("Edit Action") {
                ForEach(slideActions) { action in
                    Button(slideActionLabel(
                        action, model: model, timers: timers,
                        confidenceScreens: actionRouter?.confidenceScreenChoices ?? [])) {
                        actionEditorSlide = slide
                    }
                }
            }
            Menu("Remove Action") {
                ForEach(slideActions) { action in
                    Button(slideActionLabel(
                        action, model: model, timers: timers,
                        confidenceScreens: actionRouter?.confidenceScreenChoices ?? []), role: .destructive) {
                        removeSlideAction(action.id, from: slide)
                    }
                }
            }
        }

        Button(slide.autoAdvance == nil
            ? "Auto Advance…" : "Auto Advance… ✓"
        ) {
            autoAdvanceTarget = AutoAdvanceTarget(slideIDs: [slide.id], name: slide.name)
        }
        Button(presentation.autoAdvance == nil ? "Slide Show…" : "Slide Show… ✓") {
            slideShowPresented = true
        }
        Button("Apply Theme…") {
            applyThemeTarget = ApplyThemeTarget(presentationID: presentation.id, slideIDs: [slide.id])
        }
        Divider()
        Button("New Slide After…") { newSlideTarget = NewSlideTarget(after: slide) }
        Button("Duplicate Slide") {
            confirmingRepeatedSectionEdit(sections: [slide.sectionId]) {
                model.insertSlide(
                    presentation.id, slide: slide.freshIDCopy(),
                    afterSlideID: slide.id
                )
            }
        }
        Button("Copy Slide") { SlidePasteboard.copy(slide) }

        let _ = SlidePasteboardChanges.shared.count
        Button("Paste Slide After") { pasteSlides(after: slide) }
            .disabled(!SlidePasteboard.hasSlide)

        Button("Delete Slide", role: .destructive) {
            deleteSlides([slide.id])
        }
        .disabled(presentation.slides.count == 1)
    }

    private func applyThemeScope(_ slideIDs: [String]) -> String {
        if Set(slideIDs).isSuperset(of: presentation.slides.map(\.id)) {
            "Applies to every slide in \u{201C}\(presentation.name)\u{201D}."
        } else if slideIDs.count == 1 {
            "Applies to this slide."
        } else {
            "Applies to the \(slideIDs.count) selected slides."
        }
    }

    private func gridTile(index: Int, slide: Slide, aspect: CGFloat) -> some View {
        tile(index: index, slide: slide, aspect: aspect)

            .newSlideEdgeButton(enabled: !runOnly && index == slides.count - 1) {
                newSlideTarget = NewSlideTarget(after: slide)
            }

            .id("tileMenu|\(slide.id)|\(cueMediaIDs(of: slide).contains { model.media($0) == nil })|\(missingMedia(of: slide).isEmpty)")
            .contextMenu { tileMenu(index: index, slide: slide) }

            .id(Self.tileAnchor(contextID: contextID, index: index))
    }

    private func tile(index: Int, slide: Slide, aspect: CGFloat) -> some View {
        SlideTile(
            model: model, render: render,
            slide: slide, index: index, aspect: aspect,

            presentation: presentation,
            theme: slide.themeId != nil || slide.unthemed == true ? model.theme(for: slide, in: presentation) : theme,
            arrangementId: arrangementId,
            showsSectionLabel: index == 0 || slides[index - 1].sectionId != slide.sectionId,

            controls: controls,
            isSelected: selectedOccurrences.contains(index),
            roundedCorners: roundedCorners,
            hideScopedBackgrounds: hideScopedBackgrounds,
            legibleText: legibleText,
            contextID: contextID,
            mediaMissing: !missingMedia(of: slide).isEmpty
        ) {
            handleTap(index: index, slide: slide)
        }

        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named("slideGrid"))
                Color.clear

                    .onAppear { if tileFrames[index] != frame { tileFrames[index] = frame } }
                    .onChange(of: frame) { _, frame in
                        if tileFrames[index] != frame { tileFrames[index] = frame }
                    }
                    .onDisappear { tileFrames.removeValue(forKey: index) }
            }
        }
        .draggablePayload(runOnly ? nil : SlideBulkEdit.slideDragPayload(
            presentationID: presentation.id, slideID: slide.id))

        .onDrop(of: [.plainText, .fileURL], delegate: GutterDropDelegate(
            enabled: !runOnly,
            dropStarted: {

                dropSettleUntil = Date().addingTimeInterval(0.6)
                dropTargetIndex = nil
                dropTargetAfterIndex = nil
                backgroundDropIndex = nil
            },
            setLine: { on in
                if on {
                    guard Date() >= dropSettleUntil else { return }
                    dropTargetIndex = index
                } else if dropTargetIndex == index {
                    dropTargetIndex = nil
                }
            },
            setRing: { on in
                if on {
                    guard Date() >= dropSettleUntil else { return }
                    backgroundDropIndex = index
                } else if backgroundDropIndex == index {
                    backgroundDropIndex = nil
                }
            },
            performText: { payload, insertZone in
                handleTileText(payload, index: index, slide: slide, insertZone: insertZone)
            },
            performFiles: { urls, insertZone in
                handleTileFiles(urls, index: index, slide: slide, insertZone: insertZone)
            },
            tileWidth: { tileFrames[index]?.width ?? 0 },
            setLineAfter: { on in
                if on {
                    guard Date() >= dropSettleUntil else { return }
                    dropTargetAfterIndex = index
                } else if dropTargetAfterIndex == index {
                    dropTargetAfterIndex = nil
                }
            },
            performTextAfter: { payload in
                dropTargetIndex = nil
                dropTargetAfterIndex = nil
                backgroundDropIndex = nil
                return !runOnly && dropSlide(payload, after: slide)
            }
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .offset(x: -7.5)
            }
        }
        .overlay(alignment: .trailing) {
            if dropTargetAfterIndex == index {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .offset(x: 7.5)
            }
        }
        .overlay {
            if backgroundDropIndex == index {

                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        Color(nsColor: .controlAccentColor).opacity(0.9), lineWidth: 2)
            }
        }
    }

    private func handleTileText(
        _ payload: String, index: Int, slide: Slide, insertZone: Bool
    ) -> Bool {

        dropTargetIndex = nil
        dropTargetAfterIndex = nil
        backgroundDropIndex = nil
        defer {
            Task { @MainActor in
                dropTargetIndex = nil
                dropTargetAfterIndex = nil
                backgroundDropIndex = nil
            }
        }
        guard !runOnly else { return false }
        if payload.hasPrefix("mxuslide::") {

            return dropSlide(payload, before: slide)
        }

        let resolved = model.indexEntry(payload)
        DiagnosticsStore.shared.note(
            "grid.drop.text",
            detail: "insert=\(insertZone) kind=\(resolved?.kind.rawValue ?? "unresolved") payload=\(payload.prefix(40))")
        if !insertZone, let entry = resolved, entry.kind == .actionCombo {
            appendSlideAction(
                SlideAction(id: UUID().uuidString, kind: .fireCombo, comboId: entry.id),
                to: slide)
            return true
        }

        if !insertZone, let entry = resolved, entry.kind == .audio {
            appendSlideAction(
                SlideAction(id: UUID().uuidString, kind: .fireAudio, audioItemId: entry.id),
                to: slide)
            return true
        }
        if !insertZone, let entry = resolved, entry.kind == .playlist,
           (try? model.playlist(entry.id))?.effectiveKind == .audio {
            appendSlideAction(
                SlideAction(id: UUID().uuidString, kind: .fireAudioPlaylist, playlistId: entry.id),
                to: slide)
            return true
        }
        if !insertZone, payload.hasPrefix("pltrk::") {
            let parts = payload.components(separatedBy: "::")
            guard parts.count == 3,
                  let playlist = try? model.playlist(parts[1]),
                  playlist.effectiveKind == .audio,
                  let track = playlist.entries.first(where: { $0.id == parts[2] })
            else { return false }
            appendSlideAction(
                SlideAction(id: UUID().uuidString, kind: .fireAudio, audioItemId: track.refId),
                to: slide)
            return true
        }
        if insertZone {
            return insertMediaSlides(mediaIDs: [payload], beforeIndex: index)
        }
        return model.setSlideBackground(
            presentationID: presentation.id, slideID: slide.id, mediaID: payload)
    }

    private func appendSlideAction(_ action: SlideAction, to slide: Slide) {
        let appended = model.updateSlide(
            presentationID: presentation.id, slideID: slide.id, undoLabel: "Add Action"
        ) { target in
            target.actions = (target.actions ?? []) + [action]
        }
        if appended {
            let number = (presentation.slides.firstIndex { $0.id == slide.id } ?? 0) + 1
            DiagnosticsStore.shared.note(
                "grid.drop.appended", detail: "\(action.kind.rawValue) -> slide \(number)")
        } else {
            DiagnosticsStore.shared.note(
                "grid.drop.appendMiss", detail: "slide \(slide.id) not in \(presentation.id)")
        }
    }

    private func autoAdvanceBinding(_ slideIDs: [String]) -> Binding<AutoAdvance?> {
        Binding(
            get: {
                model.presentation(presentation.id)?.slides
                    .first { slideIDs.contains($0.id) }?.autoAdvance
            },
            set: { advance in
                model.updateSlides(presentationID: presentation.id, undoLabel: "Auto Advance") { presentation in
                    SlideBulkEdit.setAutoAdvance(advance, on: slideIDs, in: &presentation)
                }
            }
        )
    }

    private func removeSlideAction(_ actionID: String, from slide: Slide) {
        model.updateSlide(presentationID: presentation.id, slideID: slide.id, undoLabel: "Remove Action") { target in
            var actions = target.actions ?? []
            actions.removeAll { $0.id == actionID }

            target.actions = actions.isEmpty ? nil : actions
        }
    }

    private func slideActionsBinding(_ slideID: String) -> Binding<[SlideAction]> {
        Binding(
            get: {
                model.presentation(presentation.id)?.slides
                    .first { $0.id == slideID }?.actions ?? []
            },
            set: { actions in
                model.updateSlide(presentationID: presentation.id, slideID: slideID, undoLabel: "Edit Actions") {
                    $0.actions = actions.isEmpty ? nil : actions
                }
            }
        )
    }

    private func handleTileFiles(_ urls: [URL], index: Int, slide: Slide, insertZone: Bool) {
        dropTargetIndex = nil
        backgroundDropIndex = nil
        guard !runOnly, !urls.isEmpty else { return }
        let slideID = slide.id
        Task { @MainActor in

            let imported = await model.importFiles(urls)
            if insertZone {
                _ = insertMediaSlides(mediaIDs: imported, beforeIndex: index)
            } else if let first = imported.first {
                _ = model.setSlideBackground(
                    presentationID: presentation.id, slideID: slideID, mediaID: first)
            }
        }
    }

    private func appendDropDelegate(enabled: Bool) -> GutterDropDelegate {
        GutterDropDelegate(
            enabled: enabled,
            breadcrumb: "grid.appendDrop",
            dropStarted: {
                dropSettleUntil = Date().addingTimeInterval(0.6)
                dropTargetAfterIndex = nil
            },
            setLine: { on in
                if on, Date() >= dropSettleUntil {
                    dropTargetAfterIndex = slides.count - 1
                } else if !on, dropTargetAfterIndex == slides.count - 1 {
                    dropTargetAfterIndex = nil
                }
            },
            setRing: { _ in },
            performText: { payload, _ in
                dropTargetAfterIndex = nil
                return !runOnly && insertMediaSlides(mediaIDs: [payload], beforeIndex: slides.count)
            },
            performFiles: { urls, _ in
                dropTargetAfterIndex = nil
                if !runOnly {
                    Task { @MainActor in
                        let imported = await model.importFiles(urls)
                        _ = insertMediaSlides(mediaIDs: imported, beforeIndex: slides.count)
                    }
                }
            },
            insertOnly: true,
            rejectPrefixes: ["mxueditslide::", "mxuslide::", "mxuobj::"]
        )
    }

    private func insertMediaSlides(mediaIDs: [String], beforeIndex index: Int) -> Bool {
        let items = mediaIDs.compactMap { model.media($0) }
        let anchorSection = slides.indices.contains(index) ? slides[index].sectionId : slides.last?.sectionId
        let afterID = index > 0 && slides.indices.contains(index - 1)
            ? slides[index - 1].id : nil
        if items.isEmpty {
            return false
        } else {
            model.insertSlides(
                presentation.id,
                slides: items.map { Slide.droppedMedia($0, sectionId: anchorSection) },
                afterSlideID: afterID)
            return true
        }
    }

    private func dropSlide(_ payload: String, before target: Slide) -> Bool {
        if let dragged = SlideBulkEdit.draggedSlide(in: payload), dragged.slideID != target.id {
            if dragged.presentationID == presentation.id,
               let source = presentation.slides.first(where: { $0.id == dragged.slideID }) {

                confirmingRepeatedSectionEdit(sections: [source.sectionId, target.sectionId]) {
                    model.moveSlide(presentation.id, slideID: source.id, beforeSlideID: target.id)
                }
                return true
            } else if dragged.presentationID != presentation.id,
                      model.presentationExists(dragged.presentationID) {

                confirmingRepeatedSectionEdit(sections: [target.sectionId]) {
                    model.copySlide(
                        dragged.slideID, from: dragged.presentationID,
                        to: presentation.id, beforeSlideID: target.id)
                }
                return true
            } else {
                return false
            }
        } else {
            return false
        }
    }

    private func dropSlide(_ payload: String, after target: Slide) -> Bool {
        if let dragged = SlideBulkEdit.draggedSlide(in: payload), dragged.slideID != target.id {
            if dragged.presentationID == presentation.id,
               let source = presentation.slides.first(where: { $0.id == dragged.slideID }) {
                confirmingRepeatedSectionEdit(sections: [source.sectionId, target.sectionId]) {
                    model.moveSlide(presentation.id, slideID: source.id, afterSlideID: target.id)
                }
                return true
            } else if dragged.presentationID != presentation.id,
                      model.presentationExists(dragged.presentationID) {
                confirmingRepeatedSectionEdit(sections: [target.sectionId]) {
                    model.copySlide(
                        dragged.slideID, from: dragged.presentationID,
                        to: presentation.id, afterSlideID: target.id)
                }
                return true
            } else {
                return false
            }
        } else {
            return false
        }
    }

    private func confirmingRepeatedSectionEdit(
        sections sectionIds: [String?], _ apply: @escaping () -> Void
    ) {
        guard let arrangement = effectiveArrangement else {
            apply()
            return
        }
        let repeatedNames = Set(sectionIds.compactMap { $0 })
            .filter { id in arrangement.sectionIds.filter { $0 == id }.count > 1 }
            .map { id in presentation.sections?.first { $0.id == id }?.name ?? "section" }
            .sorted()
        if repeatedNames.isEmpty {
            apply()
        } else {

            let edit = PendingSectionEdit(sectionNames: repeatedNames, apply: apply)
            pendingEdit = nil
            DispatchQueue.main.async { pendingEdit = edit }
        }
    }
}

struct SlideTile: View {
    let model: AppModel
    let render: RenderContext?
    let slide: Slide
    let index: Int

    let aspect: CGFloat
    let presentation: Presentation
    let theme: Theme?
    let arrangementId: String?

    let showsSectionLabel: Bool

    let controls: ServiceControls?

    var isSelected = false
    let roundedCorners: Bool
    let hideScopedBackgrounds: Bool
    let legibleText: Bool

    var contextID: String? = nil

    var mediaMissing = false
    let fire: () -> Void

    private var isLive: Bool {
        contextID != nil && controls?.liveContextID == contextID && controls?.liveOccurrence == index
    }

    private var liveAnimationStep: Int? {
        isLive ? controls?.slideAnimationStep?.consumed : nil
    }

    @Environment(\.actionRouter) private var actionRouter

    private var tileShape: RoundedRectangle {
        .standard(roundedCorners ? CornerStandard.element : 0)
    }

    private var section: PresentationSection? {
        guard let id = slide.sectionId, !id.isEmpty else { return nil }
        return presentation.sections?.first { $0.id == id }
    }

    private var labelName: String? {
        guard !slide.name.isEmpty else { return nil }
        let mediaName = slide.background.flatMap { background in
            (background.layer ?? .loopingVideos) == .videos
                ? nil : model.media(background.mediaId)?.name
        }
        return SlidePreview.rowText(for: slide, backgroundMediaName: mediaName)
            == .name ? slide.name : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SlideThumbnailView(
                model: model, render: render,
                slide: slide, presentation: presentation, theme: theme,
                arrangementId: arrangementId,
                hideScopedBackgrounds: hideScopedBackgrounds,
                legibleText: legibleText
            )
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(tileShape)

            .overlay(alignment: .topLeading) {
                if showsSectionLabel, let section {
                    let hex = section.resolvedColorHex(paletteColors: model.groupColors)
                    Text(section.name)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(GroupColor.text(onHex: hex))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            (hex.flatMap(GroupColor.color)
                                ?? Color(.sRGB, white: 0.32)).opacity(0.92),
                            in: Capsule()
                        )
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if mediaMissing {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.orange, in: Circle())
                        .padding(4)
                        .help("Media file missing on this Mac — right-click it in the Library › Locate Missing Media…")
                }
            }
            .overlay {
                if isLive {
                    tileShape.strokeBorder(.green, lineWidth: 3)
                } else if isSelected {

                    tileShape.strokeBorder(Color.accentColor, lineWidth: 2)
                } else {
                    tileShape.strokeBorder(.separator, lineWidth: 1)
                }
            }
            HStack(spacing: 5) {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isLive ? .green : .secondary)

                if let name = labelName {
                    Text(String(name.prefix(30)))
                        .font(.caption)
                        .foregroundStyle(isLive ? .primary : .secondary)
                        .lineLimit(1)
                }

                if hasClippedText {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .tileHelp("Text on this slide doesn't fit its box — the overflow is clipped on the output. Open the slide in Edit to see the outlined box.")
                }

                if !pageLooks.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "rectangle.stack")
                        Text("\(pageLooks.map(\.pages.count).max() ?? 0)")
                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .tileHelp(pageLooks.map { "\($0.pages.count) pages on \($0.outputs)" }.joined(separator: "; ")
                              + ". Each click turns one page there while the projector holds. Hover to see them.")
                    .onHover { pagesHovered = $0 }
                    .popover(isPresented: $pagesHovered, arrowEdge: .bottom) { pagesStrip }
                }

                if stepCount > 0 {
                    Text("\(isLive ? 1 + (liveAnimationStep ?? 0) : 0)/\(stepCount + 1)")
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isLive ? Color.white : Color.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            (isLive ? Color.green : Color(.sRGB, white: 0.5).opacity(0.25)),
                            in: Capsule()
                        )
                        .tileHelp(isLive
                              ? "Click \(1 + (liveAnimationStep ?? 0)) of \(stepCount + 1): the fire was click 1. Advance (or click this tile) is the next; after the last, Advance moves on."
                              : "\(stepCount + 1) clicks on this slide: the fire, then \(stepCount) more step\(stepCount == 1 ? "" : "s").")
                } else if hasAnySteps {

                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                        .foregroundStyle(isLive ? Color.green : Color.secondary)
                        .tileHelp("Animation plays on this slide when it fires, with no extra clicks. This includes steps an output's routed theme adds.")
                }
                Spacer(minLength: 4)

                if let advance = slide.autoAdvance {
                    Glyph(kind: .timers, size: 9)
                        .foregroundStyle(.tertiary)
                        .tileHelp(autoAdvanceSummary(advance))
                }

                if !actionBadges.isEmpty {
                    let actions = slide.actions ?? []
                    HStack(spacing: 3) {

                        ForEach(Array(actions.prefix(4)), id: \.id) { action in
                            Glyph(kind: badgeGlyph(action.kind), size: 9)
                                .foregroundStyle(.tertiary)
                                .tileHelp(slideActionLabel(
                                    action, model: model,
                                    timers: actionRouter?.timerChoices ?? [],
                                    confidenceScreens: actionRouter?.confidenceScreenChoices ?? []))
                        }
                        if actionBadges.count > 4 {
                            Text("+\(actionBadges.count - 4)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .tileHelp(actionSummary)
                        }
                    }
                }
            }
            .padding(.leading, 2)
            .frame(height: SlideGridMetrics.labelHeight)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: fire)

        .task(id: clippedTextKey) {
            let slide = slide
            let theme = theme
            let presentation = presentation
            let looks = predictedLooks.map { (id: $0.id, theme: $0.theme, outputs: $0.targetIds.map { render?.outputs.outputName($0) ?? "Output" }.joined(separator: ", ")) }
            let measured = await Task.detached(priority: .utility) {
                let clipped = !SlideSceneBuilder.clippedTextObjectIDs(
                    for: slide, theme: theme, presentation: presentation
                ).isEmpty

                let pages = looks.compactMap { look -> PageLook? in
                    let pages = Paging.pages(of: slide, through: look.theme, from: theme)
                    return pages.count > 1 ? PageLook(id: look.id, outputs: look.outputs, theme: look.theme, pages: pages) : nil
                }

                let steps = PlaceholderAnimations.advanceCount(slide: slide, themes: [theme] + looks.map { $0.theme as Theme? })
                return (clipped, pages, steps)
            }.value
            hasClippedText = measured.0
            pageLooks = measured.1
            pagedStepCount = measured.2
        }
    }

    @State private var hasClippedText = false
    @State private var pageLooks: [PageLook] = []
    @State private var pagesHovered = false

    struct PageLook: Identifiable {
        let id: String
        let outputs: String
        let theme: Theme
        let pages: [Slide]
    }

    private var predictedLooks: [ActionRouter.OverrideLook] {
        actionRouter?.predictedOverrideLooks(for: slide, contextID: contextID) ?? []
    }

    private var pagesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(pageLooks) { look in
                Text("\(look.outputs): \(look.pages.count) pages")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(Array(look.pages.enumerated()), id: \.element.id) { index, page in
                        VStack(spacing: 2) {
                            SlideThumbnailView(
                                model: model, render: render,
                                slide: page, presentation: presentation, theme: look.theme,
                                arrangementId: nil, hideScopedBackgrounds: false, legibleText: false,
                                contentStamp: "pages|\(slide.id)|\(look.id)|\(index)")
                            .frame(width: 160, height: 90)
                            .clipShape(RoundedRectangle.standard(CornerStandard.element))
                            Text("Page \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    private var predictedThemes: [Theme?] {
        var themes: [Theme?] = [theme]
        for override in actionRouter?.predictedOverrideThemes(for: slide, contextID: contextID) ?? [] {
            themes.append(override)
        }
        return themes
    }

    private var stepCount: Int {

        pagedStepCount ?? PlaceholderAnimations.advanceCount(slide: slide, themes: predictedThemes, paging: false)
    }

    @State private var pagedStepCount: Int?

    private var hasAnySteps: Bool {
        PlaceholderAnimations.hasAnimationSteps(slide: slide, themes: predictedThemes)
    }

    private struct ClippedTextKey: Equatable {
        let slide: Slide
        let theme: Theme?

        let looks: [String]
    }

    private var clippedTextKey: ClippedTextKey {
        ClippedTextKey(slide: slide, theme: theme, looks: predictedLooks.map(\.id))
    }

    private var actionBadges: [GlyphKind] {
        (slide.actions ?? []).map { badgeGlyph($0.kind) }
    }

    private func badgeGlyph(_ kind: SlideActionKind) -> GlyphKind {
        switch kind {
        case .switchOutputPreset: .screens
        case .clearLayer, .clearAll, .clearAudio, .clearSignage: .clear
        case .fireMedia: .media
        case .fireAlert, .dismissAlert: .alerts
        case .timerStart, .timerPause, .timerReset, .timerConfigure: .timers
        case .midiOut: .midi
        case .fireCombo: .combos
        case .captureStart, .captureStop: .broadcast
        case .firePresentation: .presentations
        case .setConfidenceLayout: .confidence
        case .fireOverlay, .dismissOverlay: .overlays
        case .fireLiveInput: .screens
        case .setSignage: .media
        case .setScreenSource: .screens
        case .enableAudioInput, .disableAudioInput: .audio
        case .fireAudio, .fireAudioPlaylist: .audio
        }
    }

    private func autoAdvanceSummary(_ advance: AutoAdvance) -> String {
        let seconds = advance.delaySeconds
        let interval = seconds == seconds.rounded()
            ? "\(Int(abs(seconds)))s" : String(format: "%.1fs", abs(seconds))
        var text: String
        if advance.afterPlayback ?? false {
            text = if seconds > 0 {
                "Auto Advance: \(interval) after the video ends"
            } else if seconds < 0 {
                "Auto Advance: \(interval) before the video ends"
            } else {
                "Auto Advance: when the video ends"
            }
        } else {
            text = "Auto Advance: after \(interval)"
        }
        if advance.loopToStart ?? false { text += ", loops to the first slide" }
        return text
    }

    private var actionSummary: String {
        (slide.actions ?? []).map {
            slideActionLabel(
                $0, model: model, timers: actionRouter?.timerChoices ?? [],
                confidenceScreens: actionRouter?.confidenceScreenChoices ?? [])
        }.joined(separator: "\n")
    }
}

@MainActor
func slideActionLabel(
    _ action: SlideAction, model: AppModel,
    timers: [(id: String, name: String)] = [],
    confidenceScreens: [(id: String, name: String)] = []
) -> String {
    func entryName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "not set" }

        return model.indexEntry(id)?.name ?? "missing"
    }
    func timerName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "not set" }
        return timers.first { $0.id == id }?.name ?? "missing"
    }
    func liveInputName(_ action: SlideAction) -> String? {
        if let itemId = action.liveInputId, !itemId.isEmpty {
            return VideoInputInventory.shared.entry(id: itemId)?.name ?? "missing input"
        }

        guard let id = action.inputSourceId, !id.isEmpty else { return nil }
        return LiveInputCatalog.legacyLabel(kind: action.inputSourceKind, id: id)
    }
    func audioInputName(_ action: SlideAction) -> String? {
        guard let id = action.audioInputId, !id.isEmpty else { return nil }
        return AudioInputInventory.shared.name(forId: id) ?? "missing input"
    }
    func configureDetail(_ action: SlideAction) -> String {
        var parts: [String] = []
        switch action.timerMode {
        case .countdown?: parts.append("Countdown")
        case .countdownToTime?:
            let hour = action.timerHour ?? 0
            parts.append("Until \(TimersController.wallLabel(hour: hour, minute: action.timerMinute ?? 0))")
        case .countUp?: parts.append("Count Up")
        case nil: break
        }
        if action.timerMode != .countdownToTime, let seconds = action.timerDurationSeconds, seconds > 0 {
            parts.append(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: " ")))"
    }
    return switch action.kind {
    case .switchOutputPreset:
        "Switch Output Preset: \(entryName(action.presetId))"
    case .clearLayer:
        "Clear \(action.layer.flatMap(LayerKind.init(rawValue:))?.displayName ?? "Layer")"
    case .clearAll: "Clear All"
    case .clearAudio: "Clear Music"
    case .clearSignage: "Clear Signage"
    case .fireMedia: "Fire Media: \(entryName(action.mediaId))"
    case .fireAlert: "Fire Alert: \(entryName(action.alertId))"
    case .dismissAlert: "Dismiss Alert"
    case .timerStart: "Start Timer: \(timerName(action.timerId))"
    case .timerPause: "Pause Timer: \(timerName(action.timerId))"
    case .timerReset: "Reset Timer: \(timerName(action.timerId))"
    case .timerConfigure:
        "Configure Timer: \(timerName(action.timerId))\(configureDetail(action))"
    case .midiOut: "MIDI Out: ch \(action.midiChannel ?? 1)"
    case .fireCombo: "Run Combo: \(entryName(action.comboId))"
    case .captureStart: "Start Capture: \(entryName(action.capturePresetId))"
    case .captureStop:
        action.capturePresetId == nil
            ? "Stop All Capture"
            : "Stop Capture: \(entryName(action.capturePresetId))"
    case .firePresentation:
        "Fire Presentation: \(entryName(action.presentationId))"
    case .setConfidenceLayout:

        {
            let layout = (action.confidenceLayoutId?.isEmpty ?? true)
                ? "Built-in Layout" : entryName(action.confidenceLayoutId)
            guard let screenId = action.confidenceScreenId, !screenId.isEmpty else {
                return "Confidence Monitor: \(layout)"
            }
            let screen = confidenceScreens.first {
                $0.id.caseInsensitiveCompare(screenId) == .orderedSame
            }?.name ?? "missing screen"
            return "Confidence Monitor: \(layout) on \(screen)"
        }()
    case .fireOverlay: "Fire Overlay: \(entryName(action.overlayId))"
    case .dismissOverlay:
        (action.overlayId?.isEmpty ?? true)
            ? "Take Down Overlays"
            : "Take Down Overlay: \(entryName(action.overlayId))"
    case .fireLiveInput:
        "Fire Live Input: \(liveInputName(action) ?? "not set")"
    case .setSignage:
        (action.playlistId?.isEmpty ?? true)
            ? "Clear Signage"
            : "Signage: \(entryName(action.playlistId))"
    case .setScreenSource:
        (action.signageId?.isEmpty ?? true)
            ? "Screen Source : Program"
            : "Screen Source : Signage"
    case .enableAudioInput:
        "Audio Input On: \(audioInputName(action) ?? "not set")"
    case .disableAudioInput:
        "Audio Input Off: \(audioInputName(action) ?? "not set")"
    case .fireAudio: "Music: \(entryName(action.audioItemId))"
    case .fireAudioPlaylist: "Music Playlist: \(entryName(action.playlistId))"
    }
}

struct SlideThumbnailView: View {
    let model: AppModel
    let render: RenderContext?
    let slide: Slide
    let presentation: Presentation
    let theme: Theme?
    let arrangementId: String?
    let hideScopedBackgrounds: Bool
    let legibleText: Bool

    var contentStamp: String? = nil

    @AppStorage("slideGrid.transparencyGrid") private var transparencyGrid = true

    private var updatedStamp: String {
        contentStamp
            ?? "\(model.entry(presentation.id)?.updatedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {

        let source = ThumbnailStore.shared.backgroundSource(
            slideID: slide.id, presentation: presentation,
            arrangementId: arrangementId, stamp: updatedStamp
        )

        let carried = ThumbnailStore.shared.carriedMedia(
            slideID: slide.id, presentation: presentation,
            arrangementId: arrangementId, stamp: updatedStamp, model: model
        )
        let shown = hideScopedBackgrounds ? carried.filter { declaredMediaIDs.contains($0.value) } : carried

        let missing = SlideSceneBuilder.fireMediaPosterIDs(slide: slide) { model.media($0).map { ($0.mediaKind, $0.classification) } }
            .below.filter { model.media($0) == nil }
        ZStack {
            if transparencyGrid {

                TransparencyGrid()
            } else {
                themeBackground
            }

            ForEach([LayerKind.loopingVideos, .stillGraphics].compactMap { shown[$0] } + missing, id: \.self) { id in
                posterLayer(mediaId: id)
            }
            if let content = contentImage() {
                Image(decorative: content, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            if let id = shown[.videos] {
                posterLayer(mediaId: id)
            }
        }
        .overlay(alignment: .bottomLeading) {

            if source?.source == .slide(slide.id) {
                Image(systemName: "film.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .tileHelp("This slide sets the background")
            }
        }
    }

    private var declaredMediaIDs: Set<String> {
        var ids = Set((slide.actions ?? []).filter { $0.kind == .fireMedia }.compactMap(\.mediaId))
        if let own = slide.background?.mediaId, !own.isEmpty { ids.insert(own) }
        return ids
    }

    private var themeBackground: Color {
        if let theme, let color = ColorHex.color(theme.backgroundColorHex) {
            return Color(
                red: color.red, green: color.green, blue: color.blue, opacity: color.alpha
            )
        }
        return .black
    }

    private func posterLayer(mediaId: String) -> some View {
        Color.clear
            .overlay { PosterImage(model: model, mediaId: mediaId) }
            .clipped()
    }

    private func contentImage() -> CGImage? {

        let identity = "\(presentation.id)|\(slide.id)|\(SlideSceneBuilder.lookKey(for: slide, theme: theme))|\(legibleText)"
        let image = ThumbnailStore.shared.slideContent(
            slide: slide, theme: theme,
            render: render, model: model,
            legibleText: legibleText,
            canvas: SlideSceneBuilder.canvasSize(for: presentation),
            cacheKey: "\(identity)|\(updatedStamp)",
            identity: identity,
            mediaEffects: { model.mediaSceneEffects(id: $0) }
        )
        if let image {
            DropLatency.painted(slide.id, detail: "content \(image.width)px")
        }
        return image
    }
}

struct PosterImage: View {
    let model: AppModel
    let mediaId: String

    @State private var image: CGImage?
    @State private var missing = false

    var body: some View {

        let stamp = "\(mediaId)|\(model.media(mediaId)?.fileHash ?? "gone")"
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(missing ? 0.4 : 1)
            } else {
                Color.black
            }
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Media file missing")
            }
        }
        .task(id: stamp) {
            guard let item = model.media(mediaId) else {

                missing = true
                image = await ThumbnailStore.shared.tombstonePoster(id: mediaId)
                return
            }
            guard let blobs = model.blobs else { return }
            missing = model.isMediaFileMissing(item)
            if !missing, let cached = ThumbnailStore.shared.cachedPoster(for: item) {
                image = cached
                return
            }

            image = nil
            image = await ThumbnailStore.shared.poster(for: item, blobs: blobs)
        }
    }
}

struct AudioFireView: View {
    let model: AppModel
    let controls: ServiceControls?
    let audioID: String

    var body: some View {
        if let item = model.audio(audioID) {
            let isLive = controls?.state.liveAudio
                .contains { $0.audioItemId == audioID } ?? false
            let player = controls?.audio.player(forAudioItem: audioID)
            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(isLive ? Color.green : .secondary)
                HStack(spacing: 8) {
                    Text(item.name).font(.headline)
                    if isLive {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                if let player, player.duration > 0 {

                    AudioScrubBar(player: player, showsTimes: true)
                        .frame(maxWidth: 360)
                } else if let duration = item.durationSeconds {
                    Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    if isLive {
                        controls?.stopAudio(audioItemID: item.id)
                    } else {
                        controls?.fire(audioItem: item)
                    }
                } label: {
                    Label(
                        isLive ? "Stop" : "Play",
                        systemImage: isLive ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ContentUnavailableView("Music not found", systemImage: "questionmark.square.dashed")
        }
    }
}

struct PlaylistFireView: View {
    let model: AppModel
    let controls: ServiceControls?
    let playlistID: String

    var body: some View {
        if let playlist = try? model.playlist(playlistID) {
            let isLive = controls?.state.liveAudio
                .contains { $0.playlistId == playlist.id } ?? false
            VStack(spacing: 16) {
                Image(systemName: isLive ? "waveform" : "music.note.list")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(isLive ? Color.green : .secondary)
                Text(playlist.name).font(.headline)
                VStack(spacing: 2) {
                    ForEach(playlist.entries, id: \.id) { track in
                        let isCurrent = controls?.audio
                            .player(forPlaylist: playlist.id)?.currentEntryID == track.id
                        Button {
                            controls?.fire(playlist: playlist, startAt: track.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent ? "waveform" : "music.note")
                                    .font(.system(size: 10))
                                    .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.6))
                                    .frame(width: 16)
                                Text(model.entry(track.refId)?.name ?? track.refId)
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let seconds = trackSeconds(track) {
                                    Text(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            isCurrent ? Color.green.opacity(0.10) : Color.primary.opacity(0.03),
                            in: RoundedRectangle.standard(CornerStandard.element)
                        )
                        .tileHelp("Play the playlist starting here")
                    }
                }
                .frame(maxWidth: 440)
                if let player = controls?.audio.player(forPlaylist: playlist.id),
                   player.duration > 0 {

                    AudioScrubBar(player: player, showsTimes: true)
                        .frame(maxWidth: 440)
                }
                Button {
                    if isLive {
                        controls?.stopAudio(playlistID: playlist.id)
                    } else {
                        controls?.fire(playlist: playlist)
                    }
                } label: {
                    Label(
                        isLive ? "Stop" : "Play",
                        systemImage: isLive ? "stop.fill" : "play.fill"
                    )
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func trackSeconds(_ track: PlaylistEntry) -> Double? {
        switch track.refKind {
        case .audio: model.audio(track.refId)?.durationSeconds
        case .media: model.media(track.refId)?.durationSeconds
        }
    }
}

struct MediaFireView: View {
    let model: AppModel
    let controls: ServiceControls?
    let mediaID: String

    var serviceItemID: String? = nil

    @State private var mediaMenuState = MediaCueMenuState()

    @Environment(\.runOnly) private var runOnly

    var body: some View {

        if let item = model.media(mediaID) {
            let isLive = controls?.state.liveMedia.values.contains { $0.mediaId == mediaID } ?? false
            VStack(spacing: 16) {

                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { PosterImage(model: model, mediaId: mediaID) }
                    .frame(maxWidth: 640)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay {
                        if isLive {
                            RoundedRectangle.standard(CornerStandard.element)
                                .strokeBorder(.green, lineWidth: 3)
                        }
                    }
                    .contextMenu {
                        if !runOnly {
                            MediaCueMenuItems(
                                model: model, actionRouter: controls?.actionRouter,
                                mediaID: mediaID, state: mediaMenuState
                            )
                        }
                    }
                HStack(spacing: 8) {
                    Text(item.name).font(.headline)
                    if isLive {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }

                if model.isMediaFileMissing(item) {
                    Label("\u{201C}\(item.fileName)\u{201D} isn't on this Mac", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Button {
                    if let serviceItemID {
                        controls?.fire(mediaItem: item, context: .serviceItem(id: serviceItemID))
                    } else {
                        controls?.fire(mediaItem: item)
                    }
                } label: {
                    Label("Fire", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.isMediaFileMissing(item))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .mediaCueSheets(model: model, state: mediaMenuState)
        } else {

            ContentUnavailableView(
                "Deleted from the library",
                systemImage: "questionmark.square.dashed",
                description: Text(runOnly
                    ? "Unlock run-only to restore a file for it."
                    : "Right-click to restore a file for it — every slide and service using it heals.")
            )
            .contextMenu {
                if !runOnly {
                    MediaCueMenuItems(
                        model: model, actionRouter: controls?.actionRouter,
                        mediaID: mediaID, state: mediaMenuState
                    )
                }
            }
            .mediaCueSheets(model: model, state: mediaMenuState)
        }
    }
}

struct SongKeyChip: View {
    let model: AppModel
    let controls: ServiceControls?
    let presentation: Presentation

    @Environment(\.runOnly) private var runOnly

    var body: some View {
        if let musicKey = presentation.musicKey {
            transposeMenu(musicKey: musicKey)
        } else if !runOnly, ChordMath.hasChords(in: presentation) {
            setKeyMenu
        }
    }

    private func transposeMenu(musicKey: String) -> some View {
        let displayed = presentation.displayKey ?? musicKey
        return Menu {
            ForEach(ChordMath.keyChoices(matching: musicKey), id: \.self) { name in
                Button {
                    transpose(to: name, musicKey: musicKey)
                } label: {
                    let original = name.caseInsensitiveCompare(musicKey) == .orderedSame
                    if name.caseInsensitiveCompare(displayed) == .orderedSame {
                        Label(original ? "\(name) (Original)" : name, systemImage: "checkmark")
                    } else {
                        Text(original ? "\(name) (Original)" : name)
                    }
                }
            }
        } label: {
            chipLabel("Key: \(displayed)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func transpose(to name: String, musicKey: String) {
        model.updatePresentationField(
            presentation.id, \.displayKey, key: "displayKey",
            to: name.caseInsensitiveCompare(musicKey) == .orderedSame ? nil : name,
            undoLabel: "Transpose")
        controls?.presentationEdited(presentation.id)
    }

    private var setKeyMenu: some View {
        Menu {
            ForEach(ChordMath.keyChoices(matching: "C"), id: \.self) { name in
                Button(name) { setKey(name) }
            }
            Divider()
            ForEach(ChordMath.keyChoices(matching: "Am"), id: \.self) { name in
                Button(name) { setKey(name) }
            }
        } label: {
            chipLabel("Key: Set…")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tileHelp("This song has chords but no key yet — pick the key they're written in")
    }

    private func setKey(_ name: String) {
        model.updatePresentationField(presentation.id, \.musicKey, key: "musicKey", to: name, undoLabel: "Set Key")
        controls?.presentationEdited(presentation.id)
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct SlideShowChip: View {
    let model: AppModel
    let controls: ServiceControls?
    let presentation: Presentation

    @Environment(\.runOnly) private var runOnly
    @State private var sheetPresented = false

    var body: some View {
        if let slideShow = presentation.autoAdvance {
            if runOnly {
                chipLabel(text(slideShow))
            } else {
                Button {
                    sheetPresented = true
                } label: {
                    chipLabel(text(slideShow))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .sheet(isPresented: $sheetPresented) {
                    AutoAdvanceSheet(
                        slideName: presentation.name,
                        advance: Binding(
                            get: { model.presentation(presentation.id)?.autoAdvance },
                            set: { advance in
                                model.updatePresentationField(
                                    presentation.id, \.autoAdvance, key: "autoAdvance", to: advance,
                                    undoLabel: "Slide Show")
                                controls?.presentationEdited(presentation.id)
                            }
                        ),
                        presentationScope: true
                    )
                }
            }
        }
    }

    private func text(_ slideShow: AutoAdvance) -> String {
        let seconds = slideShow.delaySeconds
        let interval = seconds == seconds.rounded()
            ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
        return "Slide Show: \(interval)\((slideShow.loopToStart ?? false) ? " · Loop" : "")"
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

extension View {
    @ViewBuilder
    func tileHelp(_ text: @autoclosure () -> String) -> some View {
        self
    }
}
