import AppKit
import CoreGraphics
import Foundation
import Observation
import PresenterCore
import RenderEngine
import SlideScene

@MainActor
@Observable
final class SlideEditorModel {

    private enum Host {
        case presentation(EditorReplica<Presentation>)
        case theme(EditorReplica<Theme>)

        case overlay(EditorReplica<Overlay>)

        case confidenceLayout(EditorReplica<ConfidenceLayout>)

        init?<E: DocumentEntity>(_ replica: EditorReplica<E>) {
            switch replica {
            case let deck as EditorReplica<Presentation>: self = .presentation(deck)
            case let theme as EditorReplica<Theme>: self = .theme(theme)
            case let overlay as EditorReplica<Overlay>: self = .overlay(overlay)
            case let layout as EditorReplica<ConfidenceLayout>: self = .confidenceLayout(layout)
            default: return nil
            }
        }
    }

    let appModel: AppModel
    private let render: RenderContext?
    @ObservationIgnored private var host: Host

    @ObservationIgnored private var token: EditorToken

    @ObservationIgnored private let inbox: LandingInbox
    @ObservationIgnored private var sessionEnded = false

    @ObservationIgnored private var headsAtRequest: [String] = []
    private let blobs: BlobStore?

    var isThemeEditor: Bool {
        if case .theme = host { return true } else { return false }
    }

    var isOverlayEditor: Bool {
        if case .overlay = host { return true } else { return false }
    }

    var isConfidenceEditor: Bool {
        if case .confidenceLayout = host { return true } else { return false }
    }

    var isSingleComposition: Bool { isOverlayEditor || isConfidenceEditor }

    private(set) var presentation: Presentation
    private(set) var selectedSlideID: String?

    private(set) var selectedSlideIDs: Set<String> = []
    private(set) var selectedObjectIDs: Set<String> = []
    private(set) var canUndo = false
    private(set) var canRedo = false

    private(set) var previewFrames: [String: CGRect] = [:]

    private(set) var activeGuides: [EditorGeometry.Guide] = []

    private(set) var textEditRequests = 0

    private(set) var showsThemeContent = true

    func toggleThemeContent() {
        showsThemeContent.toggle()
        refreshScene()
    }

    private(set) var showsChords = false

    func toggleChords() {
        showsChords.toggle()
        endCanvasTextEdit()
        refreshScene()
    }

    struct ChordTarget {
        var objectID: String
        var frame: CGRect
        var text: StyledText
        var chordsMatch: Bool
    }

    var chordTargets: [ChordTarget] {
        if showsChords, let slide = currentSlide, let scene = render?.scene {
            let items = Dictionary(
                scene.layers.flatMap(\.items).compactMap { item -> (String, (CGRect, StyledText))? in
                    if case .text(let styled) = item.content, styled.pathData == nil {
                        (item.id, (item.frame, styled))
                    } else {
                        nil
                    }
                },
                uniquingKeysWith: { first, _ in first }
            )
            return slide.objects.reversed().compactMap { object in
                if object.objectKind == .text, object.textLink == nil,
                   let (frame, text) = items[object.id] ?? items[object.id + "::text"] {
                    ChordTarget(
                        objectID: object.id, frame: frame, text: text,
                        chordsMatch: text.chords.count == (object.chords ?? []).count
                    )
                } else {
                    nil
                }
            }
        } else {
            return []
        }
    }

    @discardableResult
    func setChord(objectID: String, index: Int, symbol: String) -> Int? {
        var landed: Int?
        updateObject(id: objectID) { object in
            let edit = ChordEditing.setting(symbol, at: index, in: object.chords ?? [])
            object.chords = edit.chords.isEmpty ? nil : edit.chords
            landed = edit.index
        }
        return landed
    }

    @discardableResult
    func addChord(objectID: String, line: Int, column: Int, symbol: String) -> Int? {
        var landed: Int?
        updateObject(id: objectID) { object in
            let edit = ChordEditing.adding(symbol, line: line, column: column, to: object.chords ?? [], text: object.text)
            object.chords = edit.chords.isEmpty ? nil : edit.chords
            landed = edit.index
        }
        return landed
    }

    func removeChord(objectID: String, index: Int) {
        updateObject(id: objectID) { object in
            let chords = ChordEditing.removing(at: index, from: object.chords ?? [])
            object.chords = chords.isEmpty ? nil : chords
        }
    }

    @discardableResult
    func moveChord(objectID: String, index: Int, toObjectID: String, line: Int, column: Int) -> Int? {
        var landed: Int?
        if toObjectID == objectID {
            updateObject(id: objectID) { object in
                let edit = ChordEditing.moving(at: index, toLine: line, column: column, in: object.chords ?? [], text: object.text)
                object.chords = edit.chords.isEmpty ? nil : edit.chords
                landed = edit.index
            }
        } else if let chords = object(id: objectID)?.chords, chords.indices.contains(index) {
            let symbol = chords[index].symbol
            updateObjects(ids: [objectID, toObjectID]) { object in
                if object.id == objectID {
                    let chords = ChordEditing.removing(at: index, from: object.chords ?? [])
                    object.chords = chords.isEmpty ? nil : chords
                } else {
                    let edit = ChordEditing.adding(symbol, line: line, column: column, to: object.chords ?? [], text: object.text)
                    object.chords = edit.chords.isEmpty ? nil : edit.chords
                    landed = edit.index
                }
            }
        }
        return landed
    }

    enum EditorMode: String, CaseIterable {
        case design
        case animate

        var displayName: String {
            switch self {
            case .design: "Design"
            case .animate: "Animate"
            }
        }
    }
    var editorMode: EditorMode = .design

    var timelinePointsPerSecond: Double = 120

    var timelineZoomAdjusted = false

    var timelineAnimatedOnly = true

    var timelineRowHeight: Double = 34

    enum PreviewScope: String, CaseIterable {
        case all
        case thisClick
        case fromPlayhead

        var displayName: String {
            switch self {
            case .all: "All"
            case .thisClick: "This Click"
            case .fromPlayhead: "From Playhead"
            }
        }
    }
    var previewScope: PreviewScope = .all

    var previewRepeats = false

    var timelineFocusColumn: SceneAnimationGroup?

    var timelineDraftClickAt: Int?

    var animationPreviewTime: Double? {
        didSet { syncAnimationPreviewActive() }
    }
    var animationPreviewPlaying = false {
        didSet { syncAnimationPreviewActive() }
    }

    private(set) var animationPreviewActive = false
    private func syncAnimationPreviewActive() {
        let active = animationPreviewPlaying || animationPreviewTime != nil
        if animationPreviewActive != active { animationPreviewActive = active }
    }
    @ObservationIgnored var animationPreviewStartedAt: Double = 0
    @ObservationIgnored var animationPreviewClock: Timer?

    @ObservationIgnored var animationPreviewStopAt: Double?

    @ObservationIgnored var animationPreviewLoopStart: Double = 0

    var animationPreviewPlayhead: Double = 0

    var canvasHoveredObjectID: String?

    var selectQuickAddResult = false

    var selectedAnimationStepID: String?

    var stepAddSlot: AnimationSequence.GroupSlot?

    var stepAddArmed = false

    @ObservationIgnored private var liveMediaIDs: Set<String> = []
    @ObservationIgnored private var themeCache: (id: String, fill: Int, theme: Theme?)?

    @ObservationIgnored private var lastCommitted: [String] = []

    init?(appModel: AppModel, render: RenderContext?, presentationID: String) async {
        let inbox = LandingInbox(observers: appModel.batchObservers, kind: .presentation, id: presentationID)
        if let checkout = try? await appModel.client.checkout(Presentation.self, id: presentationID, history: .parked) {
            let replica = checkout.replica
            self.host = .presentation(replica)
            self.token = checkout.token
            self.inbox = inbox
            self.appModel = appModel
            self.render = render
            self.blobs = try? BlobStore(libraryRoot: appModel.client.rootURL)
            self.lastCommitted = SyncLedger.hex(replica.heads())
            self.presentation = replica.value
            self.selectedSlideID = replica.value.slides.first?.id
            self.selectedSlideIDs = self.selectedSlideID.map { [$0] } ?? []
            refreshScene()
            sweepClippedTextWarnings()

            inbox.open(for: self, after: checkout.sequence)
        } else {
            inbox.close()
            return nil
        }
    }

    init?(appModel: AppModel, render: RenderContext?, themeID: String) async {
        let inbox = LandingInbox(observers: appModel.batchObservers, kind: .theme, id: themeID)
        let checkout = try? await appModel.client.checkout(Theme.self, id: themeID, history: .parked)
        if let checkout, Self.scaffold(checkout.replica, themeID: themeID, token: checkout.token, client: appModel.client) {
            let replica = checkout.replica
            self.host = .theme(replica)
            self.token = checkout.token
            self.inbox = inbox
            self.appModel = appModel
            self.render = render
            self.blobs = try? BlobStore(libraryRoot: appModel.client.rootURL)
            self.lastCommitted = SyncLedger.hex(replica.heads())
            let mirror = Self.mirror(of: replica.value)
            self.presentation = mirror
            self.selectedSlideID = mirror.slides.first?.id
            self.selectedSlideIDs = self.selectedSlideID.map { [$0] } ?? []
            refreshScene()
            inbox.open(for: self, after: checkout.sequence)
        } else {
            if let checkout {
                appModel.client.release(token: checkout.token)
            }
            inbox.close()
            return nil
        }
    }

    private static func scaffold(
        _ replica: EditorReplica<Theme>, themeID: String, token: EditorToken, client: LibraryClient
    ) -> Bool {
        if replica.value.slides?.isEmpty != false {
            let opened = replica.heads()
            if (try? replica.update { $0.slides = Theme.defaultSlides() }) != nil,
               let scaffold = try? replica.encodeChangesSince(heads: opened) {
                client.commit(Theme.self, id: themeID, changes: scaffold, token: token)
                return true
            } else {
                return false
            }
        } else {
            return true
        }
    }

    init?(appModel: AppModel, render: RenderContext?, overlayID: String) async {
        let inbox = LandingInbox(observers: appModel.batchObservers, kind: .overlay, id: overlayID)
        if let checkout = try? await appModel.client.checkout(Overlay.self, id: overlayID, history: .parked) {
            let replica = checkout.replica
            self.host = .overlay(replica)
            self.token = checkout.token
            self.inbox = inbox
            self.appModel = appModel
            self.render = render
            self.blobs = try? BlobStore(libraryRoot: appModel.client.rootURL)
            self.lastCommitted = SyncLedger.hex(replica.heads())
            let mirror = Self.mirror(of: replica.value)
            self.presentation = mirror
            self.selectedSlideID = mirror.slides.first?.id
            self.selectedSlideIDs = self.selectedSlideID.map { [$0] } ?? []
            refreshScene()
            inbox.open(for: self, after: checkout.sequence)
        } else {
            inbox.close()
            return nil
        }
    }

    init?(appModel: AppModel, render: RenderContext?, confidenceLayoutID: String) async {
        let inbox = LandingInbox(observers: appModel.batchObservers, kind: .confidenceLayout, id: confidenceLayoutID)
        if let checkout = try? await appModel.client.checkout(
            ConfidenceLayout.self, id: confidenceLayoutID, history: .parked
        ) {
            let replica = checkout.replica
            self.host = .confidenceLayout(replica)
            self.token = checkout.token
            self.inbox = inbox
            self.appModel = appModel
            self.render = render
            self.blobs = try? BlobStore(libraryRoot: appModel.client.rootURL)
            self.lastCommitted = SyncLedger.hex(replica.heads())
            let mirror = Self.mirror(of: replica.value)
            self.presentation = mirror
            self.selectedSlideID = mirror.slides.first?.id
            self.selectedSlideIDs = self.selectedSlideID.map { [$0] } ?? []
            refreshScene()
            inbox.open(for: self, after: checkout.sequence)
        } else {
            inbox.close()
            return nil
        }
    }

    private static func mirror(of theme: Theme) -> Presentation {
        Presentation(
            id: theme.id, name: theme.name, presentationKind: .deck,
            themeId: "", slides: theme.slides ?? []
        )
    }

    private static func mirror(of overlay: Overlay) -> Presentation {
        Presentation(
            id: overlay.id, name: overlay.name, presentationKind: .deck,
            themeId: "",
            slides: [Slide(id: overlay.id, name: overlay.name, objects: overlay.objects, animationOrder: overlay.animationOrder)]
        )
    }

    private static func mirror(of layout: ConfidenceLayout) -> Presentation {
        layout.editorMirror
    }

    func teardown() {
        endSession()
        render?.media.stopAll(withPrefix: Self.editorMediaPrefix)
        liveMediaIDs = []
    }

    func endSession() {
        if !sessionEnded {
            sessionEnded = true
            inbox.close()
            appModel.client.release(token: token, history: history)
        }
    }

    private var history: EditorHistory {
        switch host {
        case .presentation(let replica): replica.history
        case .theme(let replica): replica.history
        case .overlay(let replica): replica.history
        case .confidenceLayout(let replica): replica.history
        }
    }

    var currentSlideIndex: Int? {
        presentation.slides.firstIndex { $0.id == selectedSlideID }
    }

    var currentSlide: Slide? {
        guard var slide = documentSlide else { return nil }
        if let editing = animationStateEditing,
           let index = slide.objects.firstIndex(where: { $0.id == editing.objectID }) {
            var state = editing.state
            state.id = editing.objectID
            state.animationSteps = slide.objects[index].animationSteps
            slide.objects[index] = state
        }
        return slide
    }

