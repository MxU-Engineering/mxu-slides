import AppKit
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct EditorInteractionView: NSViewRepresentable {
    let model: SlideEditorModel

    func makeNSView(context: Context) -> EditorInteractionNSView {
        EditorInteractionNSView(model: model)
    }

    func updateNSView(_ nsView: EditorInteractionNSView, context: Context) {

        nsView.syncTextOverlay()
        nsView.needsDisplay = true
    }
}

@MainActor
final class EditorInteractionNSView: NSView {
    private let model: SlideEditorModel

    private enum Drag {

        case move(origin: CGPoint, originalFrames: [String: CGRect])
        case resize(handle: EditorGeometry.Handle, origin: CGPoint, originalFrame: CGRect, objectID: String)

        case marquee(origin: CGPoint, base: Set<String>)

        case divider(MultiViewTiles.Divider, position: Double)
    }

    private var drag: Drag?
    private var dragMoved = false

    private var marqueeBand: CGRect?

    private var marqueeSelection: Set<String>?

    var marqueeViewRect: CGRect? { marqueeBand.map(viewRect(fromScene:)) }

    weak var margin: NSView?

    var takesMarginPress: Bool { model.pathDrawing == nil }

    private var penDownPoint: CGPoint?
    private enum PenEditTarget {
        case anchor(Int)
        case handleIn(Int)
        case handleOut(Int)
    }
    private var penEditDrag: PenEditTarget?

    private var textOverlay: OverlayTextView?
    private var overlayObjectID: String?

    var chordState = ChordCanvasState()

    init(model: SlideEditorModel) {
        self.model = model
        super.init(frame: .zero)
        armObservation()
    }

