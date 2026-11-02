import AppKit
import PresenterCore
import SwiftUI

enum NotePanelMetrics {
    static let header: CGFloat = 20

    static let pad: CGFloat = 6

    static let inset: CGFloat = 10

    static let gap: CGFloat = 12

    static let trailing: CGFloat = 3

    static let stackBelow: CGFloat = 420

    static func pictureWidth(column: CGFloat) -> CGFloat {
        guard column > 0 else { return 180 }
        return min(220, max(120, (column * 0.4 / 10).rounded() * 10))
    }

    static func layout(column: CGFloat) -> NotePanelLayout {
        column > 0 && column < stackBelow ? .stacked : .side
    }
}

enum NotePanelLayout: Equatable { case side, stacked }

final class NotePanelTag: NSObject {
    enum Part { case words, card, fold }
    static let key = NSAttributedString.Key("mxu.notePanel")

    static let spacerKey = NSAttributedString.Key("mxu.notePanelSpacer")
    static let spacerBaseKey = NSAttributedString.Key("mxu.notePanelSpacerBase")

    let panel: NotePanels.Panel
    let part: Part

    init(panel: NotePanels.Panel, part: Part) {
        self.panel = panel
        self.part = part
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NotePanelTag else { return false }
        return panel.id == other.panel.id && part == other.part
    }

    override var hash: Int { panel.id.hashValue }
}

final class NoteSizedHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?
    private var sizeCheckScheduled = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        scheduleSizeCheck()
    }

    func scheduleSizeCheck() {
        guard !sizeCheckScheduled else { return }
        sizeCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeCheckScheduled = false
            let size = self.fittingSize
            guard size.width > 0, size.height > 0, size != self.frame.size else { return }
            self.frame.size = size
            self.onSizeChange?()
        }
    }
}

typealias NoteSlideHostingView = NoteSizedHostingView<NoteSlideCardHost>
typealias NotePanelHostingView = NoteSizedHostingView<NotePanelPicturesHost>