    var documentSlide: Slide? {
        currentSlideIndex.map { presentation.slides[$0] }
    }

    struct AnimationStateEditing: Equatable {
        var objectID: String
        var stepID: String

        var isStart: Bool
        var state: SlideObject
    }

    @ObservationIgnored var bypassStateRedirect = false

    func updateDocumentObject(id: String, _ mutate: (inout SlideObject) -> Void) {
        bypassStateRedirect = true
        defer { bypassStateRedirect = false }
        updateObject(id: id, mutate)
    }

    var animationStateEditing: AnimationStateEditing? {
        guard let stepID = selectedAnimationStepID, let slide = documentSlide else { return nil }
        for object in slide.objects {
            guard let step = object.animationSteps?.first(where: { $0.id == stepID }) else { continue }
            if step.kind == .morph, let to = step.toObject {
                return AnimationStateEditing(objectID: object.id, stepID: stepID, isStart: false, state: to)
            }
            if step.kind == .in, let from = step.fromObject {
                return AnimationStateEditing(objectID: object.id, stepID: stepID, isStart: true, state: from)
            }
            return nil
        }
        return nil
    }

    var singleSelectedObject: SlideObject? {
        guard selectedObjectIDs.count == 1, let id = selectedObjectIDs.first else { return nil }
        return object(id: id)
    }

    func object(id: String) -> SlideObject? {
        currentSlide?.objects.first { $0.id == id }
    }

    var selectedObjects: [SlideObject] {
        SelectionFormatting.selectedObjects(in: currentSlide?.objects ?? [], ids: selectedObjectIDs)
    }

    var inspectedObject: SlideObject? {
        singleSelectedObject ?? SelectionFormatting.primary(in: currentSlide?.objects ?? [], ids: selectedObjectIDs)
    }

    func previewedObject(id: String) -> SlideObject? {
        scrubPreviewOverrides[id] ?? object(id: id)
    }

    var canvasSize: CGSize { SlideSceneBuilder.canvasSize(for: presentation) }

    private(set) var isDraggingObjects = false

    func documentFrame(for object: SlideObject) -> CGRect {
        SlideSceneBuilder.frame(
            for: object,
            placeholder: currentPlaceholderAssignments[object.id],
            in: canvasSize
        )
    }

    func displayFrame(for object: SlideObject) -> CGRect {
        previewFrames[object.id] ?? documentFrame(for: object)
    }

    private var currentPlaceholderAssignments: [String: SlideObject] {
        SlideSceneBuilder.placeholderAssignments(
            for: currentSlide?.objects ?? [], in: currentTemplate
        )
    }

    var theme: Theme? {
        switch host {
        case .presentation:

            let id = currentSlide.map { presentation.themeId(for: $0) } ?? presentation.themeId
            guard !id.isEmpty else { return nil }

            let fill = appModel.fillVersion(of: .theme)
            if let cached = themeCache, cached.id == id, cached.fill == fill { return cached.theme }

            let theme = appModel.theme(id)
            themeCache = (id, fill, theme)
            return theme
        case .theme(let document):
            var base = document.value
            base.slides = nil
            return base
        case .overlay, .confidenceLayout:
            return nil
        }
    }

    var currentTemplate: Slide? {
        guard case .presentation = host, let slide = currentSlide else { return nil }
        return SlideSceneBuilder.themeSlide(for: slide, theme: theme)
    }

    func setTheme(_ id: String) {
        guard case .presentation = host else { return }
        if id == presentation.themeId, !presentation.hasSlideThemes {
            if !id.isEmpty { reapplyTheme() }
            return
        }
        if id.isEmpty {
            detachFromTheme()
        } else {

            updateDocument { presentation in
                presentation.clearSlideThemes()
                presentation.themeId = id
            }
        }
    }

    var presentationHasSlideThemes: Bool {
        guard case .presentation = host else { return false }
        return presentation.hasSlideThemes
    }

    var otherThemeChoices: [(theme: Theme, groups: [(folder: String?, names: [String])])] {
        guard case .presentation = host else { return [] }
        let deckThemeId = presentation.themeId
        return appModel.entries(in: .themes).compactMap { entry in
            guard entry.id != deckThemeId, let theme = appModel.theme(entry.id),
                  let slides = theme.slides, !slides.isEmpty else { return nil }
            return (theme, Self.groups(of: slides))
        }
    }

    private static func groups(of slides: [Slide]) -> [(folder: String?, names: [String])] {
        var groups: [(folder: String?, names: [String])] = []
        for slide in slides {
            if !groups.isEmpty, groups[groups.count - 1].folder == slide.folder {
                groups[groups.count - 1].names.append(slide.name)
            } else {
                groups.append((slide.folder, [slide.name]))
            }
        }
        return groups
    }

    func setThemeSlide(_ name: String?, themeId: String, for slideID: String) {
        guard case .presentation = host else { return }
        let own = themeId == presentation.themeId ? nil : themeId
        let previous = presentation.slides.first { $0.id == slideID }.flatMap(followedDesign)
        let taken = design(name, inTheme: themeId)
        updateSlide(slideID) { slide in
            slide.themeId = own
            slide.themeSlideName = name
            slide.unthemed = nil
            slide.adoptActions(of: taken, replacing: previous)
        }
    }

    private func followedDesign(_ slide: Slide) -> Slide? {
        design(slide.themeSlideName, inTheme: presentation.themeId(for: slide))
    }

    private func design(_ name: String?, inTheme themeId: String) -> Slide? {
        themeId.isEmpty ? nil : appModel.theme(themeId)?.design(named: name)
    }

    func setSlideBlank(_ slideID: String) {
        updateSlide(slideID) { $0.unthemed = true }
    }

    func setOverrideDesign(_ name: String?, forTheme themeId: String, for slideID: String) {
        guard case .presentation = host else { return }
        updateSlide(slideID) { $0.setOverrideDesign(name, forTheme: themeId) }
    }

    func themeId(of slideID: String) -> String {
        guard case .presentation = host, let slide = presentation.slides.first(where: { $0.id == slideID }) else { return "" }
        return presentation.themeId(for: slide)
    }

    func setBackgroundFill(_ fill: ObjectFill?) {
        guard case .presentation = host else { return }
        updateDocument { $0.backgroundFill = fill }
    }

    var themeSlideNames: [String] {
        guard case .presentation = host else { return [] }
        return (theme?.slides ?? []).map(\.name)
    }

    var themeSlideGroups: [(folder: String?, names: [String])] {
        guard case .presentation = host else { return [] }
        var groups: [(folder: String?, names: [String])] = []
        for slide in theme?.slides ?? [] {
            if !groups.isEmpty, groups[groups.count - 1].folder == slide.folder {
                groups[groups.count - 1].names.append(slide.name)
            } else {
                groups.append((slide.folder, [slide.name]))
            }
        }
        return groups
    }

    func setThemeSlide(_ name: String?, for slideID: String) {
        guard case .presentation = host else { return }
        let slide = presentation.slides.first { $0.id == slideID }
        let current = slide?.themeSlideName

        let isSame = slide?.unthemed != true && (name == nil
            ? (current ?? "").isEmpty
            : current?.caseInsensitiveCompare(name!) == .orderedSame)
        var taking = slide
        taking?.unthemed = nil
        let taken = taking.flatMap { design(name, inTheme: presentation.themeId(for: $0)) }
        if isSame {
            updateSlide(slideID) { slide in
                SlideSceneBuilder.resetThemeOverrides(&slide)
                slide.adoptActions(of: taken)
            }
        } else {
            let previous = slide.flatMap(followedDesign)
            updateSlide(slideID) { slide in
                slide.themeSlideName = name
                slide.unthemed = nil
                slide.adoptActions(of: taken, replacing: previous)
            }
        }
    }

    var presentationHasLocalEdits: Bool {
        guard case .presentation = host else { return false }
        return presentation.slides.contains(where: SlideSceneBuilder.hasThemeOverrides)
    }

    func slideHasLocalEdits(_ slide: Slide) -> Bool {
        !isThemeEditor && SlideSceneBuilder.hasThemeOverrides(slide)
    }

    func resetSlideToTheme(_ slideID: String) {
        updateSlide(slideID) { SlideSceneBuilder.resetThemeOverrides(&$0) }
    }

    func reapplyTheme() {
        guard case .presentation = host else { return }
        updateDocument { presentation in
            for index in presentation.slides.indices {
                SlideSceneBuilder.resetThemeOverrides(&presentation.slides[index])
            }
        }
    }

    func resetObjectToTheme(_ objectID: String) {
        resetObjectsToTheme([objectID])
    }

    func resetObjectsToTheme(_ ids: Set<String>) {
        updateObjects(ids: ids) { object in
            object.textStyle = nil
            object.x = nil
            object.y = nil
            object.width = nil
            object.height = nil
        }
    }

    private func detachFromTheme() {
        guard case .presentation = host, !presentation.themeId.isEmpty else { return }
        let appModel = appModel
        updateDocument { presentation in

            presentation.slides = presentation.slides.map { slide in
                guard let theme = appModel.theme(presentation.themeId(for: slide)) else { return slide }
                var baked = SlideSceneBuilder.bakedSlide(slide, theme: theme)
                baked.themeId = nil
                return baked
            }
            presentation.themeId = ""
        }
    }

    func clearSelection() {
        endCanvasTextEdit()
        selectedObjectIDs = []
    }

    func handleClick(objectID: String?, shiftDown: Bool) {
        guard let objects = currentSlide?.objects else { return }
        guard let objectID else {
            if !shiftDown { selectedObjectIDs = [] }
            return
        }
        if shiftDown {
            var ids = selectedObjectIDs
            if ids.contains(objectID) { ids.remove(objectID) } else { ids.insert(objectID) }
            selectedObjectIDs = EditorGeometry.expandSelectionToGroups(ids, in: objects)
        } else if !selectedObjectIDs.contains(objectID) {
            selectedObjectIDs = EditorGeometry.expandSelectionToGroups([objectID], in: objects)
        }
    }

    func selectObject(id: String) {
        guard let objects = currentSlide?.objects else { return }
        selectedObjectIDs = EditorGeometry.expandSelectionToGroups([id], in: objects)
    }

    func requestTextEdit(objectID: String) {
        guard let objects = currentSlide?.objects else { return }
        selectedObjectIDs = EditorGeometry.expandSelectionToGroups([objectID], in: objects)
        textEditRequests += 1
    }

    private(set) var canvasTextEditID: String?

    var inspectorTextFocused = false {
        didSet { if inspectorTextFocused != oldValue { refreshScene() } }
    }

    var motionPausedForEditing: Bool {
        inspectorTextFocused || canvasTextEditID != nil
    }

    private(set) var canvasTextEditStyle: StyledText?

    var canvasTextEditTarget: (frame: CGRect, text: StyledText)? {
        if let id = canvasTextEditID, let object = previewedObject(id: id) {
            let textID = id + "::text"
            let item = render?.scene.layers.lazy.flatMap(\.items).first { item in
                if case .text = item.content { item.id == id || item.id == textID } else { false }
            }
            if let item, case .text(let styled) = item.content {
                return (item.frame, styled)
            } else {
                var empty = canvasTextEditStyle
                empty?.string = ""
                return empty.map { (displayFrame(for: object), $0) }
            }
        } else {
            return nil
        }
    }

    func canvasTextEditEligible(_ object: SlideObject) -> Bool {
        switch object.objectKind {
        case .text:
            return resolvedStyledText(objectID: object.id)?.pathData == nil
        case .shape:
            return (object.shapeTextPlacement ?? .inside) == .inside
        default:
            return false
        }
    }

    func beginCanvasTextEdit(objectID: String) {
        guard let objects = currentSlide?.objects,
              let object = objects.first(where: { $0.id == objectID }),

              object.textLink == nil
        else { return }
        selectedObjectIDs = EditorGeometry.expandSelectionToGroups([objectID], in: objects)
        canvasTextEditStyle = resolvedStyledText(objectID: objectID)
        canvasTextEditID = objectID
        refreshScene()
    }

    func endCanvasTextEdit() {
        guard canvasTextEditID != nil else { return }
        canvasTextEditID = nil
        canvasTextEditStyle = nil
        canvasTextSelection = nil
        refreshScene()
    }

    private(set) var canvasTextSelection: NSRange?

    func canvasTextSelectionChanged(_ range: NSRange) {
        guard canvasTextEditID != nil else { return }
        canvasTextSelection = range
    }

    private var canvasEditedObject: SlideObject? {
        guard let id = canvasTextEditID else { return nil }
        return currentSlide?.objects.first { $0.id == id }
    }

    var canvasSelectionRun: TextStyleRun? {
        guard let object = canvasEditedObject,
              let selection = canvasTextSelection, selection.length > 0 else { return nil }
        let range = TextStyleRuns.characterRange(
            fromUTF16: selection.location, length: selection.length, in: object.text
        )
        return TextStyleRuns.effectiveRun(
            at: range.lowerBound, runs: object.styleRuns ?? [], in: object.text
        )
    }