    private func armObservation() {
        withObservationTracking {
            _ = model.presentation
            _ = model.selectedObjectIDs
            _ = model.previewFrames
            _ = model.activeGuides
            _ = model.canvasTextEditID
            _ = model.scrubPreviewActive
            if let id = model.canvasTextEditID {
                _ = model.previewedObject(id: id) 
                _ = model.canvasTextEditTarget 
            }
            _ = model.inspectorTextFocused
            _ = model.pathDrawing
            _ = model.pathEditing
            _ = model.showsChords
            _ = model.selectedSlideID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncTextOverlay()
                self.syncChordState()
                self.needsDisplay = true
                self.armObservation()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorInteractionNSView does not support NSCoder")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func syncTextOverlay() {
        let editID = model.canvasTextEditID
        if editID != overlayObjectID {
            tearDownOverlay()
            if let editID, let object = model.object(id: editID) {
                createOverlay(for: object)
            }
        }
        guard let overlay = textOverlay, let id = overlayObjectID else { return }

        guard let object = model.previewedObject(id: id), let target = model.canvasTextEditTarget else {
            model.endCanvasTextEdit()
            tearDownOverlay()
            return
        }
        let frame = viewRect(fromScene: target.frame)
        if overlay.frame != frame { overlay.frame = frame }
        overlay.sceneScale = sceneScale

        if overlay.editLayoutKey?.text != target.text || overlay.editLayoutKey?.size != target.frame.size {
            overlay.editLayoutKey = (target.text, target.frame.size)
            overlay.editLayout = TextEditLayout(text: target.text, sceneFrame: target.frame.size)
        }

        overlay.perspective = overlayHomography(for: object, frame: frame)
    }

    private func overlayHomography(for object: SlideObject, frame: CGRect) -> EditorGeometry.Homography? {
        let canvasView = viewRect(fromScene: CGRect(origin: .zero, size: model.canvasSize))
        guard let corners = EditorGeometry.perspectiveCorners(
            frame: frame, object: object, canvasSize: canvasView.size
        ) else { return nil }

        let local = corners.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
        return EditorGeometry.Homography(from: CGRect(origin: .zero, size: frame.size), to: local)
    }

    private func createOverlay(for object: SlideObject) {
        let styled = model.canvasTextEditStyle
        let frame = viewRect(fromScene: model.canvasTextEditTarget?.frame ?? model.displayFrame(for: object))
        let overlay = OverlayTextView(frame: frame)

        overlay.onFormatKey = { [weak self] key in
            guard let model = self?.model,
                  (model.canvasTextSelection?.length ?? 0) > 0 else { return false }
            switch key {
            case .bold: model.toggleSelectionBold()
            case .italic: model.toggleSelectionItalic()
            case .underline: model.toggleSelectionUnderline()
            }
            return true
        }
        overlay.onPasteWithFormatting = { [weak self, weak overlay] attributed in
            guard let self, let overlay, overlayObjectID != nil else { return false }
            let selection = overlay.selectedRange()

            overlay.insertText(attributed.string, replacementRange: selection)
            model.applyPastedFormatting(attributed, atUTF16: selection.location)
            return true
        }
        overlay.isRichText = false
        overlay.drawsBackground = false
        overlay.allowsUndo = false 
        overlay.textContainerInset = .zero
        overlay.isVerticallyResizable = false
        overlay.isHorizontallyResizable = false

        overlay.textColor = .clear
        overlay.insertionPointColor = .clear
        overlay.selectedTextAttributes = [.backgroundColor: NSColor.clear, .foregroundColor: NSColor.clear]
        overlay.markedTextAttributes = [.foregroundColor: NSColor.clear]
        if let color = styled?.color {
            overlay.caretColor = NSColor(
                srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha
            )
        }
        overlay.sceneScale = sceneScale
        if let target = model.canvasTextEditTarget {
            overlay.editLayoutKey = (target.text, target.frame.size)
            overlay.editLayout = TextEditLayout(text: target.text, sceneFrame: target.frame.size)
        }
        overlay.string = object.text

        overlay.delegate = self
        addSubview(overlay)
        window?.makeFirstResponder(overlay)

        overlay.setSelectedRange(NSRange(location: (object.text as NSString).length, length: 0))

        textOverlay = overlay
        overlayObjectID = object.id
    }

    private func tearDownOverlay() {
        guard let overlay = textOverlay else {
            overlayObjectID = nil
            return
        }
        overlay.delegate = nil
        overlay.removeFromSuperview()
        textOverlay = nil
        overlayObjectID = nil
    }

    private func endCanvasEditing() {
        guard model.canvasTextEditID != nil || textOverlay != nil else { return }
        model.endCanvasTextEdit()
        tearDownOverlay()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        syncTextOverlay()
    }

    private var sceneScale: CGFloat {
        EditorGeometry.letterbox(
            canvas: model.canvasSize, in: bounds.size, inset: EditorGeometry.pasteboardInset).scale
    }

    private var sceneOrigin: CGPoint {
        EditorGeometry.letterbox(
            canvas: model.canvasSize, in: bounds.size, inset: EditorGeometry.pasteboardInset).origin
    }

    private func scenePoint(fromView point: CGPoint) -> CGPoint {
        let origin = sceneOrigin
        let scale = sceneScale
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    private func viewPoint(fromScene point: CGPoint) -> CGPoint {
        let origin = sceneOrigin
        let scale = sceneScale
        return CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    private func viewRect(fromScene rect: CGRect) -> CGRect {
        let topLeft = viewPoint(fromScene: rect.origin)
        let scale = sceneScale
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width * scale, height: rect.height * scale)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewLocal = convert(event.locationInWindow, from: nil)
        let point = scenePoint(fromView: viewLocal)
        guard let objects = model.currentSlide?.objects else { return }

        let inView = bounds.contains(viewLocal)

        if let layout = model.multiViewLayout {
            let tolerance = Double(sceneScale > 0 ? 6 / sceneScale : 6)
            if let divider = layout.dividers.first(where: {
                $0.isHit(x: Double(point.x), y: Double(point.y), tolerance: tolerance)
            }) {
                drag = .divider(divider, position: divider.fraction(atX: Double(point.x), y: Double(point.y)))
                dragMoved = false
            } else {
                model.selectTile(
                    inView
                        ? MultiViewTiles.tile(atX: Double(point.x), y: Double(point.y), in: layout.tiles)?.node.id
                        : nil)
            }
            needsDisplay = true
            return
        }

        if model.pathDrawing != nil {
            penDrawMouseDown(scenePoint: point)
            return
        }
        if model.pathEditing != nil {
            if penEditMouseDown(atView: convert(event.locationInWindow, from: nil)) { return }

            model.endPathEditing()
        }

        if model.canvasTextEditID != nil {
            endCanvasEditing()
        }

        if model.showsChords, inView, chordMouseDown(event, at: point) {
            needsDisplay = true
            return
        }

        let pressed = inView
            ? EditorGeometry.pressTarget(
                at: point, in: objects, selected: model.selectedObjectIDs, template: model.currentTemplate)
            : nil

        if event.clickCount == 2, let hit = pressed, model.canEditPath(hit) {

            model.beginPathEditing(hit.id)
            needsDisplay = true
            return
        }

        if event.clickCount == 2, let hit = pressed,
           hit.objectKind == .text || hit.objectKind == .shape {
            if model.canvasTextEditEligible(hit) {
                model.beginCanvasTextEdit(objectID: hit.id)
                syncTextOverlay()

                textOverlay?.placeCaret(at: event)
            } else {
                model.requestTextEdit(objectID: hit.id)
            }
            return
        }

        if let (handle, objectID, frame) = handleHit(atView: convert(event.locationInWindow, from: nil)) {
            drag = .resize(handle: handle, origin: point, originalFrame: frame, objectID: objectID)
            dragMoved = false
            return
        }

        let shiftDown = event.modifierFlags.contains(.shift)

        let hit = shiftDown && inView
            ? EditorGeometry.hitObject(at: point, in: objects, template: model.currentTemplate)
            : pressed
        model.handleClick(objectID: hit?.id, shiftDown: shiftDown)

        if let hit, !shiftDown, model.selectedObjectIDs.contains(hit.id) {
            var frames: [String: CGRect] = [:]
            for object in objects where model.selectedObjectIDs.contains(object.id) {

                frames[object.id] = model.displayFrame(for: object)
            }
            drag = .move(origin: point, originalFrames: frames)
            dragMoved = false
        } else if hit == nil {

            drag = .marquee(origin: point, base: shiftDown ? model.selectedObjectIDs : [])
            dragMoved = false
        }
        needsDisplay = true
    }

    private var snapThreshold: CGFloat {
        let scale = sceneScale
        return scale > 0 ? 8 / scale : 8
    }

    override func mouseDragged(with event: NSEvent) {
        if var chordDrag = chordState.drag {
            chordDrag.point = scenePoint(fromView: convert(event.locationInWindow, from: nil))
            chordDrag.moved = true
            chordState.drag = chordDrag
            needsDisplay = true
            return
        }
        if model.pathDrawing != nil {
            penDrawMouseDragged(scenePoint: scenePoint(fromView: convert(event.locationInWindow, from: nil)))
            return
        }
        if penEditDrag != nil {
            penEditMouseDragged(
                scenePoint: scenePoint(fromView: convert(event.locationInWindow, from: nil)),
                breakPair: event.modifierFlags.contains(.option)
            )
            return
        }
        guard let drag, let slide = model.currentSlide else { return }
        let point = scenePoint(fromView: convert(event.locationInWindow, from: nil))
        dragMoved = true

        switch drag {
        case .move(let origin, let originalFrames):
            let dx = point.x - origin.x
            let dy = point.y - origin.y

            let visualFrames = slide.objects.compactMap { object -> CGRect? in
                guard let frame = originalFrames[object.id] else { return nil }
                return EditorGeometry.rotatedBounds(frame, degrees: object.rotationDegrees ?? 0)
            }
            guard let first = visualFrames.first else { return }
            let union = visualFrames.dropFirst().reduce(first) { $0.union($1) }
            let others = slide.objects
                .filter { originalFrames[$0.id] == nil }
                .map {
                    EditorGeometry.rotatedBounds(
                        model.displayFrame(for: $0), degrees: $0.rotationDegrees ?? 0
                    )
                }
            let snap = EditorGeometry.snapMove(
                union.offsetBy(dx: dx, dy: dy), others: others, threshold: snapThreshold
            )
            let ox = snap.frame.origin.x - union.origin.x
            let oy = snap.frame.origin.y - union.origin.y
            model.previewDrag(
                frames: originalFrames.mapValues { $0.offsetBy(dx: ox, dy: oy) },
                guides: snap.guides
            )

        case .resize(let handle, let origin, let originalFrame, let objectID):
            let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            let resized = EditorGeometry.resize(originalFrame, dragging: handle, by: delta)
            let others = slide.objects
                .filter { $0.id != objectID }
                .map {
                    EditorGeometry.rotatedBounds(
                        model.displayFrame(for: $0), degrees: $0.rotationDegrees ?? 0
                    )
                }
            let rotation = slide.objects.first { $0.id == objectID }?.rotationDegrees ?? 0
            let snap = EditorGeometry.snapResize(
                resized, handle: handle, rotationDegrees: rotation,
                others: others, threshold: snapThreshold
            )
            model.previewDrag(frames: [objectID: snap.frame], guides: snap.guides)

        case .divider(let divider, _):
            let position = divider.fraction(atX: Double(point.x), y: Double(point.y))
            self.drag = .divider(divider, position: position)
            model.previewDivider(divider, to: position)

        case .marquee(let origin, let base):

            let band = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            )
            marqueeBand = band
            marqueeSelection = model.sweptSelection(band: band, keeping: base)
            margin?.needsDisplay = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let chordDrag = chordState.drag {
            chordMouseUp(chordDrag)
            return
        }
        if model.pathDrawing != nil {
            penDrawMouseUp(atView: convert(event.locationInWindow, from: nil))
            return
        }
        if penEditDrag != nil {
            penEditMouseUp()
            return
        }
        defer {
            drag = nil
            dragMoved = false
            needsDisplay = true
        }
        if let drag {
            if case .marquee = drag {

                if let marqueeSelection { model.setSelection(marqueeSelection) }
                marqueeSelection = nil
                marqueeBand = nil
                margin?.needsDisplay = true
            } else if case .divider(let divider, let position) = drag {
                if dragMoved {
                    model.commitDivider(divider, to: position)
                }
            } else if dragMoved {
                model.commitDrag()
            } else {
                model.cancelDrag()
            }
        }
    }

    private func drawMultiViewChrome(
        _ layout: (tiles: [MultiViewTiles.PlacedTile], dividers: [MultiViewTiles.Divider]),
        in context: CGContext, accent: NSColor
    ) {
        context.saveGState()
        var dragged: MultiViewTiles.Divider?
        var draggedPosition = 0.0
        if case .divider(let divider, let position) = drag {
            dragged = divider
            draggedPosition = position
        }
        for divider in layout.dividers {
            let rect = divider.splitRect
            let isDragged = divider.splitId == dragged?.splitId && divider.index == dragged?.index
            let along = isDragged
                ? (divider.axis == .columns
                    ? rect.x + draggedPosition * rect.width : rect.y + draggedPosition * rect.height)
                : divider.position
            let line = divider.axis == .columns
                ? CGRect(x: along, y: rect.y, width: 0, height: rect.height)
                : CGRect(x: rect.x, y: along, width: rect.width, height: 0)
            let viewLine = viewRect(fromScene: line)
            context.setStrokeColor(accent.withAlphaComponent(isDragged ? 1 : 0.35).cgColor)
            context.setLineWidth(isDragged ? 3 : 1.5)
            context.move(to: CGPoint(x: viewLine.minX, y: viewLine.minY))
            context.addLine(to: CGPoint(x: viewLine.maxX, y: viewLine.maxY))
            context.strokePath()
        }
        if dragged == nil, let selected = layout.tiles.first(where: { $0.node.id == model.selectedTileID }) {
            let tile = viewRect(fromScene: CGRect(
                x: selected.rect.x, y: selected.rect.y,
                width: selected.rect.width, height: selected.rect.height))
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(2)
            context.stroke(tile.insetBy(dx: 2, dy: 2))
        }
        context.restoreGState()
    }

    private func handleHit(atView point: CGPoint) -> (EditorGeometry.Handle, String, CGRect)? {
        guard let object = model.singleSelectedObject else { return nil }
        let frame = model.displayFrame(for: object)
        let rotation = object.rotationDegrees ?? 0
        for handle in EditorGeometry.Handle.allCases {
            let scenePosition = rotated(
                EditorGeometry.handlePosition(handle, in: frame),
                around: CGPoint(x: frame.midX, y: frame.midY),
                degrees: rotation
            )
            let viewPosition = viewPoint(fromScene: scenePosition)
            if hypot(viewPosition.x - point.x, viewPosition.y - point.y) <= 6 {
                return (handle, object.id, frame)
            }
        }
        return nil
    }

    private func rotated(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * CGFloat(cos(radians)) - dy * CGFloat(sin(radians)),
            y: center.y + dx * CGFloat(sin(radians)) + dy * CGFloat(cos(radians))
        )
    }

    private var penGrabDistance: CGFloat { 7 }

    private func penDrawMouseDown(scenePoint point: CGPoint) {
        penDownPoint = point
        model.pathDrawingSetProvisional(PathAnchor(point: point))
        needsDisplay = true
    }

    private func penDrawMouseDragged(scenePoint point: CGPoint) {
        guard let down = penDownPoint else { return }

        let mirrored = CGPoint(x: down.x * 2 - point.x, y: down.y * 2 - point.y)
        model.pathDrawingSetProvisional(
            PathAnchor(point: down, handleIn: mirrored, handleOut: point)
        )
        needsDisplay = true
    }

    private func penDrawMouseUp(atView viewPoint: CGPoint) {
        defer {
            penDownPoint = nil
            needsDisplay = true
        }
        guard let drawing = model.pathDrawing, let down = penDownPoint else { return }

        if drawing.anchors.count >= 2,
           let first = drawing.anchors.first,
           drawing.provisional?.handleOut == nil {
            let firstView = self.viewPoint(fromScene: first.point)
            if hypot(firstView.x - viewPoint.x, firstView.y - viewPoint.y) <= penGrabDistance {
                model.finishPathDrawing(closed: true)
                return
            }
        }
        model.pathDrawingCommit(drawing.provisional ?? PathAnchor(point: down))
    }

    private func penEditMouseDown(atView viewPoint: CGPoint) -> Bool {
        guard let editing = model.pathEditing else { return false }

        for (index, anchor) in editing.anchors.enumerated() {
            if let h = anchor.handleIn {
                let v = self.viewPoint(fromScene: h)
                if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= penGrabDistance {
                    penEditDrag = .handleIn(index)
                    model.setScrubPreview(true)
                    return true
                }
            }
            if let h = anchor.handleOut {
                let v = self.viewPoint(fromScene: h)
                if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= penGrabDistance {
                    penEditDrag = .handleOut(index)
                    model.setScrubPreview(true)
                    return true
                }
            }
        }
        for (index, anchor) in editing.anchors.enumerated() {
            let v = self.viewPoint(fromScene: anchor.point)
            if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= penGrabDistance {
                penEditDrag = .anchor(index)
                model.setScrubPreview(true)
                return true
            }
        }
        return false
    }

    private func penEditMouseDragged(scenePoint point: CGPoint, breakPair: Bool) {
        guard let editing = model.pathEditing, let target = penEditDrag else { return }
        var anchors = editing.anchors
        switch target {
        case .anchor(let index):
            let old = anchors[index].point
            let dx = point.x - old.x
            let dy = point.y - old.y
            anchors[index].point = point
            anchors[index].handleIn = anchors[index].handleIn.map {
                CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
            anchors[index].handleOut = anchors[index].handleOut.map {
                CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
        case .handleIn(let index):
            anchors[index].handleIn = point
            if !breakPair, anchors[index].handleOut != nil {
                let p = anchors[index].point
                anchors[index].handleOut = CGPoint(x: p.x * 2 - point.x, y: p.y * 2 - point.y)
            }
        case .handleOut(let index):
            anchors[index].handleOut = point
            if !breakPair, anchors[index].handleIn != nil {
                let p = anchors[index].point
                anchors[index].handleIn = CGPoint(x: p.x * 2 - point.x, y: p.y * 2 - point.y)
            }
        }
        model.pathEditingUpdate(anchors: anchors)
        needsDisplay = true
    }

    private func penEditMouseUp() {
        guard let editing = model.pathEditing else {
            penEditDrag = nil
            return
        }
        penEditDrag = nil

        model.setScrubPreview(false)
        model.pathEditingUpdate(anchors: editing.anchors)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        if model.pathDrawing != nil {
            model.pathDrawingSetHover(scenePoint(fromView: convert(event.locationInWindow, from: nil)))
            needsDisplay = true
            return
        }

        guard model.editorMode == .animate else {
            if model.canvasHoveredObjectID != nil { model.canvasHoveredObjectID = nil }
            return
        }
        let point = scenePoint(fromView: convert(event.locationInWindow, from: nil))
        let hit = model.currentSlide.flatMap {
            EditorGeometry.hitObject(at: point, in: $0.objects, template: model.currentTemplate)
        }
        if model.canvasHoveredObjectID != hit?.id {
            model.canvasHoveredObjectID = hit?.id
        }
    }

    override func mouseExited(with event: NSEvent) {
        if model.canvasHoveredObjectID != nil { model.canvasHoveredObjectID = nil }
        super.mouseExited(with: event)
    }

    @objc func copy(_ sender: Any?) { model.copySelectedObjects() }
    @objc func cut(_ sender: Any?) { model.cutSelectedObjects() }
    @objc func paste(_ sender: Any?) { model.paste() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let focused = event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && window?.firstResponder === self
        if focused, event.charactersIgnoringModifiers == "d", model.canCopyObjects {
            model.duplicateSelectedObjects()
            return true
        } else if focused, event.charactersIgnoringModifiers == "a" {
            model.selectAllObjects(includingHidden: false)
            return true
        } else {
            return super.performKeyEquivalent(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = scenePoint(fromView: convert(event.locationInWindow, from: nil))
        guard let objects = model.currentSlide?.objects else { return nil }
        if let hit = EditorGeometry.hitObject(at: point, in: objects, template: model.currentTemplate),
           !model.selectedObjectIDs.contains(hit.id) {
            model.handleClick(objectID: hit.id, shiftDown: false)
            needsDisplay = true
        }

        let menu = NSMenu()
        let hasSelection = model.canCopyObjects
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = enabled ? self : nil
            menu.addItem(item)
        }
        if let single = model.singleSelectedObject, model.canEditPath(single) {
            item("Edit Path", #selector(editPathFromMenu(_:)))
            menu.addItem(.separator())
        }
        item("Cut", #selector(cut(_:)), enabled: hasSelection)
        item("Copy", #selector(copy(_:)), enabled: hasSelection)
        item("Paste", #selector(paste(_:)), enabled: model.canPaste)
        item("Duplicate", #selector(duplicateFromMenu(_:)), enabled: hasSelection)
        menu.addItem(.separator())
        SlideEditorModel.ArrangeAction.grouping.forEach { menu.addItem(arrangeItem($0)) }
        menu.addItem(.separator())

        let align = NSMenu()
        let groups: [[SlideEditorModel.ArrangeAction]] = [
            SlideEditorModel.ArrangeAction.horizontalAlign,
            SlideEditorModel.ArrangeAction.verticalAlign,
            SlideEditorModel.ArrangeAction.distribute,
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { align.addItem(.separator()) }
            group.forEach { align.addItem(arrangeItem($0)) }
        }
        let alignItem = NSMenuItem(title: "Align", action: nil, keyEquivalent: "")
        alignItem.submenu = align
        menu.addItem(alignItem)
        SlideEditorModel.ArrangeAction.layerOrder.forEach { menu.addItem(arrangeItem($0)) }
        menu.addItem(.separator())
        item("Delete", #selector(deleteFromMenu(_:)), enabled: hasSelection)
        return menu
    }

    private func arrangeItem(_ action: SlideEditorModel.ArrangeAction) -> NSMenuItem {
        let enabled = model.canPerform(action)
        let item = NSMenuItem(
            title: action.title, action: enabled ? #selector(arrangeFromMenu(_:)) : nil, keyEquivalent: "")
        item.target = enabled ? self : nil
        item.representedObject = action
        return item
    }

    @objc private func arrangeFromMenu(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? SlideEditorModel.ArrangeAction {
            model.perform(action)
        }
    }

    @objc private func duplicateFromMenu(_ sender: Any?) { model.duplicateSelectedObjects() }
    @objc private func editPathFromMenu(_ sender: Any?) {
        if let single = model.singleSelectedObject { model.beginPathEditing(single.id) }
    }
    @objc private func deleteFromMenu(_ sender: Any?) { model.deleteSelectedObjects() }

    override func keyDown(with event: NSEvent) {
        if model.showsChords, let selected = chordState.selected, chordKeyDown(event, selected: selected) {
            needsDisplay = true
            return
        }
        if model.pathDrawing != nil {
            switch event.keyCode {
            case 53: 
                model.cancelPathDrawing()
            case 36, 76: 
                model.finishPathDrawing(closed: false)
            case 51, 117: 
                model.pathDrawingRemoveLast()
            default:
                super.keyDown(with: event)
            }
            needsDisplay = true
            return
        }
        if model.pathEditing != nil, [53, 36, 76].contains(event.keyCode) {
            model.endPathEditing() 
            needsDisplay = true
            return
        }

        if event.keyCode == 49, model.editorMode == .animate {
            if model.animationPreviewPlaying {
                model.stopAnimationPreview()
            } else {
                model.playPreviewScope()
            }
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: 
            model.clearSelection()
        case 51, 117: 
            model.deleteSelectedObjects()
        case 123: 
            model.nudgeSelection(dx: -step, dy: 0)
        case 124: 
            model.nudgeSelection(dx: step, dy: 0)
        case 125: 
            model.nudgeSelection(dx: 0, dy: step)
        case 126: 
            model.nudgeSelection(dx: 0, dy: -step)
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let slide = model.currentSlide else { return }
        let accent = NSColor.controlAccentColor

        drawPasteboardVeil(in: context)
        drawGuides(in: context, accent: accent)

        for object in slide.objects
        where object.objectKind == .text
            && object.textLink == nil
            && object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && object.id != model.canvasTextEditID {
            drawEmptyTextHint(for: object, in: context)
        }

        let matteIDs = Set(slide.objects.compactMap(\.maskObjectId))
        for object in slide.objects where matteIDs.contains(object.id) {
            drawMatteHint(for: object, in: context)
        }

        syncClippedTextTooltips()
        for object in slide.objects where model.clippedTextObjectIDs.contains(object.id) {
            drawClippedTextWarning(for: object, in: context)
        }

        if let layout = model.multiViewLayout {
            drawMultiViewChrome(layout, in: context, accent: accent)
        }

        let selected = marqueeSelection.map(model.sweepOutline) ?? model.selectedObjectIDs
        for object in slide.objects where selected.contains(object.id) {
            drawSelectionOutline(for: object, in: context, accent: accent)
        }
        if selected.count == 1, let id = selected.first, let single = model.object(id: id) {
            drawHandles(for: single, in: context, accent: accent)
        }

        if let band = marqueeViewRect {
            drawEditorMarquee(band, in: context, accent: accent)
        }

        if let drawing = model.pathDrawing {
            drawPenDrawing(drawing, in: context, accent: accent)
        }
        if let editing = model.pathEditing {
            drawPenEditing(editing, in: context, accent: accent)
        }

        if model.showsChords {
            drawChordChrome(in: context, accent: accent)
        }

        if model.motionPausedForEditing,
           slide.objects.contains(where: { object in
               model.selectedObjectIDs.contains(object.id)
                   && ((object.textStyle?.tickerSpeed ?? 0) != 0 || (object.textStyle?.scroll?.speed ?? 0) > 0)
           }) {
            drawMotionPausedHint()
        }
    }

    var canvasViewRect: CGRect {
        viewRect(fromScene: CGRect(origin: .zero, size: model.canvasSize))
    }

    private func drawPasteboardVeil(in context: CGContext) {
        let canvas = canvasViewRect
        if !canvas.contains(bounds) {
            context.saveGState()
            context.addRect(bounds)
            context.addRect(canvas)
            context.setFillColor(NSColor(Color.basePlane).withAlphaComponent(Self.pasteboardVeilAlpha).cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
    }

    static let pasteboardVeilAlpha: CGFloat = 0.55

    private func penViewPath(anchors: [PathAnchor], closed: Bool, to hover: CGPoint? = nil) -> CGPath {
        let path = CGMutablePath()
        guard let first = anchors.first else { return path }
        path.move(to: viewPoint(fromScene: first.point))
        for i in 1..<anchors.count {
            addPenSegment(from: anchors[i - 1], to: anchors[i], into: path)
        }
        if closed, anchors.count > 1 {
            addPenSegment(from: anchors[anchors.count - 1], to: anchors[0], into: path)
            path.closeSubpath()
        } else if let hover, let last = anchors.last {

            if let h = last.handleOut {
                path.addCurve(
                    to: viewPoint(fromScene: hover),
                    control1: viewPoint(fromScene: h),
                    control2: viewPoint(fromScene: hover)
                )
            } else {
                path.addLine(to: viewPoint(fromScene: hover))
            }
        }
        return path
    }

    private func addPenSegment(from: PathAnchor, to: PathAnchor, into path: CGMutablePath) {
        if from.handleOut == nil, to.handleIn == nil {
            path.addLine(to: viewPoint(fromScene: to.point))
        } else {
            path.addCurve(
                to: viewPoint(fromScene: to.point),
                control1: viewPoint(fromScene: from.handleOut ?? from.point),
                control2: viewPoint(fromScene: to.handleIn ?? to.point)
            )
        }
    }

    private func strokePenPath(_ path: CGPath, in context: CGContext, dashed: Bool) {
        context.saveGState()
        context.setLineWidth(1.5)
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        if dashed { context.setLineDash(phase: 3.5, lengths: [4, 3]) }
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    private func drawPenAnchor(at scenePoint: CGPoint, in context: CGContext, accent: NSColor, highlighted: Bool = false) {
        let v = viewPoint(fromScene: scenePoint)
        let size: CGFloat = highlighted ? 9 : 7
        let rect = CGRect(x: v.x - size / 2, y: v.y - size / 2, width: size, height: size)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(highlighted ? 2 : 1.5)
        context.fill(rect)
        context.stroke(rect)
    }

    private func drawPenHandle(anchor: CGPoint, handle: CGPoint, in context: CGContext, accent: NSColor) {
        let a = viewPoint(fromScene: anchor)
        let h = viewPoint(fromScene: handle)
        context.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.strokeLineSegments(between: [a, h])
        let dot = CGRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6)
        context.setFillColor(accent.cgColor)
        context.fillEllipse(in: dot)
    }

    private func drawPenDrawing(_ drawing: SlideEditorModel.PathDrawing, in context: CGContext, accent: NSColor) {
        var anchors = drawing.anchors
        if let provisional = drawing.provisional { anchors.append(provisional) }
        guard !anchors.isEmpty else {
            drawPenHint("Click to add points — drag for curves · click the first point to close · ⏎ finishes open · esc cancels")
            return
        }
        strokePenPath(
            penViewPath(anchors: anchors, closed: false, to: drawing.provisional == nil ? drawing.hover : nil),
            in: context, dashed: true
        )
        for (index, anchor) in anchors.enumerated() {

            var highlighted = false
            if index == 0, anchors.count >= 2, let hover = drawing.hover {
                let f = viewPoint(fromScene: anchor.point)
                let hv = viewPoint(fromScene: hover)
                highlighted = hypot(f.x - hv.x, f.y - hv.y) <= penGrabDistance
            }
            drawPenAnchor(at: anchor.point, in: context, accent: accent, highlighted: highlighted)
        }
        if let provisional = drawing.provisional {
            if let h = provisional.handleIn {
                drawPenHandle(anchor: provisional.point, handle: h, in: context, accent: accent)
            }
            if let h = provisional.handleOut {
                drawPenHandle(anchor: provisional.point, handle: h, in: context, accent: accent)
            }
        }
        drawPenHint("Click to add points — drag for curves · click the first point to close · ⏎ finishes open · esc cancels")
    }

    private func drawPenEditing(_ editing: SlideEditorModel.PathEditing, in context: CGContext, accent: NSColor) {
        strokePenPath(
            penViewPath(anchors: editing.anchors, closed: editing.closed),
            in: context, dashed: false
        )
        for anchor in editing.anchors {
            if let h = anchor.handleIn {
                drawPenHandle(anchor: anchor.point, handle: h, in: context, accent: accent)
            }
            if let h = anchor.handleOut {
                drawPenHandle(anchor: anchor.point, handle: h, in: context, accent: accent)
            }
            drawPenAnchor(at: anchor.point, in: context, accent: accent)
        }
        drawPenHint("Drag points and handles · ⌥ breaks a handle pair · ⏎ done")
    }

    private func drawPenHint(_ text: String) {
        let hint = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = hint.size(withAttributes: attributes)
        hint.draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 10),
            withAttributes: attributes
        )
    }

    private func drawMotionPausedHint() {
        let text = "Motion paused while editing" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height - 10
        )
        text.draw(at: origin, withAttributes: attributes)
    }

    private func drawClippedTextWarning(for object: SlideObject, in context: CGContext) {
        let rect = viewRect(fromScene: model.displayFrame(for: object)).insetBy(dx: 0.5, dy: 0.5)
        let amber = NSColor.systemOrange
        context.saveGState()
        context.setLineWidth(1.5)
        context.setStrokeColor(amber.withAlphaComponent(0.9).cgColor)
        context.stroke(rect)
        context.restoreGState()

        let badge = clippedBadgeRect(for: rect)
        context.saveGState()
        context.setFillColor(amber.cgColor)
        context.fillEllipse(in: badge)
        context.restoreGState()
        let mark = "!" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = mark.size(withAttributes: attributes)
        mark.draw(
            at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func clippedBadgeRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 8, y: rect.minY - 8, width: 16, height: 16)
    }

    private static let clippedTextToolTip: NSString =
        "Text doesn't fit this box — the overflow is clipped on the output. Resize the box, edit the text, or shrink the font."

    func syncClippedTextTooltips() {
        removeAllToolTips()
        guard let slide = model.currentSlide else { return }
        for object in slide.objects where model.clippedTextObjectIDs.contains(object.id) {
            let rect = viewRect(fromScene: model.displayFrame(for: object))
            addToolTip(
                clippedBadgeRect(for: rect.insetBy(dx: 0.5, dy: 0.5)),
                owner: Self.clippedTextToolTip,
                userData: nil
            )
        }
    }

    private func drawMatteHint(for object: SlideObject, in context: CGContext) {
        let rect = viewRect(fromScene: model.displayFrame(for: object)).insetBy(dx: 0.5, dy: 0.5)
        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.setLineDash(phase: 0, lengths: [3, 3])
        context.stroke(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
        context.setLineDash(phase: 3, lengths: [3, 3])
        context.stroke(rect)
        context.restoreGState()

        let tag = "Mask" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let size = tag.size(withAttributes: attributes)
        if rect.width > size.width + 8, rect.height > size.height + 6 {
            tag.draw(
                at: CGPoint(x: rect.minX + 5, y: rect.minY + 3),
                withAttributes: attributes
            )
        }
    }

    private func drawEmptyTextHint(for object: SlideObject, in context: CGContext) {
        let rect = viewRect(fromScene: model.displayFrame(for: object)).insetBy(dx: 0.5, dy: 0.5)

        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
        context.setLineDash(phase: 4.5, lengths: [5, 4])
        context.stroke(rect)
        context.restoreGState()

        let hint = "Double-click to add text" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                shadow.shadowBlurRadius = 2
                return shadow
            }(),
        ]
        let size = hint.size(withAttributes: attributes)
        guard size.width < rect.width, size.height < rect.height else { return }
        hint.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawGuides(in context: CGContext, accent: NSColor) {
        guard !model.activeGuides.isEmpty else { return }
        let canvas = model.canvasSize
        context.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        for guide in model.activeGuides {
            switch guide {
            case .vertical(let x):
                context.move(to: viewPoint(fromScene: CGPoint(x: x, y: 0)))
                context.addLine(to: viewPoint(fromScene: CGPoint(x: x, y: canvas.height)))
            case .horizontal(let y):
                context.move(to: viewPoint(fromScene: CGPoint(x: 0, y: y)))
                context.addLine(to: viewPoint(fromScene: CGPoint(x: canvas.width, y: y)))
            }
            context.strokePath()
        }
    }

    private func drawSelectionOutline(for object: SlideObject, in context: CGContext, accent: NSColor) {
        let rect = viewRect(fromScene: model.displayFrame(for: object))
        let rotation = object.rotationDegrees ?? 0
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)

        context.rotate(by: CGFloat(rotation * .pi / 180))
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func drawHandles(for object: SlideObject, in context: CGContext, accent: NSColor) {
        let frame = model.displayFrame(for: object)
        let rotation = object.rotationDegrees ?? 0
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let size: CGFloat = 7
        for handle in EditorGeometry.Handle.allCases {
            let scenePosition = rotated(
                EditorGeometry.handlePosition(handle, in: frame), around: center, degrees: rotation
            )
            let p = viewPoint(fromScene: scenePosition)
            let box = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1)
            context.stroke(box)
        }
    }
}

extension EditorInteractionNSView: NSTextViewDelegate {
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {

        if overlayObjectID != nil, let replacement = replacementString {
            model.canvasTextWillReplace(utf16Range: affectedCharRange, replacement: replacement)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let overlay = textOverlay, let id = overlayObjectID else { return }
        let text = overlay.string

        model.updateObject(id: id) { $0.text = text }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let overlay = textOverlay, overlayObjectID != nil else { return }
        model.canvasTextSelectionChanged(overlay.selectedRange())
    }

    func textDidEndEditing(_ notification: Notification) {

        endCanvasEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endCanvasEditing()
            return true
        }
        return false
    }
}

struct ChordCanvasState {
    struct Ref: Equatable {
        var objectID: String
        var index: Int
    }

    enum FieldTarget {
        case existing(Ref)
        case new(objectID: String, line: Int, column: Int)
    }

    struct Drag {
        var ref: Ref
        var grab: CGSize
        var point: CGPoint
        var moved = false
    }

    struct Drop {
        var objectID: String
        var line: Int
        var column: Int
        var caret: CGRect
    }

    var selected: Ref?
    var drag: Drag?
    var field: NSTextField?
    var fieldTarget: FieldTarget?
    var layouts: [String: (text: StyledText, size: CGSize, layout: TextEditLayout)] = [:]
}

extension EditorInteractionNSView: NSTextFieldDelegate {
    private func chordLayout(_ target: SlideEditorModel.ChordTarget) -> TextEditLayout {
        if let cached = chordState.layouts[target.objectID],
           cached.text == target.text, cached.size == target.frame.size {
            return cached.layout
        } else {
            let layout = TextEditLayout(text: target.text, sceneFrame: target.frame.size)
            chordState.layouts[target.objectID] = (target.text, target.frame.size, layout)
            return layout
        }
    }

    private func chordHit(at point: CGPoint) -> (ref: ChordCanvasState.Ref, rect: CGRect)? {
        let slop = 6 / max(sceneScale, 0.01)
        return model.chordTargets.lazy.filter(\.chordsMatch).compactMap { target in
            let layout = self.chordLayout(target)
            let local = CGPoint(x: point.x - target.frame.minX, y: point.y - target.frame.minY)
            return layout.chord(at: local, slop: slop).flatMap { index in
                layout.chords.first { $0.index == index }.map { chord in
                    (ChordCanvasState.Ref(objectID: target.objectID, index: index),
                     chord.rect.offsetBy(dx: target.frame.minX, dy: target.frame.minY))
                }
            }
        }.first
    }

    private func chordAnchor(at point: CGPoint) -> ChordCanvasState.Drop? {
        let slop = 12 / max(sceneScale, 0.01)
        return model.chordTargets.lazy.filter {
            $0.chordsMatch && $0.frame.insetBy(dx: -slop, dy: -slop).contains(point)
        }.map { target in
            let layout = self.chordLayout(target)
            let anchor = layout.anchor(at: CGPoint(x: point.x - target.frame.minX, y: point.y - target.frame.minY))
            return ChordCanvasState.Drop(
                objectID: target.objectID, line: anchor.line, column: anchor.column,
                caret: layout.caretRect(line: anchor.line, column: anchor.column)
                    .offsetBy(dx: target.frame.minX, dy: target.frame.minY)
            )
        }.first
    }

    private func draggedRect(_ drag: ChordCanvasState.Drag) -> CGRect? {
        model.chordTargets.first { $0.objectID == drag.ref.objectID }.flatMap { target in
            chordLayout(target).chords.first { $0.index == drag.ref.index }.map { chord in
                CGRect(
                    x: drag.point.x - drag.grab.width, y: drag.point.y - drag.grab.height,
                    width: chord.rect.width, height: chord.rect.height)
            }
        }
    }

    private func chordDrop(for drag: ChordCanvasState.Drag) -> ChordCanvasState.Drop? {
        draggedRect(drag).flatMap { rect in
            chordAnchor(at: CGPoint(x: rect.minX + 1, y: rect.maxY + rect.height * 0.25))
        }
    }

    private func storedChord(_ ref: ChordCanvasState.Ref) -> ChordPlacement? {
        model.object(id: ref.objectID)?.chords.flatMap { $0.indices.contains(ref.index) ? $0[ref.index] : nil }
    }

    func chordMouseDown(_ event: NSEvent, at point: CGPoint) -> Bool {
        endChordField(commit: true)
        if let hit = chordHit(at: point) {
            chordState.selected = hit.ref
            if event.clickCount == 2 {
                openChordField(.existing(hit.ref), sceneRect: hit.rect, symbol: storedChord(hit.ref)?.symbol ?? "")
            } else {
                chordState.drag = ChordCanvasState.Drag(
                    ref: hit.ref, grab: CGSize(width: point.x - hit.rect.minX, height: point.y - hit.rect.minY),
                    point: point)
            }
            return true
        } else if event.clickCount == 2, let anchor = chordAnchor(at: point) {
            chordState.selected = nil
            let rowHeight = anchor.caret.height * 0.7
            openChordField(
                .new(objectID: anchor.objectID, line: anchor.line, column: anchor.column),
                sceneRect: CGRect(x: anchor.caret.minX, y: anchor.caret.minY - rowHeight, width: 0, height: rowHeight),
                symbol: "")
            return true
        } else {
            chordState.selected = nil
            return false
        }
    }

    func chordMouseUp(_ drag: ChordCanvasState.Drag) {
        chordState.drag = nil
        if drag.moved, let drop = chordDrop(for: drag) {
            let landed = model.moveChord(
                objectID: drag.ref.objectID, index: drag.ref.index,
                toObjectID: drop.objectID, line: drop.line, column: drop.column)
            chordState.selected = landed.map { ChordCanvasState.Ref(objectID: drop.objectID, index: $0) }
        }
        needsDisplay = true
    }

    func chordKeyDown(_ event: NSEvent, selected: ChordCanvasState.Ref) -> Bool {
        let nudge: (line: Int, column: Int)? = switch event.keyCode {
        case 123: (0, -1)
        case 124: (0, 1)
        case 125: (1, 0)
        case 126: (-1, 0)
        default: nil
        }
        if [51, 117].contains(event.keyCode) {
            model.removeChord(objectID: selected.objectID, index: selected.index)
            chordState.selected = nil
            return true
        } else if [36, 76].contains(event.keyCode), let chord = storedChord(selected), let hit = selectedRect(selected) {
            openChordField(.existing(selected), sceneRect: hit, symbol: chord.symbol)
            return true
        } else if event.keyCode == 53 {
            chordState.selected = nil
            return true
        } else if let nudge, let chord = storedChord(selected) {
            let landed = model.moveChord(
                objectID: selected.objectID, index: selected.index, toObjectID: selected.objectID,
                line: chord.line + nudge.line, column: chord.column + nudge.column)
            chordState.selected = landed.map { ChordCanvasState.Ref(objectID: selected.objectID, index: $0) }
            return true
        } else {
            return false
        }
    }

    private func selectedRect(_ ref: ChordCanvasState.Ref) -> CGRect? {
        model.chordTargets.first { $0.objectID == ref.objectID }.flatMap { target in
            chordLayout(target).chords.first { $0.index == ref.index }
                .map { $0.rect.offsetBy(dx: target.frame.minX, dy: target.frame.minY) }
        }
    }

    private func openChordField(_ target: ChordCanvasState.FieldTarget, sceneRect: CGRect, symbol: String) {
        endChordField(commit: true)
        let rect = viewRect(fromScene: sceneRect)
        let field = NSTextField(string: symbol)
        field.placeholderString = "Chord"
        field.font = .systemFont(ofSize: 14, weight: .bold)
        field.alignment = .left
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.frame = CGRect(x: rect.minX - 4, y: rect.midY - 12, width: max(rect.width + 36, 72), height: 24)
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        chordState.field = field
        chordState.fieldTarget = target
    }

    func endChordField(commit: Bool) {
        if let field = chordState.field, let target = chordState.fieldTarget {
            chordState.field = nil
            chordState.fieldTarget = nil
            let symbol = field.stringValue
            field.delegate = nil
            field.removeFromSuperview()
            window?.makeFirstResponder(self)
            if commit {
                switch target {
                case .existing(let ref):
                    if symbol != storedChord(ref)?.symbol {
                        let landed = model.setChord(objectID: ref.objectID, index: ref.index, symbol: symbol)
                        chordState.selected = landed.map { ChordCanvasState.Ref(objectID: ref.objectID, index: $0) }
                    }
                case .new(let objectID, let line, let column):
                    let landed = model.addChord(objectID: objectID, line: line, column: column, symbol: symbol)
                    chordState.selected = landed.map { ChordCanvasState.Ref(objectID: objectID, index: $0) }
                }
            }
            needsDisplay = true
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endChordField(commit: false)
            return true
        } else if commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertTab(_:)) {
            endChordField(commit: true)
            return true
        } else {
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endChordField(commit: true)
    }

    func syncChordState() {
        if !model.showsChords || chordState.selected.map({ storedChord($0) == nil }) == true {
            chordState.selected = nil
        }
        if !model.showsChords {
            endChordField(commit: false)
            chordState.drag = nil
            chordState.layouts = [:]
        }
    }

    func drawChordChrome(in context: CGContext, accent: NSColor) {
        let dragging = chordState.drag.flatMap { $0.moved ? $0 : nil }
        for target in model.chordTargets where target.chordsMatch {
            let layout = chordLayout(target)
            for chord in layout.chords {
                let ref = ChordCanvasState.Ref(objectID: target.objectID, index: chord.index)
                let rect = viewRect(fromScene: chord.rect.offsetBy(dx: target.frame.minX, dy: target.frame.minY))
                    .insetBy(dx: -3, dy: -2)
                let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.saveGState()
                if dragging?.ref == ref {
                    context.setLineDash(phase: 0, lengths: [3, 3])
                    context.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
                    context.setLineWidth(1)
                } else if chordState.selected == ref {
                    context.addPath(path)
                    context.setFillColor(accent.withAlphaComponent(0.25).cgColor)
                    context.fillPath()
                    context.setStrokeColor(accent.cgColor)
                    context.setLineWidth(1.5)
                } else {
                    context.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
                    context.setLineWidth(1)
                }
                context.addPath(path)
                context.strokePath()
                context.restoreGState()
            }
        }

        if let dragging, let rect = draggedRect(dragging),
           let target = model.chordTargets.first(where: { $0.objectID == dragging.ref.objectID }),
           target.text.chords.indices.contains(dragging.ref.index) {
            if let drop = chordDrop(for: dragging) {
                let caret = viewRect(fromScene: drop.caret)
                context.saveGState()
                context.setFillColor(accent.cgColor)
                context.fill(CGRect(
                    x: caret.minX - 1, y: caret.minY - viewRect(fromScene: rect).height,
                    width: 2, height: caret.height + viewRect(fromScene: rect).height))
                context.restoreGState()
            }
            let view = viewRect(fromScene: rect).insetBy(dx: -4, dy: -2)
            context.saveGState()
            context.addPath(CGPath(roundedRect: view, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            context.fillPath()
            context.restoreGState()
            let symbol = target.text.chords[dragging.ref.index].symbol as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(view.height * 0.7, 10), weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = symbol.size(withAttributes: attributes)
            symbol.draw(at: CGPoint(x: view.minX + 4, y: view.midY - size.height / 2), withAttributes: attributes)
        }

        if model.pathDrawing == nil, model.pathEditing == nil {
            drawPenHint("Chords: double-click a word to add one · drag to move · double-click to change · Delete removes")
        }
    }
}

#if DEBUG || MXU_PERF_HOOKS

extension EditorInteractionNSView {
    var perfEditor: SlideEditorModel { model }

    func perfPressPoints(objectID: String) -> (center: CGPoint, handle: CGPoint)? {
        guard let window, let object = model.object(id: objectID), let primary = NSScreen.screens.first
        else { return nil }
        let frame = model.displayFrame(for: object)
        func screen(_ scene: CGPoint) -> CGPoint {
            let onScreen = window.convertPoint(toScreen: convert(viewPoint(fromScene: scene), to: nil))
            return CGPoint(x: onScreen.x, y: primary.frame.maxY - onScreen.y)
        }
        return (
            screen(CGPoint(x: frame.midX, y: frame.midY)),
            screen(EditorGeometry.handlePosition(.bottomRight, in: frame))
        )
    }
}
#endif

final class OverlayTextView: NSTextView {
    enum FormatKey { case bold, italic, underline }
    var onFormatKey: ((FormatKey) -> Bool)?

    var onPasteWithFormatting: ((NSAttributedString) -> Bool)?

    var perspective: EditorGeometry.Homography? {
        didSet {
            if perspective != oldValue {
                wantsLayer = perspective != nil || wantsLayer
                applyPerspective()
            }
        }
    }

    private func applyPerspective() {
        guard let layer else { return }
        guard let p = perspective else {
            if !CATransform3DIsIdentity(layer.transform) { layer.transform = CATransform3DIdentity }
            return
        }

        var t = CATransform3DIdentity
        t.m11 = p.a; t.m12 = p.d; t.m14 = p.g
        t.m21 = p.b; t.m22 = p.e; t.m24 = p.h
        t.m41 = p.c; t.m42 = p.f; t.m44 = p.w0
        layer.transform = t
    }

    override func layout() {
        super.layout()
        applyPerspective()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPerspective()
    }

    private func remapped(_ event: NSEvent) -> NSEvent {
        guard let p = perspective, let window else { return event }
        let local = convert(event.locationInWindow, from: nil)
        let flat = p.inverseApply(local)
        let inWindow = convert(flat, to: nil)
        return NSEvent.mouseEvent(
            with: event.type, location: inWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
        ) ?? event
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    override func mouseDown(with event: NSEvent) {
        if let editLayout {
            trackSelection(from: remapped(event), in: editLayout)
        } else {
            super.mouseDown(with: remapped(event))
        }
    }
    override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: remapped(event)) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: remapped(event)) }
    override func rightMouseDown(with event: NSEvent) { super.rightMouseDown(with: remapped(event)) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: remapped(event)) }

    var editLayout: TextEditLayout? {
        didSet { refreshCaret() }
    }

    var editLayoutKey: (text: StyledText, size: CGSize)?

    var sceneScale: CGFloat = 1 {
        didSet { if sceneScale != oldValue { refreshCaret() } }
    }
    var caretColor: NSColor = .controlAccentColor {
        didSet { caret.color = caretColor }
    }

    private lazy var caret: NSTextInsertionIndicator = {
        let indicator = NSTextInsertionIndicator(frame: .zero)
        indicator.color = caretColor
        addSubview(indicator)
        return indicator
    }()

    private var selectionEnds: (anchor: Int, moving: Int)?

    private var verticalGoal: (x: CGFloat, index: Int)?

    private func viewRect(_ scene: CGRect) -> CGRect {
        CGRect(
            x: scene.minX * sceneScale, y: scene.minY * sceneScale,
            width: scene.width * sceneScale, height: scene.height * sceneScale
        )
    }

    private func refreshCaret() {
        let selection = selectedRange()
        if let editLayout, selection.length == 0, window?.firstResponder === self {
            let rect = viewRect(editLayout.caretRect(at: selection.location))
            let width = max(2, (rect.height / 24).rounded())
            caret.frame = CGRect(x: rect.minX - width / 2, y: rect.minY, width: width, height: max(rect.height, 1))
            caret.displayMode = .automatic
        } else {
            caret.displayMode = .hidden
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selection = selectedRange()
        if let editLayout, selection.length > 0 {

            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).setFill()
            for rect in editLayout.selectionRects(for: selection) {
                viewRect(rect).fill(using: .sourceOver)
            }
        }
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        refreshCaret()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        refreshCaret()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        refreshCaret()
        return resigned
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let editLayout, let window {
            let local = viewRect(editLayout.caretRect(at: range.location))
            return window.convertToScreen(convert(local, to: nil))
        } else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
    }

    private func caretIndex(at event: NSEvent, in layout: TextEditLayout) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        return layout.index(at: CGPoint(x: point.x / sceneScale, y: point.y / sceneScale))
    }

    func placeCaret(at event: NSEvent) {
        if let editLayout {
            setSelectedRange(NSRange(location: caretIndex(at: remapped(event), in: editLayout), length: 0))
        }
    }

    private func trackSelection(from event: NSEvent, in layout: TextEditLayout) {
        window?.makeFirstResponder(self)
        let granularity: NSSelectionGranularity = switch event.clickCount {
        case 2: .selectByWord
        case 3...: .selectByParagraph
        default: .selectByCharacter
        }
        func index(of event: NSEvent) -> Int { caretIndex(at: event, in: layout) }
        let hit = index(of: event)
        let current = selectedRange()
        let anchor: NSRange = if event.modifierFlags.contains(.shift) {
            NSRange(location: hit < current.location ? NSMaxRange(current) : current.location, length: 0)
        } else {
            selectionRange(forProposedRange: NSRange(location: hit, length: 0), granularity: granularity)
        }
        func select(to index: Int) {
            let proposed = NSUnionRange(anchor, NSRange(location: index, length: 0))
            setSelectedRange(selectionRange(forProposedRange: proposed, granularity: granularity))
        }
        select(to: hit)
        selectionEnds = nil
        verticalGoal = nil
        var tracking = true
        while tracking, let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            select(to: index(of: remapped(next)))
            tracking = next.type == .leftMouseDragged
        }
    }

    private func moveCaret(extending: Bool, forward: Bool, to target: (Int) -> Int) {
        let range = selectedRange()
        let ends = selectionEnds.flatMap { ends in
            NSRange(location: min(ends.anchor, ends.moving), length: abs(ends.moving - ends.anchor)) == range ? ends : nil
        } ?? (anchor: range.location, moving: NSMaxRange(range))
        if extending {
            let moving = target(ends.moving)
            setSelectedRange(NSRange(location: min(ends.anchor, moving), length: abs(moving - ends.anchor)))
            selectionEnds = (ends.anchor, moving)
        } else {
            let index = target(forward ? NSMaxRange(range) : range.location)
            setSelectedRange(NSRange(location: index, length: 0))
            selectionEnds = (index, index)
        }
    }

    private func moveVertically(_ delta: Int, extending: Bool, fallback: () -> Void) {
        if let editLayout {
            moveCaret(extending: extending, forward: delta > 0) { from in
                let x = verticalGoal.flatMap { $0.index == from ? $0.x : nil } ?? editLayout.caretRect(at: from).minX
                let index = editLayout.index(from: from, movingLines: delta, goalX: x)
                verticalGoal = (x, index)
                return index
            }
        } else {
            fallback()
        }
    }

    private func moveToLineBoundary(end: Bool, extending: Bool, fallback: () -> Void) {
        if let editLayout {
            moveCaret(extending: extending, forward: end) { editLayout.lineBoundary(of: $0, end: end) }
        } else {
            fallback()
        }
    }

    override func moveUp(_ sender: Any?) {
        moveVertically(-1, extending: false) { super.moveUp(sender) }
    }
    override func moveDown(_ sender: Any?) {
        moveVertically(1, extending: false) { super.moveDown(sender) }
    }
    override func moveUpAndModifySelection(_ sender: Any?) {
        moveVertically(-1, extending: true) { super.moveUpAndModifySelection(sender) }
    }
    override func moveDownAndModifySelection(_ sender: Any?) {
        moveVertically(1, extending: true) { super.moveDownAndModifySelection(sender) }
    }
    override func moveToBeginningOfLine(_ sender: Any?) {
        moveToLineBoundary(end: false, extending: false) { super.moveToBeginningOfLine(sender) }
    }
    override func moveToEndOfLine(_ sender: Any?) {
        moveToLineBoundary(end: true, extending: false) { super.moveToEndOfLine(sender) }
    }
    override func moveToLeftEndOfLine(_ sender: Any?) {
        moveToLineBoundary(end: false, extending: false) { super.moveToLeftEndOfLine(sender) }
    }
    override func moveToRightEndOfLine(_ sender: Any?) {
        moveToLineBoundary(end: true, extending: false) { super.moveToRightEndOfLine(sender) }
    }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        moveToLineBoundary(end: false, extending: true) { super.moveToBeginningOfLineAndModifySelection(sender) }
    }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        moveToLineBoundary(end: true, extending: true) { super.moveToEndOfLineAndModifySelection(sender) }
    }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        moveToLineBoundary(end: false, extending: true) { super.moveToLeftEndOfLineAndModifySelection(sender) }
    }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        moveToLineBoundary(end: true, extending: true) { super.moveToRightEndOfLineAndModifySelection(sender) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyPerspective()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift, .option],
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let attributed = NSPasteboard.general.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString,
           onPasteWithFormatting?(attributed) == true {
            return true
        }

        if let chord = KeyChord.from(event), !chord.isBare {
            let map = KeyMapStore.shared.map
            let format: FormatKey? =
                if map.chords(for: .boldSelection).contains(where: { $0.matches(chord) }) {
                    .bold
                } else if map.chords(for: .italicSelection).contains(where: { $0.matches(chord) }) {
                    .italic
                } else if map.chords(for: .underlineSelection).contains(where: { $0.matches(chord) }) {
                    .underline
                } else {
                    nil
                }
            if let format, onFormatKey?(format) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension EditorInteractionNSView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return model.canCopyObjects
        case #selector(paste(_:)):
            return model.canPaste
        default:
            return true
        }
    }
}

@MainActor
func drawEditorMarquee(_ rect: CGRect, in context: CGContext, accent: NSColor = .controlAccentColor) {
    context.saveGState()
    context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
    context.fill(rect)
    context.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
    context.setLineWidth(1)
    context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    context.restoreGState()
}