struct NotePanelPicturesHost: View {
    let panel: NotePanels.Panel
    let attachments: [NoteSlideAttachment]
    weak var textView: NoteDocumentTextView?
    let context: NoteSlideContext?
    let style: NoteReaderStyle
    @ObservedObject var live: NoteSlideLive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachments.isEmpty {
                emptySlot
            } else {
                ForEach(attachments, id: \.self) { attachment in
                    NotePanelCardView(attachment: attachment, textView: textView, live: live, style: style)
                }
            }
        }
        .frame(width: style.pictureWidth, alignment: .leading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak textView] _ in
            textView?.panelHosts[panel.id]?.scheduleSizeCheck()
        }
    }

    private var emptySlot: some View {
        ZStack {
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.accentColor.opacity(0.6))
            if let make = context?.makeSlides {
                Button("Make Slides") { make() }.font(.caption)
            } else {
                Text("No slide yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(width: style.pictureWidth)
    }
}

struct NotePanelCardView: View {
    let attachment: NoteSlideAttachment
    weak var textView: NoteDocumentTextView?
    @ObservedObject var live: NoteSlideLive
    @ObservedObject var state: NoteSlideAttachment.State
    let style: NoteReaderStyle

    init(attachment: NoteSlideAttachment, textView: NoteDocumentTextView?, live: NoteSlideLive, style: NoteReaderStyle) {
        self.attachment = attachment
        self.textView = textView
        self.live = live
        self.state = attachment.state
        self.style = style
    }

    var body: some View {
        let editable = textView?.isEditable == true
        NoteSlideCard(
            slide: state.ref, style: style, context: attachment.context?.withLive(live.slideID),
            onChange: editable ? { changed in
                state.ref = changed
                textView?.attachmentDidChange(attachment)
            } : nil,
            onRemove: editable ? { textView?.removeAttachment(attachment) } : nil,
            availableWidth: style.pictureWidth, panel: true)
    }
}

extension NoteDocumentTextView {
    struct PanelGeometry {
        var panel: NotePanels.Panel
        var top: CGFloat
        var wordsTop: CGFloat
        var bottom: CGFloat
        var spacerRange: NSRange?
        var cards: [NoteSlideAttachment]
    }

    var drawsPanels: Bool { style.slideDisplay.drawsPanels }

    func panelGeometries() -> [PanelGeometry] {
        guard drawsPanels, let storage = textStorage, storage.length > 0, let manager = textLayoutManager else { return [] }
        var order: [String] = []
        var found: [String: (panel: NotePanels.Panel, ranges: [(NSRange, NotePanelTag.Part)])] = [:]
        storage.enumerateAttribute(NotePanelTag.key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let tag = value as? NotePanelTag else { return }
            if found[tag.panel.id] == nil {
                found[tag.panel.id] = (tag.panel, [])
                order.append(tag.panel.id)
            }
            found[tag.panel.id]?.ranges.append((range, tag.part))
        }
        let origin = textContainerOrigin
        let stacked = style.panelLayout == .stacked
        return order.compactMap { id -> PanelGeometry? in
            guard let entry = found[id] else { return nil }
            var top: CGFloat?
            var wordsTop: CGFloat?
            var bottom: CGFloat?
            var cards: [NoteSlideAttachment] = []
            for (range, part) in entry.ranges {
                if part == .card {
                    storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
                        if let card = value as? NoteSlideAttachment { cards.append(card) }
                    }
                }
                guard let textRange = textRange(for: range) else { continue }
                manager.ensureLayout(for: textRange)
                manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                    let line = frame.offsetBy(dx: origin.x, dy: origin.y)
                    top = min(top ?? line.minY, line.minY)
                    if part != .card { wordsTop = min(wordsTop ?? line.minY, line.minY) }

                    if part != .card || stacked { bottom = max(bottom ?? line.maxY, line.maxY) }
                    return true
                }
            }
            guard let top else { return nil }
            var spacer: NSRange?
            storage.enumerateAttribute(NotePanelTag.spacerKey, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value as? String == id {
                    spacer = range
                    stop.pointee = true
                }
            }
            return PanelGeometry(panel: entry.panel, top: top, wordsTop: wordsTop ?? top, bottom: bottom ?? top, spacerRange: spacer, cards: cards)
        }
    }

    func rebuildPanelHosts() {
        guard let storage = textStorage else { return }
        var wanted: [(panel: NotePanels.Panel, attachments: [NoteSlideAttachment])] = []
        if drawsPanels, style.panelLayout == .side, storage.length > 0 {
            var index: [String: Int] = [:]
            storage.enumerateAttribute(NotePanelTag.key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let tag = value as? NotePanelTag else { return }
                if index[tag.panel.id] == nil {
                    index[tag.panel.id] = wanted.count
                    wanted.append((tag.panel, []))
                }
                guard tag.part == .card, let slot = index[tag.panel.id] else { return }
                storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
                    if let card = value as? NoteSlideAttachment, card.panelHosted { wanted[slot].attachments.append(card) }
                }
            }
        }
        let keep = Set(wanted.map(\.panel.id))
        for (id, host) in panelHosts where !keep.contains(id) {
            host.removeFromSuperview()
            panelHosts[id] = nil
            panelHostCards[id] = nil
        }
        for entry in wanted {
            let ids = entry.attachments.map(ObjectIdentifier.init)
            let root = NotePanelPicturesHost(
                panel: entry.panel, attachments: entry.attachments, textView: self,
                context: dropContext?.0, style: style, live: dropContext?.1 ?? NoteSlideLive())
            if let host = panelHosts[entry.panel.id], panelHostCards[entry.panel.id] == ids {
                host.rootView = root
                continue
            }
            panelHosts[entry.panel.id]?.removeFromSuperview()
            let host = NotePanelHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.frame.size = host.fittingSize
            host.onSizeChange = { [weak self] in self?.schedulePanelLayout() }
            addSubview(host)
            panelHosts[entry.panel.id] = host
            panelHostCards[entry.panel.id] = ids
        }
        schedulePanelLayout()
    }

    func schedulePanelLayout() {
        guard !panelLayoutScheduled else { return }
        panelLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelLayoutScheduled = false
            self.positionPanels()
        }
    }

    private func positionPanels() {
        guard drawsPanels else { return }
        let right = bounds.width - textContainerInset.width
        var spacers: [(NSRange, CGFloat)] = []
        for geometry in panelGeometries() {
            var extra: CGFloat = 0
            if let host = panelHosts[geometry.panel.id] {
                let size = host.fittingSize
                let frame = NSRect(x: right - style.pictureWidth, y: geometry.wordsTop, width: style.pictureWidth, height: size.height)
                if host.frame != frame { host.frame = frame }
                extra = max(0, frame.maxY - geometry.bottom)
            }
            if let range = geometry.spacerRange { spacers.append((range, extra)) }
        }
        applyPanelSpacers(spacers)
        needsDisplay = true
    }

    private func applyPanelSpacers(_ spacers: [(NSRange, CGFloat)]) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let string = storage.string as NSString
        var edits: [(NSRange, NSParagraphStyle)] = []
        for (range, extra) in spacers {
            let location = min(range.location, storage.length - 1)
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let base = (storage.attribute(NotePanelTag.spacerBaseKey, at: location, effectiveRange: nil) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let current = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle.default
            let wanted = base + extra
            guard abs(current.paragraphSpacing - wanted) > 0.5, let style = current.mutableCopy() as? NSMutableParagraphStyle else { continue }
            style.paragraphSpacing = wanted
            edits.append((paragraph, style))
        }
        guard !edits.isEmpty else { return }
        storage.beginEditing()
        for (paragraph, style) in edits { storage.addAttribute(.paragraphStyle, value: style, range: paragraph) }
        storage.endEditing()
    }

    func panelsOutOfDate(for body: NoteBody) -> Bool {
        guard drawsPanels, let storage = textStorage else { return false }
        var tagged: [String: Int] = [:]
        if storage.length > 0 {
            storage.enumerateAttribute(NotePanelTag.key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let tag = value as? NotePanelTag else { return }
                var count = tagged[tag.panel.id] ?? 0
                if tag.part == .card {
                    storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
                        if value is NoteSlideAttachment { count += 1 }
                    }
                }
                tagged[tag.panel.id] = count
            }
        }
        var parsed: [String: Int] = [:]
        for panel in NotePanels.panels(in: body) { parsed[panel.id] = panel.cards.count }
        return tagged != parsed
    }

    func placePanelOverlay() {
        guard drawsPanels else {
            panelOverlay?.removeFromSuperview()
            panelOverlay = nil
            return
        }
        let view = panelOverlay ?? PanelOverlayView()
        view.owner = self
        if view.superview !== self { addSubview(view, positioned: .below, relativeTo: nil) }
        panelOverlay = view
        if view.frame != bounds {
            view.frame = bounds
            view.needsDisplay = true
        }
    }

    func drawPanels() {
        panelHits = []
        panelRects = []
        let geometries = panelGeometries()
        guard !geometries.isEmpty else { return }

        let left = textContainerOrigin.x - Self.gutter
        let right = bounds.width - textContainerInset.width + NotePanelMetrics.trailing
        for geometry in geometries {
            let panel = geometry.panel
            var bottom = geometry.bottom
            if let host = panelHosts[panel.id] { bottom = max(bottom, host.frame.maxY) }
            let top = geometry.top - NotePanelMetrics.header - NotePanelMetrics.pad
            let rect = NSRect(x: left, y: top, width: right - left, height: bottom + NotePanelMetrics.pad - top)
            panelRects.append((rect, geometry))
            let accent: NSColor = panel.made ? .systemGreen : .controlAccentColor
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.5
            path.stroke()

            if markGutter == 0 {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                accent.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            drawPanelHeader(geometry, in: rect, accent: accent)
        }
    }

    private func drawPanelHeader(_ geometry: PanelGeometry, in rect: NSRect, accent: NSColor) {
        let panel = geometry.panel
        let refs = geometry.cards.map(\.slide)
        let folded = style.isFolded(panel.id)
        let header = NSMutableAttributedString()
        func piece(_ text: String, color: NSColor, weight: NSFont.Weight = .regular) {
            if header.length > 0 { header.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 10)])) }
            header.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: weight), .foregroundColor: color]))
        }

        let model = dropContext?.0?.model
        let numbers = refs.compactMap { ref -> Int? in
            if let model, case .slide(_, _, let index) = NoteSlides.resolve(ref, presentation: { model.presentation($0) }) { return index + 1 }
            return ref.slideIndex.map { $0 + 1 }
        }
        if let title = NotePanels.title(slideNumbers: numbers) {
            piece(title, color: accent, weight: .semibold)
        } else if panel.placedByHand {
            piece("Placed here", color: .secondaryLabelColor, weight: .semibold)
        } else {
            piece(panel.type.map { $0.uppercased() } ?? "SLIDE", color: accent, weight: .semibold)
        }
        if let design = panelDesignName(refs) { piece(design, color: .secondaryLabelColor) }
        if let live = dropContext?.1.slideID, refs.contains(where: { $0.slideId == live }) { piece("LIVE", color: .systemGreen, weight: .bold) }
        if folded { piece(NotePanels.foldedTitle(lines: panel.lines), color: .secondaryLabelColor) }
        let behind = refs.first.map { dropContext?.0?.isBehind?($0) == true } ?? false
        let origin = NSPoint(x: rect.minX + NotePanelMetrics.inset + 4, y: rect.minY + NotePanelMetrics.pad + (NotePanelMetrics.header - header.size().height) / 2)
        header.draw(at: origin)
        var x = origin.x + header.size().width + 6
        if behind {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.minY + NotePanelMetrics.pad + NotePanelMetrics.header / 2 - 4, width: 8, height: 8)).fill()
            x += 14
        }
        let titleHit = NSRect(x: rect.minX, y: rect.minY, width: x - rect.minX, height: NotePanelMetrics.header + NotePanelMetrics.pad)
        if folded { panelHits.append((titleHit, geometry, .unfold)) }

        let dots = NSAttributedString(string: "•••", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.tertiaryLabelColor])
        let dotsSize = dots.size()
        let dotsRect = NSRect(x: rect.maxX - dotsSize.width - 10, y: rect.minY + NotePanelMetrics.pad + (NotePanelMetrics.header - dotsSize.height) / 2, width: dotsSize.width, height: dotsSize.height)
        dots.draw(at: dotsRect.origin)
        panelHits.append((dotsRect.insetBy(dx: -8, dy: -6), geometry, .menu))
    }

    private func panelDesignName(_ refs: [NoteSlideRef]) -> String? {
        guard let first = refs.first, let presentationId = first.presentationId, let slideId = first.slideId,
              let model = dropContext?.0?.model, let deck = model.presentation(presentationId),
              let slide = deck.slides.first(where: { $0.id == slideId }), let name = slide.themeSlideName, !name.isEmpty
        else { return nil }
        return name
    }

    func panelGeometry(at point: NSPoint) -> PanelGeometry? {
        panelRects.first { $0.rect.contains(point) }?.geometry
    }

    func panelMenuItems(_ geometry: PanelGeometry) -> [NSMenuItem] {
        let panel = geometry.panel
        var items: [NSMenuItem] = []
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = panel.id
            return item
        }
        if panel.made, dropContext?.0?.updateFromNote != nil, geometry.cards.first != nil {
            items.append(item("Update Slides from Note", #selector(updatePanelFromNote(_:))))
        }
        if !panel.made, !panel.placedByHand, onMakeSlides != nil {
            items.append(item("Make Slides…", #selector(makeSlideFromMenu(_:))))
        }
        if panel.words != nil, onFoldPanel != nil {
            items.append(item(style.isFolded(panel.id) ? "Unfold Words" : "Fold Words", #selector(togglePanelFold(_:))))
        }
        return items
    }

    func showPanelMenu(_ geometry: PanelGeometry, at point: NSPoint) {
        let items = panelMenuItems(geometry)
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func geometry(named id: String) -> PanelGeometry? {
        panelRects.first { $0.geometry.panel.id == id }?.geometry
    }

    @objc private func updatePanelFromNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let first = geometry(named: id)?.cards.first else { return }
        dropContext?.0?.updateFromNote?(first.slide)
    }

    @objc private func togglePanelFold(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onFoldPanel?(id)
    }

    func trackMargin(at point: NSPoint) {
        guard isEditable, onInsertSlideHere != nil, let storage = textStorage, storage.length > 0 else {
            clearMarginPlus()
            return
        }
        let right = bounds.width - textContainerInset.width
        guard point.x > right + 2 else {
            clearMarginPlus()
            return
        }
        let index = characterIndexForInsertion(at: NSPoint(x: textContainerInset.width + 1, y: point.y))
        let probe = min(max(0, index), storage.length - 1)
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: probe, length: 0))
        if marginPlus?.paragraph == paragraph || marginCandidate == paragraph { return }
        marginCandidate = paragraph
        marginToken += 1
        let token = marginToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { [weak self] in
            guard let self, self.marginToken == token else { return }
            self.showMarginPlus(paragraph)
        }
    }

    private func showMarginPlus(_ paragraph: NSRange) {
        guard let manager = textLayoutManager, let textRange = textRange(for: NSRange(location: paragraph.location, length: 0)) else { return }
        let origin = textContainerOrigin
        var first: NSRect?
        manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            first = frame.offsetBy(dx: origin.x, dy: origin.y)
            return false
        }
        guard let line = first else { return }
        let right = bounds.width - textContainerInset.width
        let rect = NSRect(x: right + 4, y: line.midY - 8, width: 16, height: 16)
        marginPlus = (paragraph, rect)
        needsDisplay = true
    }

    func clearMarginPlus() {
        marginCandidate = nil
        marginToken += 1
        guard marginPlus != nil else { return }
        marginPlus = nil
        needsDisplay = true
    }

    func drawMarginPlus() {
        guard let plus = marginPlus else { return }
        let color = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        color.setStroke()
        let circle = NSBezierPath(ovalIn: plus.rect.insetBy(dx: 0.5, dy: 0.5))
        circle.lineWidth = 1
        circle.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: plus.rect.midX - 4, y: plus.rect.midY))
        cross.line(to: NSPoint(x: plus.rect.midX + 4, y: plus.rect.midY))
        cross.move(to: NSPoint(x: plus.rect.midX, y: plus.rect.midY - 4))
        cross.line(to: NSPoint(x: plus.rect.midX, y: plus.rect.midY + 4))
        cross.lineWidth = 1.2
        cross.stroke()
    }

    func showMarginMenu(at point: NSPoint) {
        let menu = NSMenu()
        if onInsertSlideHere != nil {
            let insert = NSMenuItem(title: "Insert Slide Here…", action: #selector(insertSlideHereFromMenu(_:)), keyEquivalent: "")
            insert.target = self
            menu.addItem(insert)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func marginParagraphContent() -> NSRange? {
        guard let plus = marginPlus, let storage = textStorage else { return nil }
        var range = plus.paragraph
        if range.length > 0, (storage.string as NSString).character(at: range.location + range.length - 1) == 0x0A { range.length -= 1 }
        return range
    }

    @objc private func insertSlideHereFromMenu(_ sender: NSMenuItem) {
        guard let range = marginParagraphContent() else { return }
        setSelectedRange(NSRange(location: range.location + range.length, length: 0))
        window?.makeFirstResponder(self)
        clearMarginPlus()
        onInsertSlideHere?()
    }
}

final class PanelOverlayView: NSView {
    weak var owner: NoteDocumentTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawPanels()
    }
}