    func applyStyleToSelection(_ mutate: @escaping (inout TextStyleRun) -> Void) {
        guard let id = canvasTextEditID,
              let selection = canvasTextSelection, selection.length > 0 else { return }
        updateObject(id: id) { object in
            let range = TextStyleRuns.characterRange(
                fromUTF16: selection.location, length: selection.length, in: object.text
            )
            let runs = TextStyleRuns.applying(
                mutate, to: object.styleRuns ?? [], in: object.text, selection: range
            )
            object.styleRuns = runs.isEmpty ? nil : runs
        }
    }

    func toggleSelectionBold() { toggleSelectionTrait(.boldFontMask) }
    func toggleSelectionItalic() { toggleSelectionTrait(.italicFontMask) }

    func toggleSelectionUnderline() {
        let on = canvasSelectionRun?.underline == true
        applyStyleToSelection { $0.underline = on ? nil : true }
    }

    private func toggleSelectionTrait(_ trait: NSFontTraitMask) {
        guard let selection = canvasTextSelection, selection.length > 0 else { return }
        let name = canvasSelectionRun?.fontName
            ?? canvasEditedObject?.textStyle?.fontName
            ?? canvasTextEditStyle?.fontName
            ?? "HelveticaNeue-Bold"
        let size = canvasSelectionRun?.fontSize ?? canvasTextEditStyle?.fontSize ?? 96
        guard let font = NSFont(name: name, size: size) else { return }
        let manager = NSFontManager.shared
        let converted = manager.traits(of: font).contains(trait)
            ? manager.convert(font, toNotHaveTrait: trait)
            : manager.convert(font, toHaveTrait: trait)
        guard converted.fontName != font.fontName else { return }
        applyStyleToSelection { $0.fontName = converted.fontName }
    }

    func applyPastedFormatting(_ attributed: NSAttributedString, atUTF16 location: Int) {
        guard let id = canvasTextEditID, let object = canvasEditedObject else { return }
        let baseName = object.textStyle?.fontName ?? canvasTextEditStyle?.fontName ?? "HelveticaNeue-Bold"
        let baseSize = canvasTextEditStyle?.fontSize ?? 96
        guard let baseFont = NSFont(name: baseName, size: baseSize) else { return }
        let manager = NSFontManager.shared
        var spans: [PastedFormatting.Span] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            var span = PastedFormatting.Span(location: range.location, length: range.length)
            if let font = attributes[.font] as? NSFont {
                let traits = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
                if !traits.isEmpty {
                    var face = baseFont
                    if traits.contains(.boldFontMask) { face = manager.convert(face, toHaveTrait: .boldFontMask) }
                    if traits.contains(.italicFontMask) { face = manager.convert(face, toHaveTrait: .italicFontMask) }
                    if face.fontName != baseFont.fontName { span.fontName = face.fontName }
                }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { span.underline = true }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { span.strikethrough = true }
            spans.append(span)
        }
        guard spans.contains(where: { $0.fontName != nil || $0.underline != nil || $0.strikethrough != nil }) else { return }
        updateObject(id: id) { object in
            let runs = PastedFormatting.apply(spans, pastedAtUTF16: location, to: object.styleRuns ?? [], in: object.text)
            object.styleRuns = runs.isEmpty ? nil : runs
        }
    }

    func canvasTextWillReplace(utf16Range: NSRange, replacement: String) {
        guard let id = canvasTextEditID, let object = canvasEditedObject,
              object.styleRuns?.isEmpty == false || object.chords?.isEmpty == false
                || object.animationSteps?.contains(where: { !($0.ranges ?? []).isEmpty }) == true
        else { return }
        let replaced = TextStyleRuns.characterRange(
            fromUTF16: utf16Range.location, length: utf16Range.length, in: object.text
        )
        updateObject(id: id) { object in
            let old = object.text
            let runs = TextStyleRuns.replacing(
                object.styleRuns ?? [], range: replaced, with: replacement, in: old
            )
            object.styleRuns = runs.isEmpty ? nil : runs
            if let chords = object.chords, !chords.isEmpty {
                let moved = TextStyleRuns.replacing(chords, range: replaced, with: replacement, in: old)
                object.chords = moved.isEmpty ? nil : moved
            }

            if let animationSteps = object.animationSteps, animationSteps.contains(where: { !($0.ranges ?? []).isEmpty }) {
                let moved = AnimationRanges.reanchor(animationSteps, range: replaced, with: replacement, in: old)
                object.animationSteps = moved.isEmpty ? nil : moved
            }
            let start = old.index(old.startIndex, offsetBy: min(replaced.lowerBound, old.count))
            let end = old.index(old.startIndex, offsetBy: min(replaced.upperBound, old.count))
            object.text = old.replacingCharacters(in: start..<end, with: replacement)
        }
    }

    private func resolvedStyledText(objectID: String) -> StyledText? {
        if let render {
            let textID = objectID + "::text"
            for layer in render.scene.layers {
                for item in layer.items where item.id == objectID || item.id == textID {
                    if case .text(let styled) = item.content { return styled }
                }
            }
        }
        guard let object = object(id: objectID) else { return nil }
        let own = object.textStyle
        return StyledText(
            string: object.text,
            fontName: own?.fontName ?? theme?.fontFamily ?? "HelveticaNeue-Bold",
            fontSize: own?.fontSize ?? theme?.fontSize ?? 96,
            color: own?.colorHex.flatMap(ColorHex.color)
                ?? theme.flatMap { ColorHex.color($0.textColorHex) }
                ?? .white
        )
    }

    func selectSlide(_ id: String) {
        guard presentation.slides.contains(where: { $0.id == id }) else { return }

        if selectedSlideIDs != [id] { selectedSlideIDs = [id] }
        guard id != selectedSlideID else { return }
        selectedSlideID = id
        selectedObjectIDs = []
        selectedAnimationStepID = nil

        animationPreviewClock?.invalidate()
        animationPreviewClock = nil
        animationPreviewPlaying = false
        animationPreviewTime = nil
        animationPreviewPlayhead = 0
        previewFrames = [:]
        activeGuides = []
        if isDraggingObjects { isDraggingObjects = false }

        render?.media.stopAll(withPrefix: Self.editorMediaPrefix)
        liveMediaIDs = []
        refreshScene()
    }

    func setSlideSelection(_ ids: Set<String>) {
        let living = ids.filter { id in presentation.slides.contains { $0.id == id } }
        if let current = selectedSlideID, living.contains(current) {
            if selectedSlideIDs != living { selectedSlideIDs = living }
        } else if let first = presentation.slides.first(where: { living.contains($0.id) }) {
            selectSlide(first.id)
            selectedSlideIDs = living
        }
    }

    func selectAllSlides() {
        setSlideSelection(Set(presentation.slides.map(\.id)))
    }

    func slideBatch(for id: String) -> [String] {
        SlideBulkEdit.batch(for: id, selected: selectedSlideIDs, slides: presentation.slides)
    }

    var moveTargetThemes: [LibraryIndex.Entry] {
        isThemeEditor ? appModel.entries(in: .themes).filter { $0.id != presentation.id } : []
    }

    var choosingNewSlide = false

    func addSlide() {
        if isThemeEditor {

            let slide = Slide(
                id: UUID().uuidString, name: "Category \(presentation.slides.count + 1)",
                objects: [SlideObject(
                    id: UUID().uuidString, objectKind: .text,
                    name: "Text Placeholder", text: "Sample Text"
                )]
            )
            let anchor = selectedSlideID
            updateDocument { SlideBulkEdit.insertSlides([slide], after: anchor, in: &$0) }
            selectSlide(slide.id)
        } else {
            choosingNewSlide = true
        }
    }

    func addSlide(_ choice: NewSlideChoice) {
        let anchor = selectedSlideID
        let slide = choice.slide(sectionId: nil, deckThemeId: presentation.themeId)
        updateDocument { SlideBulkEdit.insertSlides([slide], after: anchor, in: &$0) }
        selectSlide(slide.id)
    }

    func duplicateSlide(_ id: String) {
        duplicateSlides([id])
    }

    func duplicateSlides(_ ids: [String]) {
        let targets = Set(ids)
        let before = Set(presentation.slides.map(\.id))
        if presentation.slides.contains(where: { targets.contains($0.id) }) {
            updateDocument { presentation in

                for index in presentation.slides.indices.reversed()
                where targets.contains(presentation.slides[index].id) {

                    var copy = presentation.slides[index].freshIDCopy()
                    if !copy.name.isEmpty { copy.name += " Copy" }
                    presentation.slides.insert(copy, at: index + 1)
                }
            }
            let fresh = presentation.slides.map(\.id).filter { !before.contains($0) }
            if let first = fresh.first {
                selectSlide(first)
                selectedSlideIDs = Set(fresh)
            }
        }
    }

    func moveSlides(_ ids: [String], beforeSlideID: String?) {
        let anchorInBatch = beforeSlideID.map { ids.contains($0) } ?? false
        if !anchorInBatch {
            for id in presentation.slides.map(\.id) where ids.contains(id) {
                moveSlide(id, beforeSlideID: beforeSlideID)
            }
        }
    }

    func moveSlides(_ ids: [String], afterSlideID: String) {
        if !ids.contains(afterSlideID) {
            for id in presentation.slides.map(\.id).reversed() where ids.contains(id) {
                moveSlide(id, afterSlideID: afterSlideID)
            }
        }
    }

    @discardableResult
    func moveSlides(_ ids: [String], toTheme themeID: String) -> Bool {
        var moved = false
        if isThemeEditor, themeID != presentation.id, let target = appModel.theme(themeID) {
            var source = presentation.slides
            var destination = target.slides?.isEmpty == false ? target.slides ?? [] : Theme.defaultSlides()
            let firstIndex = presentation.slides.firstIndex { ids.contains($0.id) } ?? 0
            if SlideBulkEdit.moveSlides(ids, from: &source, to: &destination) {
                let slides = destination
                appModel.updateTheme(themeID) { $0.slides = slides }
                updateDocument { $0.slides = source }
                reselectAfterRemoval(of: Set(ids), firstIndex: firstIndex)
                moved = true
            }
        }
        return moved
    }

    func moveSlide(_ id: String, beforeSlideID: String?) {
        guard id != beforeSlideID,
              let from = presentation.slides.firstIndex(where: { $0.id == id })
        else { return }
        let before = beforeSlideID.flatMap { beforeID in
            presentation.slides.firstIndex { $0.id == beforeID }
        }

        var next = presentation
        var slide = next.slides.remove(at: from)
        let originalSectionId = slide.sectionId
        let target = before.map { $0 > from ? $0 - 1 : $0 } ?? next.slides.count
        let neighbor = target < next.slides.count ? next.slides[target] : next.slides.last
        slide.sectionId = neighbor?.sectionId
        next.slides.insert(slide, at: min(target, next.slides.count))

        let fields: [String: ScalarValue?] = originalSectionId == slide.sectionId
            ? [:]
            : ["sectionId": slide.sectionId.map { .String($0) }]
        commitSlideMove(from: from, before: before, fields: fields, next: next)
    }

    private func commitSlideMove(
        from: Int, before: Int?, fields: [String: ScalarValue?], next: Presentation
    ) {
        let start = ContinuousClock.now
        var writeDone = start
        do {
            switch host {
            case .presentation(let document):
                presentation = try document.moveListElement(
                    listAt: [AnyCodingKey("slides")], from: from, before: before,
                    settingOnMoved: fields, next: next
                )
            case .theme(let document):
                var themeNext = document.value
                themeNext.slides = next.slides
                presentation = Self.mirror(of: try document.moveListElement(
                    listAt: [AnyCodingKey("slides")], from: from, before: before,
                    settingOnMoved: fields, next: themeNext
                ))
            case .overlay, .confidenceLayout:
                return 
            }
            writeDone = .now
            finishMutation()
        } catch {}

        let finish = writeDone.duration(to: .now)
        DiagnosticsStore.shared.note(
            "editor.moveSlide.commit",
            detail: "write=\(start.duration(to: writeDone)) finish=\(finish)"
        )
    }

    func moveSlide(_ id: String, afterSlideID: String) {
        guard id != afterSlideID,
              let from = presentation.slides.firstIndex(where: { $0.id == id }),
              let anchor = presentation.slides.firstIndex(where: { $0.id == afterSlideID })
        else { return }
        let before: Int? = anchor + 1 < presentation.slides.count ? anchor + 1 : nil
        let anchorSectionId = presentation.slides[anchor].sectionId

        var next = presentation
        var slide = next.slides.remove(at: from)
        let originalSectionId = slide.sectionId
        let target = before.map { $0 > from ? $0 - 1 : $0 } ?? next.slides.count
        slide.sectionId = anchorSectionId
        next.slides.insert(slide, at: min(target, next.slides.count))
        guard next != presentation else { return }

        let fields: [String: ScalarValue?] = originalSectionId == anchorSectionId
            ? [:]
            : ["sectionId": anchorSectionId.map { .String($0) }]
        commitSlideMove(from: from, before: before, fields: fields, next: next)
    }

    func moveSlide(_ id: String, toSection sectionId: String) {
        guard presentation.slides.contains(where: { $0.id == id }) else { return }
        updateDocument { presentation in
            guard let from = presentation.slides.firstIndex(where: { $0.id == id })
            else { return }
            var slide = presentation.slides.remove(at: from)
            slide.sectionId = sectionId
            let insertIndex = presentation.slides
                .lastIndex { $0.sectionId == sectionId }
                .map { $0 + 1 } ?? presentation.slides.count
            presentation.slides.insert(slide, at: insertIndex)
        }
    }

    func copySlides(_ ids: [String]) {
        let targets = Set(ids)
        let slides = presentation.slides.filter { targets.contains($0.id) }
        if !slides.isEmpty {
            SlidePasteboard.copy(slides)
        }
    }

    func pasteSlides(after id: String) {
        let pasted = SlidePasteboard.pasteAll()
        if !pasted.isEmpty, let index = presentation.slides.firstIndex(where: { $0.id == id }) {
            let sectionId = presentation.slides[index].sectionId
            let landing = isThemeEditor
                ? SlideBulkEdit.adoptedForTheme(pasted, existing: presentation.slides)
                : pasted.map { slide in
                    var slide = slide
                    slide.sectionId = sectionId
                    return slide
                }
            updateDocument { $0.slides.insert(contentsOf: landing, at: index + 1) }
            selectSlide(landing[0].id)
            selectedSlideIDs = Set(landing.map(\.id))
        }
    }

    func copySelectedSlides() {
        copySlides(Array(selectedSlideIDs))
    }

    func cutSelectedSlides() {
        copySelectedSlides()
        deleteSlides(Array(selectedSlideIDs))
    }

    func deleteSlide(_ id: String) {
        deleteSlides([id])
    }

    func deleteSlides(_ ids: [String]) {
        let targets = Set(ids)
        let survivors = presentation.slides.filter { !targets.contains($0.id) }
        if !survivors.isEmpty, survivors.count < presentation.slides.count {
            let firstIndex = presentation.slides.firstIndex { targets.contains($0.id) } ?? 0
            updateDocument { SlideBulkEdit.deleteSlides(ids, in: &$0) }
            reselectAfterRemoval(of: targets, firstIndex: firstIndex)
        }
    }

    private func reselectAfterRemoval(of targets: Set<String>, firstIndex: Int) {
        if let current = selectedSlideID, targets.contains(current) {
            let fallback = presentation.slides[min(firstIndex, presentation.slides.count - 1)].id
            selectedSlideID = nil
            selectSlide(fallback)
        }
    }

    func addTextObject() {
        let frame = SlideSceneBuilder.defaultFrame(for: .text, in: canvasSize)
        add(SlideObject(
            id: UUID().uuidString, objectKind: .text, name: "Text", text: "",
            x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height
        ))
    }

    func addShapeObject() {
        let size = CGSize(width: 400, height: 300)
        add(SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: "Shape", text: "",
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2,
            width: size.width, height: size.height,
            shapeKind: .rectangle,
            fill: ObjectFill(fillKind: .solid, colorHex: "#4A90D9FF")
        ))
    }

    func addMediaObject(mediaID: String, name: String) {
        add(SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: name, text: "",
            x: 0, y: 0,
            width: canvasSize.width,
            height: canvasSize.height,
            fill: ObjectFill(fillKind: .media, mediaId: mediaID)
        ))
    }

    func importMediaObjects(_ urls: [URL], placement: LibraryHome.Placement) {
        Task {
            for id in await appModel.importFiles(urls, placement: placement) {
                addMediaObject(mediaID: id, name: appModel.media(id)?.name ?? "")
            }
        }
    }

    @discardableResult
    func dropMediaObject(mediaID: String, at scenePoint: CGPoint) -> Bool {
        guard let item = appModel.media(mediaID)
        else { return false }
        let canvas = canvasSize
        var size = CGSize(width: canvas.width / 2, height: canvas.height / 2)
        if let w = item.pixelWidth, let h = item.pixelHeight, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            size = aspect >= canvas.width / canvas.height
                ? CGSize(width: canvas.width / 2, height: canvas.width / 2 / aspect)
                : CGSize(width: canvas.height / 2 * aspect, height: canvas.height / 2)
        }
        var origin = CGPoint(x: scenePoint.x - size.width / 2, y: scenePoint.y - size.height / 2)
        origin.x = max(0, min(origin.x, canvas.width - size.width))
        origin.y = max(0, min(origin.y, canvas.height - size.height))
        add(SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: item.name, text: "",
            x: origin.x, y: origin.y, width: size.width, height: size.height,
            fill: ObjectFill(fillKind: .media, mediaId: mediaID)
        ))
        return true
    }

    func dropFiles(_ urls: [URL], at scenePoint: CGPoint) {
        guard !urls.isEmpty else { return }
        Task { await placeFiles(urls, at: scenePoint) }
    }

    private func placeFiles(_ urls: [URL], at scenePoint: CGPoint) async {
        let ids = await appModel.importFiles(urls)
        for (index, id) in ids.enumerated() {
            let offset = CGFloat(index) * 32
            dropMediaObject(
                mediaID: id,
                at: CGPoint(x: scenePoint.x + offset, y: scenePoint.y + offset)
            )
        }
    }

    func addLiveInputObject() {
        add(SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: "Live Input", text: "",
            x: 0, y: 0,
            width: canvasSize.width,
            height: canvasSize.height,
            fill: ObjectFill(
                fillKind: .media, captureSourceKind: .camera, captureSourceId: "")
        ))
    }

    private func add(_ object: SlideObject) {
        guard !isMultiView, let slideIndex = currentSlideIndex else { return }
        endCanvasTextEdit()
        updateDocument { $0.slides[slideIndex].objects.append(object) }
        selectedObjectIDs = [object.id]
    }

    func deleteSelectedObjects() {
        guard let slideIndex = currentSlideIndex, !selectedObjectIDs.isEmpty else { return }
        let ids = selectedObjectIDs
        selectedObjectIDs = []
        updateDocument { $0.slides[slideIndex].objects.removeAll { ids.contains($0.id) } }
    }

    var canCopyObjects: Bool { !selectedObjectIDs.isEmpty }

    var canPaste: Bool { pasteSource != nil }

    private var pasteSource: EditorPaste.Source? {
        EditorPaste.source(types: NSPasteboard.general.types?.map(\.rawValue) ?? [])
    }

    func paste() {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        switch pasteSource {
        case .objects:
            pasteObjects()
        case .slides:
            if let anchor = presentation.slides.last(where: { selectedSlideIDs.contains($0.id) })?.id ?? selectedSlideID {
                pasteSlides(after: anchor)
            }
        case .files:
            let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            dropFiles(urls, at: center)
        case .image:
            pasteImage(at: center)
        case nil:
            break
        }
    }

    private func pasteImage(at scenePoint: CGPoint) {
        let board = NSPasteboard.general
        if !isMultiView,
           let type = EditorPaste.imageType(in: board.types?.map(\.rawValue) ?? []),
           let data = board.data(forType: NSPasteboard.PasteboardType(type)) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MxU Pasted Images", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            Task {
                let url = await Task.detached(priority: .userInitiated) {
                    EditorPaste.writeImage(data, type: type, into: directory)
                }.value
                if let url {
                    await placeFiles([url], at: scenePoint)
                }
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func copySelectedObjects() {
        guard let slide = currentSlide else { return }
        let objects = slide.objects.filter { selectedObjectIDs.contains($0.id) }
        guard !objects.isEmpty else { return }
        ObjectPasteboard.copy(objects, from: slide.id)
        pasteCascade = 0
    }

    func cutSelectedObjects() {
        guard canCopyObjects else { return }
        copySelectedObjects()
        deleteSelectedObjects()
    }

    @ObservationIgnored private var pasteCascade = 0

    func pasteObjects() {

        guard !isMultiView, let slideIndex = currentSlideIndex,
              let payload = ObjectPasteboard.paste()
        else { return }
        let targetSlideID = presentation.slides[slideIndex].id
        let ontoSource = payload.sourceSlideID == targetSlideID
        pasteCascade = ontoSource ? pasteCascade + 1 : 0
        let offset = CGFloat(pasteCascade) * 24

        var groupMap: [String: String] = [:]
        let pasted = payload.objects.map { object -> SlideObject in
            var copy = object
            if ontoSource {

                let frame = displayFrame(for: copy)
                copy.x = frame.origin.x + offset
                copy.y = frame.origin.y + offset
                copy.width = frame.width
                copy.height = frame.height
            }
            copy.id = UUID().uuidString
            if let groupID = copy.groupId, !groupID.isEmpty {
                if groupMap[groupID] == nil { groupMap[groupID] = UUID().uuidString }
                copy.groupId = groupMap[groupID]
            }
            return copy
        }
        updateDocument { $0.slides[slideIndex].objects.append(contentsOf: pasted) }
        selectedObjectIDs = Set(pasted.map(\.id))
    }

    var canGroup: Bool { selectedObjectIDs.count >= 2 }

    var canUngroup: Bool {
        currentSlide?.objects.contains {
            selectedObjectIDs.contains($0.id) && !($0.groupId ?? "").isEmpty
        } ?? false
    }

    func groupSelection() {
        guard canGroup, let slideIndex = currentSlideIndex else { return }
        let ids = selectedObjectIDs
        let groupID = UUID().uuidString
        updateDocument { presentation in
            for i in presentation.slides[slideIndex].objects.indices
            where ids.contains(presentation.slides[slideIndex].objects[i].id) {
                presentation.slides[slideIndex].objects[i].groupId = groupID
            }
        }
    }

    func ungroupSelection() {
        guard canUngroup, let slideIndex = currentSlideIndex else { return }
        let ids = selectedObjectIDs
        updateDocument { presentation in
            for i in presentation.slides[slideIndex].objects.indices
            where ids.contains(presentation.slides[slideIndex].objects[i].id) {
                presentation.slides[slideIndex].objects[i].groupId = nil
            }
        }
    }

    var panelStackTopFirst: [SlideSceneBuilder.ComposedEntry] {
        SlideSceneBuilder.composedStack(for: currentSlide?.objects ?? [], in: currentTemplate)
            .reversed()
    }

    func movePanelObject(id: String, beforeID: String?) {
        guard let slideIndex = currentSlideIndex, id != beforeID else { return }
        var items = Array(panelStackTopFirst)
        guard let from = items.firstIndex(where: { $0.object.id == id && !$0.fromTheme })
        else { return }
        let item = items.remove(at: from)
        let target = beforeID.flatMap { beforeID in
            items.firstIndex { $0.object.id == beforeID }
        } ?? items.count
        items.insert(item, at: min(target, items.count))
        let documentOrder = Array(items.filter { !$0.fromTheme }.map(\.object).reversed())
        updateDocument { $0.slides[slideIndex].objects = documentOrder }
    }

    var canBringForward: Bool {
        guard let slide = currentSlide, let single = singleSelectedObject else { return false }
        return slide.objects.last?.id != single.id
    }

    var canSendBackward: Bool {
        guard let slide = currentSlide, let single = singleSelectedObject else { return false }
        return slide.objects.first?.id != single.id
    }

    func bringForward() {
        swapSelected(offset: 1)
    }

    func sendBackward() {
        swapSelected(offset: -1)
    }

    func bringToFront() {
        guard let slideIndex = currentSlideIndex, let single = singleSelectedObject,
              let index = presentation.slides[slideIndex].objects.firstIndex(where: { $0.id == single.id }),
              index != presentation.slides[slideIndex].objects.count - 1
        else { return }
        updateDocument {
            let object = $0.slides[slideIndex].objects.remove(at: index)
            $0.slides[slideIndex].objects.append(object)
        }
    }

    func sendToBack() {
        guard let slideIndex = currentSlideIndex, let single = singleSelectedObject,
              let index = presentation.slides[slideIndex].objects.firstIndex(where: { $0.id == single.id }),
              index != 0
        else { return }
        updateDocument {
            let object = $0.slides[slideIndex].objects.remove(at: index)
            $0.slides[slideIndex].objects.insert(object, at: 0)
        }
    }

    private func swapSelected(offset: Int) {
        guard let slideIndex = currentSlideIndex, let single = singleSelectedObject,
              let index = presentation.slides[slideIndex].objects.firstIndex(where: { $0.id == single.id })
        else { return }
        let target = index + offset
        guard presentation.slides[slideIndex].objects.indices.contains(target) else { return }
        updateDocument { $0.slides[slideIndex].objects.swapAt(index, target) }
    }

    func duplicateSelectedObjects() {
        guard let slideIndex = currentSlideIndex, let slide = currentSlide,
              !selectedObjectIDs.isEmpty
        else { return }
        let originals = slide.objects.filter { selectedObjectIDs.contains($0.id) }
        guard !originals.isEmpty else { return }
        var groupMap: [String: String] = [:]
        let copies = originals.map { object -> SlideObject in
            var copy = object
            let frame = displayFrame(for: copy).offsetBy(dx: 24, dy: 24)
            apply(frame, to: &copy)
            copy.id = UUID().uuidString
            if let groupID = copy.groupId, !groupID.isEmpty {
                if groupMap[groupID] == nil { groupMap[groupID] = UUID().uuidString }
                copy.groupId = groupMap[groupID]
            }
            return copy
        }
        updateDocument { $0.slides[slideIndex].objects.append(contentsOf: copies) }
        selectedObjectIDs = Set(copies.map(\.id))
    }

    func setSelection(_ ids: Set<String>) {
        guard let objects = currentSlide?.objects else { return }

        if isMultiView {
            selectedObjectIDs = []
            if let tileID = ids.sorted().lazy.compactMap(MultiViewTiles.nodeId(forObject:)).first {
                selectedTileID = tileID
            }
        } else {
            selectedObjectIDs = EditorGeometry.expandSelectionToGroups(ids, in: objects)
        }
    }

    func selectAllObjects(includingHidden: Bool) {
        setSelection(EditorGeometry.allObjectIDs(in: currentSlide?.objects ?? [], includingHidden: includingHidden))
    }

    func sweptSelection(band: CGRect, keeping base: Set<String>) -> Set<String> {
        let objects = currentSlide?.objects ?? []
        return base.union(EditorGeometry.sweptObjectIDs(band: band, in: objects, frame: displayFrame(for:)))
    }

    func sweepOutline(_ ids: Set<String>) -> Set<String> {
        isMultiView ? [] : EditorGeometry.expandSelectionToGroups(ids, in: currentSlide?.objects ?? [])
    }

    func previewDrag(frames: [String: CGRect], guides: [EditorGeometry.Guide]) {
        if !isDraggingObjects { isDraggingObjects = true }
        previewFrames = frames
        activeGuides = guides
        guard let render, var slide = currentSlide else { return }
        for i in slide.objects.indices {
            if let frame = frames[slide.objects[i].id] { apply(frame, to: &slide.objects[i]) }
        }

        render.scene = editorScene(for: slide, restingGhost: true)
    }

    func commitDrag() {
        let frames = previewFrames
        previewFrames = [:]
        activeGuides = []
        if isDraggingObjects { isDraggingObjects = false }
        guard !frames.isEmpty else {
            refreshScene()
            return
        }
        if frames.count == 1, let (id, frame) = frames.first {
            updateObject(id: id) { apply(frame, to: &$0) }
        } else if let slideIndex = currentSlideIndex {
            updateDocument { presentation in
                for i in presentation.slides[slideIndex].objects.indices {
                    if let frame = frames[presentation.slides[slideIndex].objects[i].id] {
                        apply(frame, to: &presentation.slides[slideIndex].objects[i])
                    }
                }
            }
        }
    }

    func cancelDrag() {
        previewFrames = [:]
        activeGuides = []
        if isDraggingObjects { isDraggingObjects = false }
        refreshScene()
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !selectedObjectIDs.isEmpty else { return }
        let ids = selectedObjectIDs
        if ids.count == 1, let id = ids.first, let object = object(id: id) {
            let frame = displayFrame(for: object).offsetBy(dx: dx, dy: dy)
            updateObject(id: id) { apply(frame, to: &$0) }
        } else if let slideIndex = currentSlideIndex {
            let placeholders = currentPlaceholderAssignments
            let canvas = canvasSize
            updateDocument { presentation in
                for i in presentation.slides[slideIndex].objects.indices
                where ids.contains(presentation.slides[slideIndex].objects[i].id) {
                    let object = presentation.slides[slideIndex].objects[i]
                    let frame = SlideSceneBuilder
                        .frame(for: object, placeholder: placeholders[object.id], in: canvas)
                        .offsetBy(dx: dx, dy: dy)
                    apply(frame, to: &presentation.slides[slideIndex].objects[i])
                }
            }
        }
    }

    private func apply(_ frame: CGRect, to object: inout SlideObject) {
        object.x = frame.origin.x
        object.y = frame.origin.y
        object.width = frame.width
        object.height = frame.height
    }

    var canAlign: Bool { !selectedObjectIDs.isEmpty }

    var canDistribute: Bool { selectionUnitMembers().count >= 3 }

    private func selectionUnitMembers() -> [[SlideObject]] {
        guard let slide = currentSlide else { return [] }
        let selected = slide.objects.filter { selectedObjectIDs.contains($0.id) }
        var order: [String] = []
        var members: [String: [SlideObject]] = [:]
        for object in selected {
            let key = (object.groupId?.isEmpty == false) ? "group:\(object.groupId!)" : "solo:\(object.id)"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(object)
        }
        return order.compactMap { members[$0] }.filter { !$0.isEmpty }
    }

    private func selectionUnits() -> [EditorGeometry.AlignUnit] {
        selectionUnitMembers().map { objects in
            let frames = objects.map { displayFrame(for: $0) }
            let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
            return EditorGeometry.AlignUnit(ids: objects.map(\.id), frame: union)
        }
    }

    func alignSelection(_ edge: EditorGeometry.AlignEdge) {
        let units = selectionUnits()
        guard !units.isEmpty else { return }
        let reference: CGRect = units.count > 1
            ? units.dropFirst().reduce(units[0].frame) { $0.union($1.frame) }
            : CGRect(origin: .zero, size: canvasSize)
        offsetObjects(EditorGeometry.alignDeltas(units: units, edge: edge, reference: reference))
    }

    func distributeSelection(horizontally: Bool) {
        offsetObjects(EditorGeometry.distributeDeltas(
            units: selectionUnits(), horizontally: horizontally
        ))
    }

    private func offsetObjects(_ deltas: [String: CGVector]) {
        guard let slideIndex = currentSlideIndex, !deltas.isEmpty else { return }
        let placeholders = currentPlaceholderAssignments
        let canvas = canvasSize
        updateDocument { presentation in
            for i in presentation.slides[slideIndex].objects.indices {
                let object = presentation.slides[slideIndex].objects[i]
                guard let delta = deltas[object.id] else { continue }
                let frame = SlideSceneBuilder
                    .frame(for: object, placeholder: placeholders[object.id], in: canvas)
                    .offsetBy(dx: delta.dx, dy: delta.dy)
                apply(frame, to: &presentation.slides[slideIndex].objects[i])
            }
        }
    }

    enum ArrangeAction: Hashable {
        case group, ungroup
        case alignLeft, alignCenter, alignRight, alignTop, alignMiddle, alignBottom
        case distributeHorizontally, distributeVertically
        case bringToFront, bringForward, sendBackward, sendToBack

        static let grouping: [ArrangeAction] = [.group, .ungroup]
        static let horizontalAlign: [ArrangeAction] = [.alignLeft, .alignCenter, .alignRight]
        static let verticalAlign: [ArrangeAction] = [.alignTop, .alignMiddle, .alignBottom]
        static let distribute: [ArrangeAction] = [.distributeHorizontally, .distributeVertically]
        static let layerOrder: [ArrangeAction] = [.bringToFront, .bringForward, .sendBackward, .sendToBack]

        var title: String {
            switch self {
            case .group: "Group"
            case .ungroup: "Ungroup"
            case .alignLeft: "Align Left"
            case .alignCenter: "Align Center"
            case .alignRight: "Align Right"
            case .alignTop: "Align Top"
            case .alignMiddle: "Align Middle"
            case .alignBottom: "Align Bottom"
            case .distributeHorizontally: "Distribute Horizontally"
            case .distributeVertically: "Distribute Vertically"
            case .bringToFront: "Bring to Front"
            case .bringForward: "Bring Forward"
            case .sendBackward: "Send Backward"
            case .sendToBack: "Send to Back"
            }
        }

        var systemImage: String {
            switch self {
            case .group: "square.on.square"
            case .ungroup: "square.on.square.dashed"
            case .alignLeft: "align.horizontal.left"
            case .alignCenter: "align.horizontal.center"
            case .alignRight: "align.horizontal.right"
            case .alignTop: "align.vertical.top"
            case .alignMiddle: "align.vertical.center"
            case .alignBottom: "align.vertical.bottom"
            case .distributeHorizontally: "distribute.horizontal.center"
            case .distributeVertically: "distribute.vertical.center"
            case .bringToFront: "square.3.layers.3d.top.filled"
            case .bringForward: "square.2.layers.3d.top.filled"
            case .sendBackward: "square.2.layers.3d.bottom.filled"
            case .sendToBack: "square.3.layers.3d.bottom.filled"
            }
        }
    }

    func canPerform(_ action: ArrangeAction) -> Bool {
        switch action {
        case .group:
            canGroup
        case .ungroup:
            canUngroup
        case .alignLeft, .alignCenter, .alignRight, .alignTop, .alignMiddle, .alignBottom:
            canAlign
        case .distributeHorizontally, .distributeVertically:
            canDistribute
        case .bringToFront, .bringForward:
            canBringForward
        case .sendBackward, .sendToBack:
            canSendBackward
        }
    }

    func perform(_ action: ArrangeAction) {
        switch action {
        case .group: groupSelection()
        case .ungroup: ungroupSelection()
        case .alignLeft: alignSelection(.left)
        case .alignCenter: alignSelection(.centerX)
        case .alignRight: alignSelection(.right)
        case .alignTop: alignSelection(.top)
        case .alignMiddle: alignSelection(.centerY)
        case .alignBottom: alignSelection(.bottom)
        case .distributeHorizontally: distributeSelection(horizontally: true)
        case .distributeVertically: distributeSelection(horizontally: false)
        case .bringToFront: bringToFront()
        case .bringForward: bringForward()
        case .sendBackward: sendBackward()
        case .sendToBack: sendToBack()
        }
    }

    var sections: [PresentationSection] { presentation.sections ?? [] }

    struct SlideGroup: Identifiable {
        let section: PresentationSection?
        let slides: [Slide]
        var id: String { section?.id ?? "unsectioned-\(slides.first?.id ?? "")" }
    }

    var slideGroups: [SlideGroup] {
        var groups: [(section: PresentationSection?, slides: [Slide])] = []
        for slide in presentation.slides {

            let section = isThemeEditor
                ? slide.folder.map { PresentationSection(id: "themefolder::" + $0, name: $0) }
                : sections.first { $0.id == slide.sectionId }
            if !groups.isEmpty, groups[groups.count - 1].section?.id == section?.id {
                groups[groups.count - 1].slides.append(slide)
            } else {
                groups.append((section, [slide]))
            }
        }
        return groups.map { SlideGroup(section: $0.section, slides: $0.slides) }
    }

    func startSection(named name: String, at slideID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !isThemeEditor, !trimmed.isEmpty,
              let start = presentation.slides.firstIndex(where: { $0.id == slideID })
        else { return }
        let previous = presentation.slides[start].sectionId
        let section = PresentationSection(id: UUID().uuidString, name: trimmed)
        updateDocument { presentation in
            presentation.sections = (presentation.sections ?? []) + [section]
            var index = start
            repeat {
                presentation.slides[index].sectionId = section.id
                index += 1
            } while index < presentation.slides.count
                && presentation.slides[index].sectionId == previous
        }
    }

    func renameSection(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateDocument { presentation in
            guard let index = presentation.sections?.firstIndex(where: { $0.id == id }) else { return }
            presentation.sections?[index].name = trimmed
        }
    }

    func deleteSection(_ id: String) {
        updateDocument { presentation in
            presentation.sections?.removeAll { $0.id == id }
            for index in presentation.slides.indices
            where presentation.slides[index].sectionId == id {
                presentation.slides[index].sectionId = nil
            }
            guard presentation.arrangements != nil else { return }
            for index in presentation.arrangements!.indices {
                presentation.arrangements![index].sectionIds.removeAll { $0 == id }
            }
        }
    }

    var arrangements: [Arrangement] { presentation.arrangements ?? [] }

    private var orderedSectionIds: [String] {
        slideGroups.compactMap(\.section?.id)
    }

    @discardableResult
    func addArrangement() -> Arrangement? {
        guard !isThemeEditor else { return nil }
        let arrangement = Arrangement(
            id: UUID().uuidString,
            name: "Arrangement \(arrangements.count + 1)",
            sectionIds: orderedSectionIds
        )
        updateDocument { presentation in
            presentation.arrangements = (presentation.arrangements ?? []) + [arrangement]
        }
        return arrangement
    }

    func deleteArrangement(_ id: String) {
        updateDocument { presentation in
            presentation.arrangements?.removeAll { $0.id == id }
            if presentation.defaultArrangementId == id { presentation.defaultArrangementId = nil }
        }
    }

    func updateArrangement(_ id: String, _ mutate: (inout Arrangement) -> Void) {
        updateDocument { presentation in
            guard let index = presentation.arrangements?.firstIndex(where: { $0.id == id }) else { return }
            mutate(&presentation.arrangements![index])
        }
    }

    func sectionName(_ id: String) -> String {
        sections.first { $0.id == id }?.name ?? "Deleted Section"
    }

    func arrangedSlideCount(_ arrangementID: String) -> Int {
        SlideSceneBuilder.arrangedSlides(for: presentation, arrangementId: arrangementID).count
    }

    var reflowSeedText: String {
        ChordProExport.reflowSeed(for: presentation)
    }

    func applyReflow(text: String, linesPerSlide: Int) {
        guard !isThemeEditor else { return }
        let built = Reflow.build(
            from: text, linesPerSlide: linesPerSlide,
            themeSlideName: Reflow.lyricDesign(of: presentation.slides))
        guard !built.slides.isEmpty else { return }
        selectedObjectIDs = []
        previewFrames = [:]
        activeGuides = []
        if isDraggingObjects { isDraggingObjects = false }
        updateDocument { presentation in
            presentation.slides = built.slides
            presentation.sections = built.sections

            presentation.arrangements = nil
            presentation.defaultArrangementId = nil
            presentation.reflowSource = text
        }
        if let first = presentation.slides.first { selectSlide(first.id) }
    }

    enum BackgroundScope: String, CaseIterable {
        case slide = "This Slide"
        case untilReplaced = "Until Replaced"
        case section = "This Section"
        case song = "Entire Song"
    }

    var availableBackgroundScopes: [BackgroundScope] {
        BackgroundScope.allCases.filter { $0 != .section || currentSlide?.sectionId != nil }
    }

    var effectiveBackground: CueMedia? {
        guard !isThemeEditor else { return nil }
        return currentSlide.flatMap {
            SlideSceneBuilder.effectiveBackground(slide: $0, presentation: presentation)
        }
    }

    var backgroundScope: BackgroundScope? {
        guard effectiveBackground != nil else { return nil }
        if let own = currentSlide?.background, !own.mediaId.isEmpty {
            return own.mode == .untilReplaced ? .untilReplaced : .slide
        }
        switch backgroundLocation {
        case .slide?: return .untilReplaced 
        case .section?: return .section
        case .song?: return .song
        case nil: return nil
        }
    }

    private typealias BackgroundLocation = SlideSceneBuilder.BackgroundSource

    private var backgroundLocation: BackgroundLocation? {
        guard !isThemeEditor, let slide = currentSlide else { return nil }
        return SlideSceneBuilder.backgroundSource(slide: slide, presentation: presentation)?.source
    }

    func setBackground(mediaID: String, scope: BackgroundScope = .slide) {
        guard !isThemeEditor, let slideID = selectedSlideID,
              let item = appModel.media(mediaID)
        else { return }
        var media = CueMedia.droppedOnSlide(for: item)

        media.mode = scope == .untilReplaced ? .untilReplaced : nil

        clearBackgroundDeclaration(unlessAt: scope, slideID: slideID)
        write(background: media, at: scope, slideID: slideID)
    }

    @discardableResult
    func setDroppedBackground(mediaID: String, onSlide slideID: String) -> Bool {
        guard !isThemeEditor, let media = droppableCueMedia(mediaID)
        else { return false }
        updateSlide(slideID) { $0.background = media }
        return true
    }

    @discardableResult
    func setDroppedBackground(mediaID: String, onSection sectionID: String) -> Bool {
        guard !isThemeEditor, var media = droppableCueMedia(mediaID)
        else { return false }

        media.mode = nil
        updateDocument { presentation in
            guard let index = presentation.sections?.firstIndex(where: { $0.id == sectionID })
            else { return }
            presentation.sections?[index].background = media
        }
        return true
    }

    private func droppableCueMedia(_ mediaID: String) -> CueMedia? {
        guard let item = appModel.media(mediaID)
        else { return nil }
        return CueMedia.droppedOnSlide(for: item)
    }

    func setCanvasSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        updateDocument { presentation in
            if width == Int(SlideSceneBuilder.canvasSize.width),
                height == Int(SlideSceneBuilder.canvasSize.height) {
                presentation.canvasWidth = nil
                presentation.canvasHeight = nil
            } else {
                presentation.canvasWidth = width
                presentation.canvasHeight = height
            }
        }
    }

    func setMusicKey(_ key: String?) {
        updateDocument { presentation in
            presentation.musicKey = key
            guard let key else {
                presentation.displayKey = nil
                return
            }
            if let display = presentation.displayKey,
               display.caseInsensitiveCompare(key) == .orderedSame {
                presentation.displayKey = nil
            }
        }
    }

    func setDisplayKey(_ key: String?) {
        updateDocument { presentation in
            guard let musicKey = presentation.musicKey else { return }
            if let key, key.caseInsensitiveCompare(musicKey) != .orderedSame {
                presentation.displayKey = key
            } else {
                presentation.displayKey = nil
            }
        }
    }

    @discardableResult
    func insertMediaSlide(mediaID: String, beforeSlideID: String?) -> Bool {
        guard !isThemeEditor,
            let item = appModel.media(mediaID)
        else { return false }
        let slide = Slide(
            id: UUID().uuidString, name: item.name, objects: [],
            background: CueMedia.droppedAsNewSlide(for: item))
        updateDocument { presentation in
            var inserted = slide
            let index = beforeSlideID.flatMap { id in
                presentation.slides.firstIndex { $0.id == id }
            } ?? presentation.slides.count
            let neighbor = index < presentation.slides.count
                ? presentation.slides[index] : presentation.slides.last
            inserted.sectionId = neighbor?.sectionId
            presentation.slides.insert(inserted, at: index)
        }
        return true
    }

    func removeBackground() {
        switch backgroundLocation {
        case .slide(let id)?:
            updateSlide(id) { $0.background = nil }
        case .section(let id)?:
            updateDocument { presentation in
                guard let index = presentation.sections?.firstIndex(where: { $0.id == id }) else { return }
                presentation.sections?[index].background = nil
            }
        case .song?:
            updateDocument { $0.background = nil }
        case nil:
            break
        }
    }

    func setBackgroundScope(_ scope: BackgroundScope) {
        guard scope != backgroundScope, var media = effectiveBackground,
              let slideID = selectedSlideID
        else { return }
        media.mode = scope == .untilReplaced ? .untilReplaced : nil
        removeBackground()
        write(background: media, at: scope, slideID: slideID)
    }

    private func write(background media: CueMedia, at scope: BackgroundScope, slideID: String) {
        switch scope {
        case .song:
            updateDocument { $0.background = media }
        case .section:
            guard let sectionId = currentSlide?.sectionId else { return }
            updateDocument { presentation in
                guard let index = presentation.sections?.firstIndex(where: { $0.id == sectionId })
                else { return }
                presentation.sections?[index].background = media
            }
        case .slide, .untilReplaced:
            updateSlide(slideID) { $0.background = media }
        }
    }

    private func clearBackgroundDeclaration(unlessAt scope: BackgroundScope, slideID: String) {
        switch backgroundLocation {
        case .slide(let id)? where !(id == slideID && (scope == .slide || scope == .untilReplaced)):
            updateSlide(id) { $0.background = nil }
        case .section(let id)? where scope != .section:
            updateDocument { presentation in
                guard let index = presentation.sections?.firstIndex(where: { $0.id == id }) else { return }
                presentation.sections?[index].background = nil
            }
        case .song? where scope != .song:
            updateDocument { $0.background = nil }
        default:
            break
        }
    }

    func updateBackground(_ mutate: (inout CueMedia) -> Void) {
        guard var background = effectiveBackground, let location = backgroundLocation else { return }
        let loopsBefore = backgroundLoops(background)
        mutate(&background)

        if backgroundLoops(background) != loopsBefore {
            render?.media.stop(id: background.mediaId)
            liveMediaIDs.remove(background.mediaId)
        }
        switch location {
        case .slide(let id):
            updateSlide(id) { $0.background = background }
        case .section(let id):
            updateDocument { presentation in
                guard let index = presentation.sections?.firstIndex(where: { $0.id == id }) else { return }
                presentation.sections?[index].background = background
            }
        case .song:
            updateDocument { $0.background = background }
        }
    }

    func renameCurrentSlide(_ name: String) {
        guard let slideID = selectedSlideID else { return }
        renameSlide(slideID, to: name)
    }

    func renameSlide(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isThemeEditor, trimmed.isEmpty { return }
        updateSlide(id) { $0.name = trimmed }
    }

    func backgroundLoops(_ background: CueMedia) -> Bool {
        background.loops ?? (appModel.media(background.mediaId)?.loops ?? true)
    }

    func fillLoops(_ object: SlideObject) -> Bool {
        object.fill?.loops
            ?? (appModel.media(object.fill?.mediaId ?? "")?.loops ?? true)
    }

    func backgroundMediaName(_ background: CueMedia) -> String {

        appModel.media(background.mediaId)?.name ?? "Missing media"
    }

    func carriedMedia(for slide: Slide) -> [LayerKind: String] {
        if isThemeEditor {
            [:]
        } else {
            SlideSceneBuilder.carriedMedia(for: slide, presentation: presentation) { [appModel] id in
                appModel.media(id).map { ($0.mediaKind, $0.classification) }
            }
        }
    }

    func declaredBackgroundName(for slide: Slide) -> String? {
        guard !isThemeEditor, let own = slide.background, !own.mediaId.isEmpty else { return nil }
        return backgroundMediaName(own)
    }

    func setSlideActions(_ actions: [SlideAction]) {
        guard let slideID = selectedSlideID else { return }
        updateSlide(slideID) { $0.actions = actions.isEmpty ? nil : actions }
    }

    func setAutoAdvance(_ advance: AutoAdvance?) {
        guard let slideID = selectedSlideID else { return }
        updateSlide(slideID) { $0.autoAdvance = advance }
    }

    func setSlideTransition(_ transition: Transition?) {
        guard let slideID = selectedSlideID else { return }
        updateSlide(slideID) { $0.transition = transition }
    }

    func updateSlide(_ slideID: String, _ mutate: (inout Slide) -> Void) {
        guard let slideIndex = presentation.slides.firstIndex(where: { $0.id == slideID }) else { return }
        let path = [AnyCodingKey("slides"), AnyCodingKey(UInt64(slideIndex))]
        do {
            switch host {
            case .presentation(let document):
                presentation = try document.update(\.slides[slideIndex], at: path, mutate)
            case .theme(let document):
                presentation = Self.mirror(of: try document.update(\.slides![slideIndex], at: path, mutate))
            case .overlay(let document):

                presentation = Self.mirror(of: try document.update { overlay in
                    var slide = Self.mirror(of: overlay).slides[0]
                    mutate(&slide)
                    overlay.objects = slide.objects
                    overlay.animationOrder = slide.animationOrder
                })
            case .confidenceLayout(let document):

                presentation = Self.mirror(of: try document.update { layout in
                    var slide = Self.mirror(of: layout).slides[0]
                    mutate(&slide)
                    layout.objects = slide.objects
                    layout.animationOrder = slide.animationOrder
                })
            }
            finishMutation()
        } catch {}
    }

    struct PathDrawing {
        var anchors: [PathAnchor] = []
        var provisional: PathAnchor?
        var hover: CGPoint?
    }

    struct PathEditing {
        let objectID: String
        var anchors: [PathAnchor]
        var closed: Bool
    }

    private(set) var pathDrawing: PathDrawing?
    private(set) var pathEditing: PathEditing?

    func beginPathDrawing() {

        guard !isMultiView else { return }
        endPathEditing()
        selectedObjectIDs = []
        pathDrawing = PathDrawing()
    }

    func cancelPathDrawing() {
        pathDrawing = nil
    }

    func pathDrawingSetProvisional(_ anchor: PathAnchor?) {
        pathDrawing?.provisional = anchor
    }

    func pathDrawingSetHover(_ point: CGPoint?) {
        guard pathDrawing != nil, pathDrawing?.hover != point else { return }
        pathDrawing?.hover = point
    }

    func pathDrawingCommit(_ anchor: PathAnchor) {
        pathDrawing?.anchors.append(anchor)
        pathDrawing?.provisional = nil
    }

    func pathDrawingRemoveLast() {
        guard pathDrawing?.anchors.isEmpty == false else { return }
        pathDrawing?.anchors.removeLast()
    }

    func finishPathDrawing(closed: Bool) {
        guard let drawing = pathDrawing else { return }
        pathDrawing = nil
        guard drawing.anchors.count >= 2,
              let encoded = PathAnchorCodec.encode(anchors: drawing.anchors, closed: closed)
        else { return }
        add(SlideObject(
            id: UUID().uuidString, objectKind: .shape, name: "Path", text: "",
            x: encoded.frame.origin.x, y: encoded.frame.origin.y,
            width: encoded.frame.width, height: encoded.frame.height,
            shapeKind: .path,
            pathData: encoded.pathData,
            fill: ObjectFill(fillKind: .solid, colorHex: "#4A90D9FF")
        ))
    }

    func canEditPath(_ object: SlideObject) -> Bool {
        guard object.objectKind == .shape, object.shapeKind == .path,
              let data = object.pathData
        else { return false }
        return PathAnchorCodec.parse(data, in: displayFrame(for: object)) != nil
    }

    func beginPathEditing(_ objectID: String) {
        guard let object = object(id: objectID),
              object.shapeKind == .path,
              let data = object.pathData,
              let parsed = PathAnchorCodec.parse(data, in: displayFrame(for: object))
        else { return }
        pathDrawing = nil
        selectedObjectIDs = [objectID]
        pathEditing = PathEditing(objectID: objectID, anchors: parsed.anchors, closed: parsed.closed)
    }

    func pathEditingUpdate(anchors: [PathAnchor]) {
        guard var editing = pathEditing else { return }
        editing.anchors = anchors
        pathEditing = editing
        guard let encoded = PathAnchorCodec.encode(anchors: anchors, closed: editing.closed)
        else { return }
        updateObject(id: editing.objectID) { object in
            object.pathData = encoded.pathData
            object.x = encoded.frame.origin.x
            object.y = encoded.frame.origin.y
            object.width = encoded.frame.width
            object.height = encoded.frame.height
        }
    }

    func endPathEditing() {
        pathEditing = nil
    }

    var screenSourceChoices: [(id: String, name: String)] {
        guard let render else { return [] }
        return PreviewTargets.screens(render)
    }

    var multiViewTree: MultiViewTree? {
        _ = presentation
        if case .confidenceLayout(let document) = host {
            return document.value.multiView
        } else {
            return nil
        }
    }

    var isMultiView: Bool { multiViewTree != nil }

    private(set) var selectedTileID: String?

    var selectedTile: MultiViewNode? {
        if let selectedTileID, let tree = multiViewTree {
            MultiViewTiles.node(selectedTileID, in: tree)
        } else {
            nil
        }
    }

    func selectTile(_ id: String?) {
        selectedTileID = id
        setSelection([])
    }

    private func makeMultiViewContext(for tree: MultiViewTree) -> MultiViewTiles.Context {
        let screens = screenSourceChoices
        var aspects: [String: Double] = [:]
        if let render {
            for screen in screens {
                aspects["screen::" + screen.id] = Double(PreviewTargets.aspect(of: screen.id, render: render))
            }
        }

        var names: [String: String] = [:]
        for choice in LiveInputCatalog.choices {
            names["input::" + choice.id] = choice.name
        }
        for mediaID in tree.nodes.compactMap(\.mediaId) {
            names["media::" + mediaID] = appModel.entry(mediaID)?.name
        }
        return MultiViewTiles.Context(
            screens: screens.map { .init(id: $0.id, name: $0.name) }, aspects: aspects, names: names)
    }

    private struct MultiViewSnapshot {
        var tree: MultiViewTree
        var canvas: CGSize
        var context: MultiViewTiles.Context
        var tiles: [MultiViewTiles.PlacedTile]
        var dividers: [MultiViewTiles.Divider]
    }

    @ObservationIgnored private var multiViewSnapshotCache: MultiViewSnapshot?

    private var multiViewSnapshot: MultiViewSnapshot? {
        if let tree = multiViewTree {
            let canvas = canvasSize
            if multiViewSnapshotCache?.tree != tree || multiViewSnapshotCache?.canvas != canvas {
                let context = makeMultiViewContext(for: tree)
                let placed = MultiViewTiles.layout(
                    tree, canvasWidth: Int(canvas.width), canvasHeight: Int(canvas.height), context: context)
                multiViewSnapshotCache = MultiViewSnapshot(
                    tree: tree, canvas: canvas, context: context,
                    tiles: placed.tiles, dividers: placed.dividers)
            }
        } else {
            multiViewSnapshotCache = nil
        }
        return multiViewSnapshotCache
    }

    var multiViewContext: MultiViewTiles.Context {
        multiViewSnapshot?.context ?? MultiViewTiles.Context()
    }

    var multiViewLayout: (tiles: [MultiViewTiles.PlacedTile], dividers: [MultiViewTiles.Divider])? {
        multiViewSnapshot.map { ($0.tiles, $0.dividers) }
    }

    func updateMultiView(_ transform: (MultiViewTree) -> MultiViewTree) {
        if case .confidenceLayout(let document) = host, let tree = document.value.multiView {

            let next = transform(tree)
            let context = makeMultiViewContext(for: next)
            do {
                presentation = Self.mirror(of: try document.update { layout in
                    layout.multiView = next
                    layout.regenerateMultiViewObjects(context: context)
                })
                finishMutation()
            } catch {}
        }
    }

    func updateSelectedTile(_ mutate: (inout MultiViewNode) -> Void) {
        if let selectedTileID {
            updateMultiView { MultiViewTiles.update($0, tile: selectedTileID, mutate) }
        }
    }

    func splitSelectedTile(_ axis: MultiViewSplitAxis) {
        if let selectedTileID {
            updateMultiView { MultiViewTiles.split($0, tile: selectedTileID, axis: axis) }
        }
    }

    func quadSelectedTile() {
        if let selectedTileID {
            updateMultiView { MultiViewTiles.quad($0, tile: selectedTileID) }
        }
    }

    func mergeSelectedTile() {
        if let selectedTileID {
            updateMultiView { MultiViewTiles.merge($0, tile: selectedTileID) }
        }
    }

    var canMergeSelectedTile: Bool {
        if let selectedTileID, let tree = multiViewTree {
            MultiViewTiles.canMerge(tree, tile: selectedTileID)
        } else {
            false
        }
    }

    func applyMultiViewGrid(columns: Int, rows: Int) {
        selectTile(nil)
        updateMultiView { _ in MultiViewTiles.grid(columns: columns, rows: rows) }
    }

    func previewDivider(_ divider: MultiViewTiles.Divider, to position: Double) {
        if let tree = multiViewTree {
            let moved = MultiViewTiles.moveDivider(tree, divider, to: position)
            let objects = MultiViewTiles.objects(
                for: moved, canvasWidth: Int(canvasSize.width), canvasHeight: Int(canvasSize.height),
                context: multiViewContext)
            var frames: [String: CGRect] = [:]
            for object in objects {
                frames[object.id] = CGRect(
                    x: object.x ?? 0, y: object.y ?? 0,
                    width: object.width ?? 0, height: object.height ?? 0)
            }
            previewDrag(frames: frames, guides: [])
        }
    }

    func commitDivider(_ divider: MultiViewTiles.Divider, to position: Double) {
        cancelDrag()
        updateMultiView { MultiViewTiles.moveDivider($0, divider, to: position) }
    }

    var multiViewIsTall: Bool {
        if case .confidenceLayout(let document) = host {
            document.value.isTallCanvas
        } else {
            false
        }
    }

    func duplicateMultiViewTurned() -> String? {
        if case .confidenceLayout(let document) = host,
           let copy = document.value.multiViewTurnedCopy(context: multiViewContext) {
            appModel.createLayout(copy, besideID: document.value.id)
        } else {
            nil
        }
    }

    func unlockMultiViewTiles() {
        if case .confidenceLayout(let document) = host {
            selectedTileID = nil
            do {
                presentation = Self.mirror(of: try document.update { $0.unlockTiles() })
                finishMutation()
            } catch {}
        }
    }

    func updateObject(id: String, _ rawMutate: (inout SlideObject) -> Void) {
        func mutate(_ object: inout SlideObject) {
            object = SlideObjectNormalization.normalized(object)
            rawMutate(&object)
        }

        if scrubPreviewActive {
            guard var object = scrubPreviewOverrides[id] ?? object(id: id) else { return }
            mutate(&object)
            scrubPreviewOverrides[id] = object
            refreshScene()
            return
        }
        guard let slideIndex = currentSlideIndex,
              let objectIndex = presentation.slides[slideIndex].objects.firstIndex(where: { $0.id == id })
        else { return }
        if !bypassStateRedirect, let editing = animationStateEditing, editing.objectID == id {

            let real = presentation.slides[slideIndex].objects[objectIndex]
            var working = editing.state
            working.id = id
            working.animationSteps = real.animationSteps
            mutate(&working)
            let animationSteps = working.animationSteps
            working.animationSteps = nil
            updateObject(slideIndex: slideIndex, objectIndex: objectIndex) { object in
                object.animationSteps = animationSteps
                guard var steps = object.animationSteps,
                      let stepIndex = steps.firstIndex(where: { $0.id == editing.stepID }) else { return }
                if editing.isStart { steps[stepIndex].fromObject = working } else { steps[stepIndex].toObject = working }
                object.animationSteps = steps
            }
            return
        }
        updateObject(slideIndex: slideIndex, objectIndex: objectIndex, mutate)
    }

    func updateObjects(ids: Set<String>, _ rawMutate: (inout SlideObject) -> Void) {
        func mutate(_ object: inout SlideObject) {
            object = SlideObjectNormalization.normalized(object)
            rawMutate(&object)
        }
        if ids.count == 1, let id = ids.first {
            updateObject(id: id, rawMutate)
        } else if scrubPreviewActive {
            for id in ids {
                if var object = scrubPreviewOverrides[id] ?? object(id: id) {
                    mutate(&object)
                    scrubPreviewOverrides[id] = object
                }
            }
            refreshScene()
        } else if let slideIndex = currentSlideIndex {
            updateDocument { presentation in
                for index in presentation.slides[slideIndex].objects.indices
                where ids.contains(presentation.slides[slideIndex].objects[index].id) {
                    mutate(&presentation.slides[slideIndex].objects[index])
                }
            }
        }
    }

    private(set) var scrubPreviewActive = false
    private var scrubPreviewOverrides: [String: SlideObject] = [:]

    func setScrubPreview(_ active: Bool) {
        guard active != scrubPreviewActive else { return }
        scrubPreviewActive = active
        if !active {
            scrubPreviewOverrides = [:]
            refreshScene()
        }
    }

    func quickEditText(slideID: String, objectID: String, text: String) {
        guard let slideIndex = presentation.slides.firstIndex(where: { $0.id == slideID }),
              let objectIndex = presentation.slides[slideIndex].objects
                  .firstIndex(where: { $0.id == objectID })
        else { return }
        updateObject(slideIndex: slideIndex, objectIndex: objectIndex) { $0.text = text }
    }

    private func updateObject(slideIndex: Int, objectIndex: Int, _ mutate: (inout SlideObject) -> Void) {
        let path = [
            AnyCodingKey("slides"), AnyCodingKey(UInt64(slideIndex)),
            AnyCodingKey("objects"), AnyCodingKey(UInt64(objectIndex)),
        ]
        do {
            switch host {
            case .presentation(let document):
                presentation = try document
                    .update(\.slides[slideIndex].objects[objectIndex], at: path, mutate)
            case .theme(let document):
                presentation = Self.mirror(
                    of: try document.update(\.slides![slideIndex].objects[objectIndex], at: path, mutate)
                )
            case .overlay(let document):

                presentation = Self.mirror(
                    of: try document.update(
                        \.objects[objectIndex],
                        at: [AnyCodingKey("objects"), AnyCodingKey(UInt64(objectIndex))],
                        mutate
                    )
                )
            case .confidenceLayout(let document):
                presentation = Self.mirror(
                    of: try document.update(
                        \.objects[objectIndex],
                        at: [AnyCodingKey("objects"), AnyCodingKey(UInt64(objectIndex))],
                        mutate
                    )
                )
            }
            finishMutation()
        } catch {}
    }

    private func updateDocument(_ mutate: (inout Presentation) -> Void) {
        let before = presentation.slides.map(\.id)
        do {
            switch host {
            case .presentation(let document):
                presentation = try document.updateDeck(mutate)
                noteWholeWrite(document)
            case .theme(let document):
                presentation = Self.mirror(of: try document.update { theme in
                    var mirror = Self.mirror(of: theme)
                    mutate(&mirror)
                    theme.slides = mirror.slides
                })
            case .overlay(let document):
                presentation = Self.mirror(of: try document.update { overlay in
                    var mirror = Self.mirror(of: overlay)
                    mutate(&mirror)
                    overlay.objects = mirror.slides.first?.objects ?? []
                })
            case .confidenceLayout(let document):
                presentation = Self.mirror(of: try document.update { layout in

                    var mirror = Self.mirror(of: layout)
                    mutate(&mirror)
                    layout.adopt(editorMirror: mirror)
                    layout.regenerateMultiViewObjects(context: multiViewContext)
                })
            }
            finishMutation()
        } catch {}
    }

    func undo() {
        let before = presentation.slides.map(\.id)
        switch host {
        case .presentation(let document):
            guard let value = try? document.undo() else { return }
            presentation = value
            noteWholeWrite(document)
        case .theme(let document):
            guard let value = try? document.undo() else { return }
            presentation = Self.mirror(of: value)
        case .overlay(let document):
            guard let value = try? document.undo() else { return }
            presentation = Self.mirror(of: value)
        case .confidenceLayout(let document):
            guard let value = try? document.undo() else { return }
            presentation = Self.mirror(of: value)
        }
        reconcileAfterHistoryChange()
    }

    func redo() {
        let before = presentation.slides.map(\.id)
        switch host {
        case .presentation(let document):
            guard let value = try? document.redo() else { return }
            presentation = value
            noteWholeWrite(document)
        case .theme(let document):
            guard let value = try? document.redo() else { return }
            presentation = Self.mirror(of: value)
        case .overlay(let document):
            guard let value = try? document.redo() else { return }
            presentation = Self.mirror(of: value)
        case .confidenceLayout(let document):
            guard let value = try? document.redo() else { return }
            presentation = Self.mirror(of: value)
        }
        reconcileAfterHistoryChange()
    }

    private func noteWholeWrite(_ document: EditorReplica<Presentation>) {
        if let reason = document.wholeWrite {
            DiagnosticsStore.shared.note("editor.wholeWrite", detail: "reason=\(reason)")
        }
    }

    private func reconcileAfterHistoryChange() {
        if !presentation.slides.contains(where: { $0.id == selectedSlideID }) {
            selectedSlideID = presentation.slides.first?.id
        }
        let livingSlides = Set(presentation.slides.map(\.id))
        if !selectedSlideIDs.isSubset(of: livingSlides) {
            selectedSlideIDs.formIntersection(livingSlides)
        }
        let living = Set(currentSlide?.objects.map(\.id) ?? [])
        selectedObjectIDs = selectedObjectIDs.intersection(living)
        finishMutation()
    }

    private func finishMutation() {

        defer {

            switch host {
            case .presentation(let document):
                appModel.noteEditorSave(of: .presentation, id: document.value.id, value: document.value)
            case .theme(let document):
                appModel.noteEditorSave(of: .theme, id: document.value.id, value: document.value)

                appModel.noteDecksRestyled()
            case .overlay(let document):
                appModel.noteEditorSave(of: .overlay, id: document.value.id, value: document.value)
            case .confidenceLayout(let document):
                appModel.noteEditorSave(of: .confidenceLayout, id: document.value.id, value: document.value)
            }
        }
        switch host {
        case .presentation(let document): commit(document)
        case .theme(let document): commit(document)
        case .overlay(let document): commit(document)
        case .confidenceLayout(let document): commit(document)
        }
        adoptHostValue()
    }

    private func commit<E: DocumentEntity>(_ document: EditorReplica<E>) {
        let heads = SyncLedger.hex(document.heads())
        if heads != lastCommitted, let changes = try? document.encodeChangesSince(heads: SyncLedger.heads(lastCommitted)) {
            appModel.client.commit(E.self, id: document.value.id, changes: changes, token: token)
            lastCommitted = heads
        }
    }

    private func take(_ change: DocumentChange) {
        switch landing(change) {
        case .applied(moved: true):
            adoptLanded()
        case .applied(moved: false):
            break
        case .refused:
            checkOutAgain()
        }
    }

    private func landing(_ change: DocumentChange) -> EditorLanding {
        switch host {
        case .presentation(let replica): Self.landing(change, on: replica)
        case .theme(let replica): Self.landing(change, on: replica)
        case .overlay(let replica): Self.landing(change, on: replica)
        case .confidenceLayout(let replica): Self.landing(change, on: replica)
        }
    }

    private static func landing<E: DocumentEntity>(_ change: DocumentChange, on replica: EditorReplica<E>) -> EditorLanding {
        if change.value == nil || holds(change.heads, in: replica) {
            .applied(moved: false)
        } else if let bundle = change.bundle {
            replica.applyLanded(bundle)
        } else {
            .refused
        }
    }

    private static func holds<E: DocumentEntity>(_ heads: [String]?, in replica: EditorReplica<E>) -> Bool {
        if let heads {
            replica.contains(heads: SyncLedger.heads(heads))
        } else {
            false
        }
    }

    private func checkOutAgain() {
        inbox.hold()
        switch host {
        case .presentation: requestCheckout(Presentation.self)
        case .theme: requestCheckout(Theme.self)
        case .overlay: requestCheckout(Overlay.self)
        case .confidenceLayout: requestCheckout(ConfidenceLayout.self)
        }
    }

    private func requestCheckout<E: DocumentEntity>(_ type: E.Type) {
        let client = appModel.client
        let id = inbox.key.id
        headsAtRequest = hostHeads
        Task { [weak self] in
            let fresh = try? await client.checkout(type, id: id, history: .fresh)
            if let self {
                self.checkedOut(fresh)
            } else if let fresh {
                client.release(token: fresh.token)
            }
        }
    }

    private func checkedOut<E: DocumentEntity>(_ fresh: EditorCheckout<E>?) {
        if let fresh, !sessionEnded {
            let replay = inbox.held(after: fresh.sequence)
            if replay.allSatisfy({ replays($0, on: fresh.replica) }), carry(onto: fresh.replica), let next = Host(fresh.replica) {
                let previous = token
                host = next
                token = fresh.token
                lastCommitted = SyncLedger.hex(fresh.replica.heads())
                appModel.client.release(token: previous)
                inbox.resume()
                adoptLanded()
            } else {
                appModel.client.release(token: fresh.token)
                checkOutAgain()
            }
        } else {
            if let fresh {
                appModel.client.release(token: fresh.token)
            }
            inbox.resume()
        }
    }

    private func replays<E: DocumentEntity>(_ change: DocumentChange, on fork: EditorReplica<E>) -> Bool {
        if let bundle = change.bundle, change.value != nil, hostHolds(change.heads) {
            (try? fork.absorb(bundle.changes)) != nil && Self.holds(change.heads, in: fork)
        } else {
            Self.landing(change, on: fork) != .refused
        }
    }

    private func carry<E: DocumentEntity>(onto fork: EditorReplica<E>) -> Bool {
        if Self.holds(headsAtRequest, in: fork) {
            (try? fork.absorb(editsSinceRequest())) != nil && Self.holds(hostHeads, in: fork)
        } else {
            true
        }
    }

    private func editsSinceRequest() throws -> Data {
        let requested = SyncLedger.heads(headsAtRequest)
        return switch host {
        case .presentation(let replica): try replica.encodeChangesSince(heads: requested)
        case .theme(let replica): try replica.encodeChangesSince(heads: requested)
        case .overlay(let replica): try replica.encodeChangesSince(heads: requested)
        case .confidenceLayout(let replica): try replica.encodeChangesSince(heads: requested)
        }
    }

    private var hostHeads: [String] {
        switch host {
        case .presentation(let replica): SyncLedger.hex(replica.heads())
        case .theme(let replica): SyncLedger.hex(replica.heads())
        case .overlay(let replica): SyncLedger.hex(replica.heads())
        case .confidenceLayout(let replica): SyncLedger.hex(replica.heads())
        }
    }

    private func hostHolds(_ heads: [String]?) -> Bool {
        switch host {
        case .presentation(let replica): Self.holds(heads, in: replica)
        case .theme(let replica): Self.holds(heads, in: replica)
        case .overlay(let replica): Self.holds(heads, in: replica)
        case .confidenceLayout(let replica): Self.holds(heads, in: replica)
        }
    }

    private func adoptLanded() {
        adoptHostValue()
        if let id = selectedSlideID, !presentation.slides.contains(where: { $0.id == id }),
           let first = presentation.slides.first?.id {
            selectSlide(first)
        }
    }

    private func adoptHostValue() {
        switch host {
        case .presentation(let document):
            presentation = document.value
            canUndo = document.canUndo
            canRedo = document.canRedo
        case .theme(let document):
            presentation = Self.mirror(of: document.value)
            canUndo = document.canUndo
            canRedo = document.canRedo
        case .overlay(let document):
            presentation = Self.mirror(of: document.value)
            canUndo = document.canUndo
            canRedo = document.canRedo
        case .confidenceLayout(let document):
            presentation = Self.mirror(of: document.value)
            canUndo = document.canUndo
            canRedo = document.canRedo
        }

        let living = Set(presentation.slides.map(\.id))
        if !selectedSlideIDs.isSubset(of: living) {
            selectedSlideIDs.formIntersection(living)
        }
        refreshScene()
    }

    @MainActor
    private final class LandingInbox {
        let key: SyncLedger.Key
        private let observers: LibraryBatchObservers
        private var observer: LibraryBatchObservers.Token?
        private weak var model: SlideEditorModel?

        private var holding = true
        private var waiting: [(sequence: Int, change: DocumentChange)] = []

        init(observers: LibraryBatchObservers, kind: DocumentKind, id: String) {
            key = SyncLedger.Key(kind: kind, id: id)
            self.observers = observers
            observer = observers.add { [weak self] batch in self?.hear(batch) }
        }

        private func hear(_ batch: LibraryBatch) {
            for change in batch.changes where change.key == key {
                deliver(batch.sequence, change)
            }
        }

        private func deliver(_ sequence: Int, _ change: DocumentChange) {
            if !holding, let model {
                model.take(change)
            } else {
                waiting.append((sequence, change))
            }
        }

        func open(for model: SlideEditorModel, after sequence: Int) {
            self.model = model
            let replay = held(after: sequence)
            resume()
            for change in replay {
                deliver(sequence, change)
            }
        }

        func hold() {
            holding = true
        }

        func held(after sequence: Int) -> [DocumentChange] {
            waiting.filter { $0.sequence > sequence }.map(\.change)
        }

        func resume() {
            waiting = []
            holding = false
        }

        func close() {
            if let observer {
                observers.remove(observer)
            }
            observer = nil
            model = nil
            resume()
        }
    }

    private static let editorMediaPrefix = "edit::"

    private func insertRestingGhost(into slide: inout Slide) {
        guard let editing = animationStateEditing, let raw = documentSlide,
              let real = raw.objects.first(where: { $0.id == editing.objectID }),
              let index = slide.objects.firstIndex(where: { $0.id == editing.objectID })
        else { return }
        var ghost = real
        ghost.id = editing.objectID + "#ghost"
        ghost.name = real.name + " (resting)"
        ghost.opacity = (real.opacity ?? 1) * 0.3
        ghost.animationSteps = nil
        ghost.maskObjectId = nil
        ghost.effects = nil
        slide.objects.insert(ghost, at: index)
    }

    func refreshScene() {
        guard let render else { return }

        let previewing = animationPreviewPlaying || (animationPreviewTime != nil && animationStateEditing == nil)
        guard var slide = previewing ? documentSlide : currentSlide else {
            render.scene = RenderScene(canvasSize: canvasSize)
            return
        }

        if !scrubPreviewOverrides.isEmpty {
            for index in slide.objects.indices {
                if let override = scrubPreviewOverrides[slide.objects[index].id] {
                    slide.objects[index] = override
                }
            }
        }
        render.scene = editorScene(for: slide, restingGhost: !previewing)
        syncMedia(for: slide)
        refreshClippedTextWarnings()
    }

    private func editorScene(for slide: Slide, restingGhost: Bool) -> RenderScene {
        var slide = slide

        slide.objects = EmptyTextPlaceholder.applied(to: slide.objects, editingID: canvasTextEditID)

        if motionPausedForEditing {
            for index in slide.objects.indices
            where selectedObjectIDs.contains(slide.objects[index].id) {
                var style = slide.objects[index].textStyle ?? TextStyle()
                style.tickerSpeed = 0
                style.scroll = nil
                slide.objects[index].textStyle = style
            }
        }

        if restingGhost { insertRestingGhost(into: &slide) }

        slide.objects = LinkedText.previewObjects(slide.objects)

        var shownPresentation = presentation
        if showsChords {
            slide.objects = ChordEditing.revealed(slide.objects)
            shownPresentation.displayKey = nil
        }
        var scene = SlideSceneBuilder.scene(
            for: slide, theme: theme, presentation: shownPresentation,
            showThemeDecor: showsThemeContent,
            animationContext: animationPreviewContext(for: slide),
            carriedMedia: carriedMedia(for: slide)
        ).applyingMediaEffects {
            appModel.mediaSceneEffects(id: $0)
        }.remappingMediaIDs {

            LiveInputPlaceholder.remap($0) ?? (Self.editorMediaPrefix + $0)
        }

        insertPushStandIn(into: &scene, slide: slide)
        return scene
    }

    private(set) var clippedTextObjectIDs: Set<String> = []

    private(set) var clippedSlideIDs: Set<String> = []

    private func refreshClippedTextWarnings() {
        guard let slide = currentSlide else {
            clippedTextObjectIDs = []
            return
        }
        let clipped = SlideSceneBuilder.clippedTextObjectIDs(
            for: slide, theme: theme, presentation: presentation
        )
        clippedTextObjectIDs = Set(clipped)
        if clipped.isEmpty {
            clippedSlideIDs.remove(slide.id)
        } else {
            clippedSlideIDs.insert(slide.id)
        }
    }

    func sweepClippedTextWarnings() {
        guard case .presentation = host else { return }
        let presentation = presentation
        let theme = theme
        Task.detached(priority: .utility) {
            var clipped: Set<String> = []
            for slide in presentation.slides
            where !SlideSceneBuilder.clippedTextObjectIDs(
                for: slide, theme: theme, presentation: presentation
            ).isEmpty {
                clipped.insert(slide.id)
            }
            await MainActor.run { [weak self] in
                guard let self, self.presentation.slides.map(\.id) == presentation.slides.map(\.id)
                else { return }
                self.clippedSlideIDs = clipped
            }
        }
    }

    private func syncMedia(for slide: Slide) {
        guard let render else { return }

        var wanted = Set(slide.objects.compactMap(SlideSceneBuilder.fillMediaID))

        if let template = SlideSceneBuilder.themeSlide(for: slide, theme: theme) {
            wanted.formUnion(template.objects.compactMap(SlideSceneBuilder.fillMediaID))
        }

        if let background = SlideSceneBuilder.effectiveBackground(slide: slide, presentation: presentation) {
            wanted.insert(background.mediaId)
        }

        wanted.formUnion(carriedMedia(for: slide).values)

        for id in liveMediaIDs.subtracting(wanted) {
            render.media.stop(id: Self.editorMediaPrefix + id)
        }
        let added = wanted.subtracting(liveMediaIDs)
        liveMediaIDs = wanted
        guard !added.isEmpty, let blobs else { return }
        Task { [appModel] in
            for mediaID in added {
                guard let item = appModel.media(mediaID)
                else { continue }
                let editorID = Self.editorMediaPrefix + mediaID
                switch item.mediaKind {
                case .video:

                    if let poster = await ThumbnailStore.shared.poster(for: item, blobs: blobs) {
                        _ = try? await render.media.showStill(
                            image: poster,
                            cacheKey: "\(item.id)|\(item.fileHash)|\(item.inPoint ?? 0)",
                            id: editorID)
                    }
                case .image:
                    guard let url = blobs.url(forHash: item.fileHash) else { continue }
                    _ = try? await render.media.showStill(url: url, id: editorID)
                }
            }
        }
    }
}

enum ObjectPasteboard {
    static let type = NSPasteboard.PasteboardType(EditorPaste.objectsType)

    struct Payload: Codable {
        var objects: [SlideObject]
        var sourceSlideID: String
    }

    static func copy(_ objects: [SlideObject], from slideID: String) {
        guard let data = try? JSONEncoder().encode(Payload(objects: objects, sourceSlideID: slideID))
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: type)
    }

    static var hasObjects: Bool {
        NSPasteboard.general.data(forType: type) != nil
    }

    static func paste() -> Payload? {
        guard let data = NSPasteboard.general.data(forType: type),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.objects.isEmpty
        else { return nil }
        return payload
    }
}
