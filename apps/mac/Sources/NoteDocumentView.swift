import AppKit
import AVFoundation
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

struct NoteDocumentView: NSViewRepresentable {
    let body: NoteBody
    let style: NoteReaderStyle
    let query: String
    let slides: NoteSlideContext?
    let live: NoteSlideLive
    let scroller: NoteDocumentScroller

    let maxLineWidth: CGFloat?

    var editable: Bool = false

    var onEdit: ((NoteBody) -> Void)? = nil

    var slideRefForDrop: ((_ presentationId: String, _ slideId: String) -> NoteSlideRef?)? = nil

    var slideRefForPaste: ((_ afterSlideId: String?) -> NoteSlideRef?)? = nil

    var onMakeSlides: (() -> Void)? = nil

    var onFoldPanel: ((_ panelId: String) -> Void)? = nil
    var onInsertSlideHere: (() -> Void)? = nil

    var fitsContent: Bool = false
    var metrics: NoteLayoutMetrics? = nil

    var marksInMargin: Bool = false

    var selectedGroup: String? = nil

    var onSelectGroup: ((String?) -> Void)? = nil

    var onSelectionPreview: ((NoteBody?) -> Void)? = nil

    var onNotesArrive: ((NSAttributedString) -> Void)? = nil

    var kindMenuExtras: ((_ group: String, _ type: String?) -> [NSMenuItem])? = nil

    var parenthesesToNotes = true

    var parenthesesByGroup: [String: Bool] = [:]
    @ObservedObject private var images = NoteImageStore.shared

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteDocumentTextView(usingTextLayoutManager: true)

        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.delegate = context.coordinator
        textView.style = renderStyle
        textView.dropContext = (slides, live)
        textView.slideRefForDrop = slideRefForDrop
        textView.slideRefForPaste = slideRefForPaste
        textView.onMakeSlides = onMakeSlides
        textView.onFoldPanel = onFoldPanel
        textView.onInsertSlideHere = onInsertSlideHere
        textView.marksInMargin = marksInMargin
        textView.selectedGroup = selectedGroup
        textView.onSelectGroup = onSelectGroup
        textView.onSelectionPreview = onSelectionPreview
        textView.onNotesArrive = onNotesArrive
        textView.kindMenuExtras = kindMenuExtras
        textView.parenthesesToNotes = parenthesesToNotes
        textView.parenthesesByGroup = parenthesesByGroup

        if let metrics { textView.metrics = metrics }
        textView.fitsContent = fitsContent

        let scroll = fitsContent ? NoteFittingScrollView() : NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = !fitsContent
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if fitsContent { scroll.verticalScrollElasticity = .none }
        scroller.textView = textView
        rebuild(textView, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NoteDocumentTextView else { return }
        textView.horizontalInset = maxLineWidth
        if textView.isEditable != editable {
            textView.isEditable = editable

            textView.updateMarkGutter()
        }
        textView.style = renderStyle
        textView.dropContext = (slides, live)
        textView.slideRefForDrop = slideRefForDrop
        textView.slideRefForPaste = slideRefForPaste
        textView.onMakeSlides = onMakeSlides
        textView.onFoldPanel = onFoldPanel
        textView.onInsertSlideHere = onInsertSlideHere
        textView.marksInMargin = marksInMargin
        textView.selectedGroup = selectedGroup
        textView.onSelectGroup = onSelectGroup
        textView.onSelectionPreview = onSelectionPreview
        textView.onNotesArrive = onNotesArrive
        textView.kindMenuExtras = kindMenuExtras
        if textView.parenthesesToNotes != parenthesesToNotes || textView.parenthesesByGroup != parenthesesByGroup {
            textView.parenthesesToNotes = parenthesesToNotes
            textView.parenthesesByGroup = parenthesesByGroup
            textView.greyOffScreenWords()
        }
        context.coordinator.onEdit = onEdit
        rebuild(textView, context: context)
    }

    private var renderStyle: NoteReaderStyle {
        var style = style
        style.editable = editable
        return style
    }

    private func rebuild(_ textView: NoteDocumentTextView, context: Context) {
        let style = renderStyle
        let signature = NoteDocumentRenderer.Signature(body: body, style: style, query: query, imagesVersion: images.version)
        guard context.coordinator.signature != signature else { return }

        let unchangedText = context.coordinator.signature?.style == style
            && context.coordinator.signature?.query == query && context.coordinator.signature?.imagesVersion == images.version

        if unchangedText, let edited = context.coordinator.lastEdited,
           NoteDocumentRenderer.sameContent(edited.blocks, body.blocks) {
            context.coordinator.signature = signature
            return
        }
        let previous = context.coordinator.signature?.body
        context.coordinator.signature = signature
        context.coordinator.lastEdited = nil
        let selection = textView.selectedRange()
        let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin

        let anchor = unchangedText && previous != nil ? textView.topAnchor(blockRanges: scroller.blockRanges) : nil
        let rendered = NoteDocumentRenderer.render(body, style: style, query: query, slides: slides, live: live)
        textView.textStorage?.setAttributedString(rendered.text)
        textView.updateMarkGutter()
        textView.rebuildPanelHosts()
        scroller.blockRanges = rendered.blockRanges
        textView.blockRanges = rendered.blockRanges
        if selection.location <= rendered.text.length {
            textView.setSelectedRange(NSRange(location: min(selection.location, rendered.text.length), length: 0))
        }

        if let scrollOrigin, let clip = textView.enclosingScrollView?.contentView {
            if let anchor, let previous, !rendered.blockRanges.isEmpty {
                let block = NoteReading.block(anchor.block, from: previous.blocks, to: body.blocks)
                textView.restoreScroll(toBlockAt: rendered.blockRanges[block].location, offset: anchor.offset, x: scrollOrigin.x, in: clip)
            } else {
                textView.restoreScroll(to: scrollOrigin, in: clip)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var signature: NoteDocumentRenderer.Signature?
        var onEdit: ((NoteBody) -> Void)?
        var lastEdited: NoteBody?
        private var redrawingPanels = false

        init(onEdit: ((NoteBody) -> Void)?) { self.onEdit = onEdit }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteDocumentTextView, let storage = textView.textStorage else { return }
            let body = NoteDocumentParser.body(from: storage)
            lastEdited = body
            onEdit?(body)

            if !redrawingPanels, textView.panelsOutOfDate(for: body) {
                redrawingPanels = true
                textView.replaceBody(with: body, slides: textView.dropContext?.0, live: textView.dropContext?.1 ?? NoteSlideLive())
                redrawingPanels = false
            } else {
                textView.rebuildPanelHosts()
            }
            textView.updateMarkGutter()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NoteDocumentTextView else { return }
            view.reportSelectedGroup()
            view.updateSelectionBar()
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            guard new.length == 0, let storage = textView.textStorage, new.location < storage.length else { return new }
            var marker = NSRange()
            guard storage.attribute(NoteBlockMarker.prefixKey, at: new.location, longestEffectiveRange: &marker,
                                    in: NSRange(location: 0, length: storage.length)) != nil else { return new }
            let backFromWords = old.length == 0 && old.location == NSMaxRange(marker) && new.location < old.location
            return NSRange(location: backFromWords && marker.location > 0 ? marker.location - 1 : NSMaxRange(marker), length: 0)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let view = textView as? NoteDocumentTextView, view.isEditable else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return view.takeSelectionBarGuess() || view.insertNewlineKeepingBlock()
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), view.selectionBar != nil {
                view.hideSelectionBar()
                return true
            }
            return false
        }
    }
}

final class NoteDocumentTextView: NSTextView {
    var blockRanges: [NSRange] = []
    var horizontalInset: CGFloat? {
        didSet { if horizontalInset != oldValue { needsLayout = true; applyInset() } }
    }
    var style = NoteReaderStyle(fontSize: 14, compact: true)
    var dropContext: (NoteSlideContext?, NoteSlideLive)?
    var metrics = NoteLayoutMetrics()

    var fitsContent = false

    override var typingAttributes: [NSAttributedString.Key: Any] {
        get {
            var attributes = super.typingAttributes
            guard attributes[NoteBlockMarker.prefixKey] != nil else { return attributes }
            attributes[NoteBlockMarker.prefixKey] = nil
            attributes[.foregroundColor] = NSColor.labelColor
            return attributes
        }
        set { super.typingAttributes = newValue }
    }
    var slideRefForDrop: ((String, String) -> NoteSlideRef?)?
    var slideRefForPaste: ((String?) -> NoteSlideRef?)?
    var onMakeSlides: (() -> Void)?

    private static func slideDrop(from pasteboard: NSPasteboard) -> (presentationId: String, slideId: String)? {
        guard let payload = pasteboard.string(forType: .string), payload.hasPrefix("mxuslide::") else { return nil }
        let parts = payload.split(separator: "::", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[1], parts[2])
    }

    private func mediaFiles(_ sender: any NSDraggingInfo) -> [URL] {
        guard isEditable else { return [] }
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.movie.identifier],
        ]) as? [URL] ?? []
    }

    func insertDroppedFiles(_ files: [URL], at location: Int) {
        guard let save = NoteMediaFiles.save else { return }
        Task { [weak self] in
            let blocks = await Task.detached(priority: .userInitiated) { files.compactMap { NoteFileReader.mediaBlock(file: $0, save: save) } }.value
            guard let self, !blocks.isEmpty, let storage = textStorage else { return }
            setSelectedRange(NSRange(location: min(location, storage.length), length: 0))
            insertPasted(NoteBody(blocks: blocks, plainText: ""))
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if pictureDrop(sender) != nil || !mediaFiles(sender).isEmpty { return .copy }
        guard isEditable, Self.slideDrop(from: sender.draggingPasteboard) != nil else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if pictureDrop(sender) != nil { return .copy }
        if !mediaFiles(sender).isEmpty {
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
            return .copy
        }
        guard isEditable, Self.slideDrop(from: sender.draggingPasteboard) != nil else { return [] }

        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: index, length: 0))
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let picture = pictureDrop(sender) { return replaceMissingPicture(at: picture.range, with: picture.file) }
        let files = mediaFiles(sender)
        if !files.isEmpty, let storage = textStorage {
            insertDroppedFiles(files, at: min(characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), storage.length))
            return true
        }
        guard isEditable, let drop = Self.slideDrop(from: sender.draggingPasteboard),
              let ref = slideRefForDrop?(drop.presentationId, drop.slideId),
              let storage = textStorage, let (context, live) = dropContext else { return false }
        _ = (context, live)
        let point = convert(sender.draggingLocation, from: nil)
        insertSlide(ref, at: min(characterIndexForInsertion(at: point), storage.length))
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [SlidePasteboard.type, .png, .tiff, .rtfd, .init("com.apple.flat-rtfd")]
    }

    override func paste(_ sender: Any?) {
        if isEditable, !SlidePasteboard.hasSlide, let onNotesArrive,
           textStorage?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let pasted = NSPasteboard.general.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString,
           !pasted.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return onNotesArrive(pasted)
        }

        if isEditable, !SlidePasteboard.hasSlide, let body = Self.pastedMedia(from: .general) {
            return insertPasted(body)
        }

        if isEditable, !SlidePasteboard.hasSlide, let body = Self.pastedBlocks(from: .general) {
            return insertPasted(body)
        }
        guard isEditable, SlidePasteboard.hasSlide, let slideRefForPaste else { return super.paste(sender) }
        guard let ref = slideRefForPaste(cardSlideId(before: selectedRange().location)) else { return }
        insertSlide(ref)
    }

    static func pastedBlocks(from pasteboard: NSPasteboard) -> NoteBody? {
        guard pasteboard.availableType(from: [.rtf, .rtfd, .html]) != nil,
              let pasted = pasteboard.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString,
              pasted.string.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") else { return nil }
        let body = NoteFileReader.body(attributed: pasted, save: NoteMediaFiles.save)
        return body.blocks.isEmpty ? nil : body
    }

    static func pastedMedia(from pasteboard: NSPasteboard) -> NoteBody? {
        guard let save = NoteMediaFiles.save else { return nil }
        if let pasted = pasteboard.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString,
           pasted.containsAttachments(in: NSRange(location: 0, length: pasted.length)) {
            let body = NoteFileReader.body(attributed: pasted, save: save)
            return NoteMedia.blocks(in: body).isEmpty ? nil : body
        }

        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            guard let data = pasteboard.data(forType: type) else { continue }
            let png = ext == "png" ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            guard let png, let url = save(png, "Pasted Picture.png") else { return nil }
            return NoteBody(blocks: [NoteBlock(type: .image, url: url)], plainText: "")
        }
        return nil
    }

    private func insertPasted(_ body: NoteBody) {
        guard let storage = textStorage, let (context, live) = dropContext else { return }
        let range = selectedRange()
        let string = storage.string as NSString
        let inserted = NSMutableAttributedString()
        if range.location > 0, string.character(at: range.location - 1) != 0x0A { inserted.append(NSAttributedString(string: "\n")) }
        inserted.append(NoteDocumentRenderer.render(body, style: style, query: "", slides: context, live: live).text)
        let end = range.location + range.length
        if end < string.length, string.character(at: end) != 0x0A { inserted.append(NSAttributedString(string: "\n")) }
        insertText(inserted, replacementRange: range)
        typingAttributes = NoteDocumentRenderer.attributes(for: .paragraph, style: style)
    }

    private func cardSlideId(before location: Int) -> String? {
        guard let storage = textStorage, location > 0 else { return nil }
        var found: String?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: min(location, storage.length))) { value, _, _ in
            if let card = value as? NoteSlideAttachment, let id = card.state.ref.slideId { found = id }
        }
        return found
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "b"): toggleMark(.bold); return true
        case ([.command], "i"): toggleMark(.italic); return true
        case ([.command], "u"): toggleMark(.underline); return true
        case ([.command, .shift], "x"): toggleMark(.strike); return true
        case ([.command, .shift], "h"): toggleMark(.highlight); return true
        case ([.command, .option], "s"): markWillBeSlide(type: nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func markRange() -> NSRange? {
        guard let storage = textStorage else { return nil }
        var range = selectedRange()
        if range.length == 0 {
            let string = storage.string as NSString
            range = string.paragraphRange(for: range)
            if range.length > 0, string.character(at: range.location + range.length - 1) == 0x0A { range.length -= 1 }
        }
        return range.length > 0 ? range : nil
    }

    func markWillBeSlide(type: String?) {
        guard isEditable, let storage = textStorage, let range = markRange(),
              shouldChangeText(in: range, replacementString: nil) else { return }
        let mark = NoteSlideMark(group: NoteSlideMarks.mintGroupID(), type: type)
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            if attributes[NoteBlockMarker.prefixKey] != nil || attributes[.attachment] != nil { return }
            storage.addAttribute(NoteBlockMarker.slideKey, value: mark, range: subrange)
        }
        storage.endEditing()
        didChangeText()
        needsDisplay = true
    }

    func unmarkWillBeSlide() {
        guard isEditable, let storage = textStorage, let range = markRange() else { return }
        let groups = slideGroups(in: range)
        guard !groups.isEmpty else { return }
        let whole = NSRange(location: 0, length: storage.length)
        guard shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(NoteBlockMarker.slideKey, in: whole) { value, subrange, _ in
            guard let mark = value as? NoteSlideMark, groups.contains(mark.group) else { return }
            if let declined = Self.removing(mark) {
                storage.addAttribute(NoteBlockMarker.slideKey, value: declined, range: subrange)
            } else {
                storage.removeAttribute(NoteBlockMarker.slideKey, range: subrange)
            }
        }
        storage.endEditing()
        didChangeText()
        needsDisplay = true
    }

    var selectionIsWillBeSlide: Bool {
        markRange().map { !slideGroups(in: $0).isEmpty } ?? false
    }

    private func slideGroups(in range: NSRange) -> Set<String> {
        guard let storage = textStorage else { return [] }
        var groups: Set<String> = []
        storage.enumerateAttribute(NoteBlockMarker.slideKey, in: range) { value, _, _ in
            if let mark = value as? NoteSlideMark, mark.state != NoteSlideMarks.declined { groups.insert(mark.group) }
        }
        return groups
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()

        if let geometry = panelGeometry(at: convert(event.locationInWindow, from: nil)) {
            let items = panelMenuItems(geometry)
            if !items.isEmpty {
                for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
                menu.insertItem(.separator(), at: items.count)
            }
        }
        guard isEditable else { return menu }
        let mark = NSMenuItem(title: "Will Be Slide", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let plain = NSMenuItem(title: "Slide", action: #selector(markSlideFromMenu(_:)), keyEquivalent: "s")
        plain.keyEquivalentModifierMask = [.command, .option]
        plain.target = self
        submenu.addItem(plain)
        submenu.addItem(.separator())
        for type in NoteSlideMarks.SlideType.textKinds {
            let item = NSMenuItem(title: type.label, action: #selector(markSlideFromMenu(_:)), keyEquivalent: "")
            item.representedObject = type.rawValue
            item.target = self
            submenu.addItem(item)
        }
        mark.submenu = submenu
        var items: [NSMenuItem] = []
        if onMakeSlides != nil {
            let make = NSMenuItem(title: "Make Slide…", action: #selector(makeSlideFromMenu(_:)), keyEquivalent: "")
            make.target = self
            items.append(make)
        }
        items.append(mark)
        if selectionIsWillBeSlide {
            let remove = NSMenuItem(title: "Remove from slides", action: #selector(unmarkSlideFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            items.append(remove)
        }
        items.append(.separator())
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }

    @objc private func markSlideFromMenu(_ sender: NSMenuItem) {
        markWillBeSlide(type: sender.representedObject as? String)
    }

    @objc func makeSlideFromMenu(_ sender: NSMenuItem) {
        if !selectionIsWillBeSlide { markWillBeSlide(type: nil) }
        onMakeSlides?()
    }

    @objc private func unmarkSlideFromMenu(_ sender: NSMenuItem) {
        unmarkWillBeSlide()
    }

    var slideTagHits: [(rect: NSRect, mark: NoteSlideMark)] = []

    var marksInMargin = false {
        didSet { if marksInMargin != oldValue { updateMarkGutter() } }
    }
    var selectedGroup: String? {
        didSet { if selectedGroup != oldValue { needsDisplay = true } }
    }
    var onSelectGroup: ((String?) -> Void)?
    var kindMenuExtras: ((_ group: String, _ type: String?) -> [NSMenuItem])?
    var parenthesesToNotes = true
    var parenthesesByGroup: [String: Bool] = [:]
    var reportedGroup: String?

    var markGutter: CGFloat = 0
    var markLabelHits: [(rect: NSRect, group: String)] = []
    var markBoxes: [(rect: NSRect, group: String)] = []
    var hoveredGroup: String?
    var hoveredLabel: String?
    var gutterView: MarginGutterView?
    var panelOverlay: PanelOverlayView?

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        panelOverlay?.setNeedsDisplay(invalidRect)
    }

    var selectionBar: NoteSelectionBarView?
    var onSelectionPreview: ((NoteBody?) -> Void)?
    var onNotesArrive: ((NSAttributedString) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        placePanelOverlay()
        if drawsPanels {
            slideTagHits = []
            if markGutter > 0 { drawMarginMarks(tinted: false) }
        } else {
            panelHits = []
            panelRects = []
            if markGutter > 0 { drawMarginMarks(tinted: true) } else { drawSlideMarks() }
        }
        drawMarginPlus()
    }

    func drawSlideMarks() {
        slideTagHits = []
        guard let storage = textStorage, storage.length > 0, let manager = textLayoutManager else { return }
        var groups: [(mark: NoteSlideMark, ranges: [NSRange])] = []
        storage.enumerateAttribute(NoteBlockMarker.slideKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let mark = value as? NoteSlideMark, mark.state != NoteSlideMarks.declined else { return }
            if let index = groups.firstIndex(where: { $0.mark.group == mark.group }) {
                groups[index].ranges.append(range)
                if groups[index].mark.slideId == nil, mark.slideId != nil { groups[index].mark = mark }
            } else {
                groups.append((mark, [range]))
            }
        }
        guard !groups.isEmpty else { return }
        let origin = textContainerOrigin
        let right = bounds.width - textContainerInset.width
        for group in groups {
            let made = group.mark.slideId != nil
            let color: NSColor = made ? .systemGreen : .controlAccentColor
            var last: NSRect?
            for range in group.ranges {
                guard let textRange = textRange(for: range) else { continue }
                manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                    let line = frame.offsetBy(dx: origin.x, dy: origin.y)
                    color.withAlphaComponent(0.07).setFill()
                    line.fill()
                    color.setFill()
                    NSRect(x: line.minX - 6, y: line.minY, width: 2.5, height: line.height).fill()
                    last = line
                    return true
                }
            }
            guard let last else { continue }
            let title = tagTitle(for: group.mark)
            let tag = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: color,
            ])
            let size = tag.size()
            let x = last.maxX + 8
            guard x + size.width + 8 <= right else { continue }
            let box = NSRect(x: x, y: last.midY - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            tag.draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1))
            slideTagHits.append((box, group.mark))
        }
    }

    func tagTitle(for mark: NoteSlideMark) -> String {
        if let slideId = mark.slideId, let index = cardIndex(ofSlide: slideId) { return "SLIDE \(index + 1)" }
        if let type = mark.type, !type.isEmpty { return type.uppercased() }
        return "SLIDE"
    }

    func cardIndex(ofSlide slideId: String) -> Int? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let card = value as? NoteSlideAttachment, card.slide.slideId == slideId {
                found = card.slide.slideIndex
                stop.pointee = true
            }
        }
        return found
    }

    func textRange(for range: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func scrollToCard(ofSlide slideId: String) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let card = value as? NoteSlideAttachment, card.slide.slideId == slideId {
                scrollRangeToVisible(range)
                stop.pointee = true
            }
        }
    }

    var panelHosts: [String: NotePanelHostingView] = [:]
    var panelHostCards: [String: [ObjectIdentifier]] = [:]
    var panelLayoutScheduled = false
    enum PanelHit { case unfold, menu }
    var panelHits: [(rect: NSRect, geometry: PanelGeometry, hit: PanelHit)] = []
    var panelRects: [(rect: NSRect, geometry: PanelGeometry)] = []
    var onFoldPanel: ((String) -> Void)?
    var onInsertSlideHere: (() -> Void)?
    var marginPlus: (paragraph: NSRange, rect: NSRect)?
    var marginCandidate: NSRange?
    var marginToken = 0
    private var marginTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let marginTracking { removeTrackingArea(marginTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        marginTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        trackMargin(at: point)
        trackMarkHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearMarginPlus()
        if hoveredGroup != nil || hoveredLabel != nil {
            hoveredGroup = nil
            hoveredLabel = nil
            needsDisplay = true
        }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        (super.accessibilityCustomActions() ?? []) + missingPictureActions
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for hit in markLabelHits { addCursorRect(hit.rect, cursor: .pointingHand) }
    }

    enum Mark { case bold, italic, underline, strike, highlight }

    func toggleMark(_ mark: Mark) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else {
            typingAttributes = NoteDocumentRenderer.toggled(mark, in: typingAttributes, on: nil)
            return
        }
        let on = !NoteDocumentRenderer.hasMark(mark, storage.attributes(at: range.location, effectiveRange: nil))

        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            if attributes[NoteBlockMarker.prefixKey] != nil || attributes[.attachment] != nil { return }
            storage.setAttributes(NoteDocumentRenderer.toggled(mark, in: attributes, on: on), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    func setBlockKind(_ kind: NoteBlockMarker.Kind, at location: Int? = nil) {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        let selection = location.map { NSRange(location: $0, length: 0) } ?? selectedRange()
        var paragraphRange = string.paragraphRange(for: selection)

        if paragraphRange.length > 0, string.character(at: paragraphRange.location + paragraphRange.length - 1) == 0x0A {
            paragraphRange.length -= 1
        }
        let runs = NoteDocumentParser.runs(in: storage, range: paragraphRange)
        let rendered = NoteDocumentRenderer.paragraph(kind, runs: runs, style: style)

        replaceKeepingAttributes(paragraphRange, with: rendered)
        setSelectedRange(NSRange(location: paragraphRange.location + rendered.length, length: 0))
    }

    func insertSlide(_ ref: NoteSlideRef, at location: Int? = nil) {
        guard let storage = textStorage, let (context, live) = dropContext else { return }
        let index = min(location ?? selectedRange().location, storage.length)
        let attachment = NoteSlideAttachment(slide: ref, style: style, context: context, live: live)
        let card = NSMutableAttributedString(attachment: attachment)
        card.addAttribute(NoteBlockMarker.key, value: NoteBlockMarker(.slide), range: NSRange(location: 0, length: card.length))
        let string = storage.string as NSString
        let atParagraphStart = index == 0 || string.character(at: index - 1) == 0x0A
        let inserted = NSMutableAttributedString()
        if !atParagraphStart { inserted.append(NSAttributedString(string: "\n")) }
        inserted.append(card)
        inserted.append(NSAttributedString(string: "\n"))
        inserted.append(NoteDocumentRenderer.paragraph(.paragraph, runs: [], style: style))
        insertText(inserted, replacementRange: NSRange(location: index, length: 0))
        typingAttributes = NoteDocumentRenderer.attributes(for: .paragraph, style: style)

        window?.makeFirstResponder(self)
    }

    func replaceBody(with body: NoteBody, slides: NoteSlideContext?, live: NoteSlideLive) {
        guard let storage = textStorage else { return }
        let scrollOrigin = enclosingScrollView?.contentView.bounds.origin
        let selection = selectedRange()
        let rendered = NoteDocumentRenderer.render(body, style: style, query: "", slides: slides, live: live)
        replaceKeepingAttributes(NSRange(location: 0, length: storage.length), with: rendered.text)
        rebuildPanelHosts()
        if selection.location <= rendered.text.length {
            setSelectedRange(NSRange(location: selection.location, length: min(selection.length, rendered.text.length - selection.location)))
        }
        if let scrollOrigin, let clip = enclosingScrollView?.contentView {
            layoutSubtreeIfNeeded()
            clip.scroll(to: scrollOrigin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func topAnchor(blockRanges: [NSRange]) -> (block: Int, offset: CGFloat)? {
        let top = visibleRect.minY
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let fragment = manager.textLayoutFragment(for: CGPoint(x: 0, y: top - textContainerOrigin.y)) else { return nil }
        let character = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard let block = blockRanges.lastIndex(where: { $0.location <= character }),
              let blockTop = self.top(ofCharacter: blockRanges[block].location) else { return nil }
        return (block, top - blockTop)
    }

    private func top(ofCharacter index: Int) -> CGFloat? {
        guard let manager = textLayoutManager, let range = textRange(for: NSRange(location: index, length: 0)),
              let fragment = manager.textLayoutFragment(for: range.location) else { return nil }
        return fragment.layoutFragmentFrame.minY + textContainerOrigin.y
    }

    func restoreScroll(toBlockAt character: Int, offset: CGFloat, x: CGFloat, in clip: NSClipView) {
        if let manager = textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        layoutSubtreeIfNeeded()
        guard let blockTop = top(ofCharacter: character) else { return }
        restoreScroll(to: CGPoint(x: x, y: max(0, blockTop + offset)), in: clip)
    }

    func restoreScroll(to origin: CGPoint, in clip: NSClipView) {
        if let manager = textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        layoutSubtreeIfNeeded()
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)

        DispatchQueue.main.async { [weak self, weak clip] in
            guard let self, let clip else { return }
            clip.scroll(to: origin)
            self.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    func attachmentDidChange(_ attachment: NSTextAttachment) {
        guard let manager = textLayoutManager else { return }
        invalidateLayout(of: attachment)
        manager.ensureLayout(for: manager.documentRange)
        needsLayout = true
        didChangeText()
    }

    func attachmentPreviewDidChange(_ attachment: NSTextAttachment) {
        invalidateLayout(of: attachment)
        needsLayout = true
    }

    func attachmentSizeDidChange(_ attachment: NSTextAttachment) {
        schedulePanelLayout()
        guard let manager = textLayoutManager else { return }
        invalidateLayout(of: attachment)
        manager.ensureLayout(for: manager.documentRange)
        needsLayout = true
        needsDisplay = true
    }

    private func invalidateLayout(of attachment: NSTextAttachment) {
        guard let manager = textLayoutManager, let storage = textStorage else { return }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as AnyObject === attachment { found = range; stop.pointee = true }
        }
        let content = manager.textContentManager
        if let found, let content,
           let start = content.location(content.documentRange.location, offsetBy: found.location),
           let end = content.location(start, offsetBy: found.length),
           let textRange = NSTextRange(location: start, end: end) {
            manager.invalidateLayout(for: textRange)
        } else {
            manager.invalidateLayout(for: manager.documentRange)
        }
    }

    func removeAttachment(_ attachment: NSTextAttachment) {
        guard let storage = textStorage else { return }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as AnyObject === attachment { found = range; stop.pointee = true }
        }
        guard var range = found else { return }
        let string = storage.string as NSString

        if range.location + range.length < string.length, string.character(at: range.location + range.length) == 0x0A {
            range.length += 1
        }
        insertText("", replacementRange: range)
    }

    override func mouseDown(with event: NSEvent) {
        let clicked = convert(event.locationInWindow, from: nil)
        if handleMarginMarkClick(at: clicked) { return }
        if let hit = panelHits.first(where: { $0.rect.contains(clicked) }) {
            switch hit.hit {
            case .unfold: onFoldPanel?(hit.geometry.panel.id)
            case .menu: showPanelMenu(hit.geometry, at: clicked)
            }
            return
        }
        if let plus = marginPlus, plus.rect.insetBy(dx: -4, dy: -4).contains(clicked) {
            showMarginMenu(at: clicked)
            return
        }
        if let hit = slideTagHits.first(where: { $0.rect.contains(clicked) }), let slideId = hit.mark.slideId {
            scrollToCard(ofSlide: slideId)
            return
        }
        if isEditable, handleMissingPictureClick(at: clicked) { return }
        if isEditable, let storage = textStorage, storage.length > 0 {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            let probe = min(index, storage.length - 1)
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: probe, length: 0))
            let prefix = NoteBlockMarker.prefixLength(of: string.substring(with: paragraph))
            if prefix > 0, probe < paragraph.location + prefix,
               let marker = storage.attribute(NoteBlockMarker.key, at: probe, effectiveRange: nil) as? NoteBlockMarker,
               case .taskItem(let checked, let depth) = marker.kind {
                setBlockKind(.taskItem(checked: !checked, depth: depth), at: probe)
                return
            }
        }
        super.mouseDown(with: event)

        updateSelectionBar()
    }

    func insertNewlineKeepingBlock() -> Bool {
        guard let storage = textStorage else { return false }
        let string = storage.string as NSString
        let selection = selectedRange()
        var paragraphRange = string.paragraphRange(for: selection)
        if paragraphRange.length > 0, string.character(at: paragraphRange.location + paragraphRange.length - 1) == 0x0A {
            paragraphRange.length -= 1
        }
        let marker = paragraphRange.location < storage.length
            ? storage.attribute(NoteBlockMarker.key, at: paragraphRange.location, effectiveRange: nil) as? NoteBlockMarker
            : typingAttributes[NoteBlockMarker.key] as? NoteBlockMarker
        switch marker?.kind {
        case .listItem, .taskItem:
            let content = NoteDocumentParser.runs(in: storage, range: paragraphRange).map(\.text).joined()
            if content.isEmpty {
                setBlockKind(.paragraph)
                return true
            }
            let next: NoteBlockMarker.Kind = switch marker!.kind {
            case .listItem(let ordered, let depth): .listItem(ordered: ordered, depth: depth)
            case .taskItem(_, let depth): .taskItem(checked: false, depth: depth)
            default: .paragraph
            }
            let rendered = NSMutableAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: style.fontSize)])
            rendered.append(NoteDocumentRenderer.paragraph(next, runs: [], style: style))

            if paragraphRange.location < storage.length, rendered.length > 1,
               let current = (storage.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle {
                current.paragraphSpacingBefore = 0
                rendered.addAttribute(.paragraphStyle, value: current, range: NSRange(location: 1, length: rendered.length - 1))
            }
            insertText(rendered, replacementRange: selection)

            typingAttributes[NoteBlockMarker.slideKey] = nil
            return true
        case .heading:
            insertText(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: style.fontSize)]), replacementRange: selection)

            let start = selectedRange().location
            setBlockKind(.paragraph, at: start)
            setSelectedRange(NSRange(location: start, length: 0))
            typingAttributes = NoteDocumentRenderer.attributes(for: .paragraph, style: style)
            return true
        default:

            guard typingAttributes[NoteBlockMarker.slideKey] != nil else { return false }
            insertNewline(nil)
            typingAttributes[NoteBlockMarker.slideKey] = nil
            return true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyInset()
        placeGutterView()
        placeSelectionBar()
    }

    override func layout() {
        super.layout()
        schedulePanelLayout()
        guard fitsContent, let manager = textLayoutManager else { return }
        manager.ensureLayout(for: manager.documentRange)
        let height = ceil(manager.usageBoundsForTextContainer.height + textContainerInset.height * 2 + leadingPanelRoom)
        guard height > 0, abs(metrics.contentHeight - height) > 0.5 else { return }
        let metrics = metrics
        DispatchQueue.main.async { metrics.contentHeight = height }
    }

    static let gutter: CGFloat = 8

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.x += markGutter
        origin.y += leadingPanelRoom
        return origin
    }

    var leadingPanelRoom: CGFloat {
        guard drawsPanels, let storage = textStorage, storage.length > 0,
              storage.attribute(NotePanelTag.key, at: 0, effectiveRange: nil) != nil else { return 0 }
        return NotePanelMetrics.header + NotePanelMetrics.pad * 2
    }

    func applyInset() {
        let width = bounds.width
        let side: CGFloat = (horizontalInset.map { max(0, (width - $0) / 2) } ?? 0) + Self.gutter
        let inset = NSSize(width: side, height: 12)
        if textContainerInset != inset { textContainerInset = inset }
        let column = max(0, width - side * 2 - markGutter)
        if let container = textContainer {
            container.widthTracksTextView = markGutter == 0
            if container.size.width != column {
                container.size = NSSize(width: column, height: container.size.height)
            }
        }
        guard metrics.columnWidth != column else { return }

        let metrics = metrics
        DispatchQueue.main.async { [weak self] in
            guard metrics.columnWidth != column else { return }
            metrics.columnWidth = column

            if let manager = self?.textLayoutManager { manager.invalidateLayout(for: manager.documentRange) }
            guard let storage = self?.textStorage, storage.length > 0 else { return }
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                (value as? NoteSlideAttachment)?.host?.scheduleSizeCheck()
            }
        }
    }
}

@MainActor
final class NoteDocumentScroller {
    weak var textView: NSTextView?
    var blockRanges: [NSRange] = []

    func setBlockKind(_ kind: NoteBlockMarker.Kind) {
        (textView as? NoteDocumentTextView)?.setBlockKind(kind)
    }

    func toggleMark(_ mark: NoteDocumentTextView.Mark) {
        (textView as? NoteDocumentTextView)?.toggleMark(mark)
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func markWillBeSlide(type: String?) {
        (textView as? NoteDocumentTextView)?.markWillBeSlide(type: type)
    }

    func kindMenu(for group: String) -> NSMenu? {
        (textView as? NoteDocumentTextView)?.kindMenu(group: group)
    }

    func unmarkWillBeSlide() {
        (textView as? NoteDocumentTextView)?.unmarkWillBeSlide()
    }

    func insertSlide(_ ref: NoteSlideRef) {
        (textView as? NoteDocumentTextView)?.insertSlide(ref)
    }

    func replaceBody(with body: NoteBody, slides: NoteSlideContext?, live: NoteSlideLive) {
        (textView as? NoteDocumentTextView)?.replaceBody(with: body, slides: slides, live: live)
    }

    func scrollToGroup(_ id: String) {
        jumping = true
        defer { jumping = false }
        (textView as? NoteDocumentTextView)?.scrollToGroup(id)
    }

    private var jumping = false

    func firstVisibleGroup() -> String? {
        guard let textView = textView as? NoteDocumentTextView else { return nil }
        let top = textView.visibleRect.minY
        return textView.markBoxes.filter { $0.rect.maxY > top }.min { $0.rect.minY < $1.rect.minY }?.group
    }

    var followedGroup: String?

    func scrolls(_ view: Any?) -> Bool {
        guard !jumping, let clip = textView?.enclosingScrollView?.contentView else { return false }
        return view as AnyObject? === clip
    }

    func scroll(toBlock index: Int, selectNeedle needle: String? = nil, occurrence: Int = 0) {
        guard let textView, blockRanges.indices.contains(index) else { return }
        var target = blockRanges[index]
        if let needle, !needle.isEmpty {
            let haystack = textView.string as NSString
            var search = target
            var found = NSRange(location: NSNotFound, length: 0)
            for _ in 0 ... occurrence {
                found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard found.location != NSNotFound else { break }
                let next = found.location + found.length
                search = NSRange(location: next, length: max(0, target.location + target.length - next))
            }
            if found.location != NSNotFound {
                target = found
                textView.setSelectedRange(found)
            }
        }
        textView.scrollRangeToVisible(target)
    }
}

final class NoteSlideLive: ObservableObject {
    @Published var slideID: String?
}

final class NoteLayoutMetrics: ObservableObject {
    @Published var columnWidth: CGFloat = 0

    @Published var contentHeight: CGFloat = 0
}

final class NoteFittingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

@MainActor
final class NoteImageStore: ObservableObject {
    static let shared = NoteImageStore()
    @Published private(set) var version = 0
    private var images: [URL: NSImage] = [:]
    private var loading: Set<URL> = []
    private var failed: Set<URL> = []

    func image(for source: String) -> NSImage? {
        guard !source.isEmpty, let url = NoteMedia.resolve(source) else { return nil }
        if let image = images[url] { return image }
        guard !loading.contains(url), !failed.contains(url) else { return nil }
        loading.insert(url)
        Task { [weak self] in
            let data = try? await NoteMediaFiles.data(from: url)
            guard let self else { return }
            loading.remove(url)
            if let data, let image = NSImage(data: data) {
                images[url] = image
            } else {
                failed.insert(url)
            }
            version += 1
        }
        return nil
    }

    func cantShow(_ source: String) -> Bool {
        guard !source.isEmpty else { return true }
        guard let url = NoteMedia.resolve(source) else { return URL(string: source)?.scheme != nil }
        return failed.contains(url)
    }

    func poster(for block: NoteBlock) -> NSImage? {
        guard let key = NoteMedia.key(of: block) else { return nil }
        if let poster = posters[key] { return poster }
        guard !loadingPosters.contains(key) else { return nil }
        loadingPosters.insert(key)
        Task { [weak self] in
            let source = NoteMedia.fetchesByURL(block) ? NoteMedia.resolve(block.url ?? "") : nil
            var poster: NSImage?
            if let source { poster = await Self.makePoster(source, name: block.filename ?? "Video") }
            guard let self else { return }
            if let poster {
                posters[key] = poster
                version += 1
            }
        }
        return nil
    }

    private var posters: [String: NSImage] = [:]
    private var loadingPosters: Set<String> = []

    nonisolated private static func makePoster(_ url: URL, name: String) async -> NSImage? {
        let duration = (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard let frame = await ThumbnailStore.videoPoster(url: url, at: NoteMedia.posterTime(duration: duration), maxPixels: 960)
        else { return nil }
        return posterImage(frame: frame, duration: duration, name: name)
    }

    nonisolated static func posterImage(frame: CGImage?, duration: Double, name: String) -> NSImage {
        let picture = frame.map { NSSize(width: $0.width, height: $0.height) } ?? NSSize(width: 960, height: 540)
        let unit = max(picture.width, picture.height) / 480

        let nameSize = picture.width / 26
        let band = nameSize * 1.9
        let size = NSSize(width: picture.width, height: picture.height + band)
        return NSImage(size: size, flipped: false) { _ in
            let area = CGRect(x: 0, y: band, width: picture.width, height: picture.height)
            if let frame {
                NSGraphicsContext.current?.cgContext.draw(frame, in: area)
            } else {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                area.fill()
            }
            let caption = NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: nameSize), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            caption.draw(with: CGRect(x: 0, y: nameSize * 0.35, width: picture.width, height: nameSize * 1.4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            guard frame != nil else { return true }
            let circle = NSRect(x: area.midX - 22 * unit, y: area.midY - 22 * unit, width: 44 * unit, height: 44 * unit)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: circle.midX - 6 * unit, y: circle.midY - 9 * unit))
            play.line(to: NSPoint(x: circle.midX + 10 * unit, y: circle.midY))
            play.line(to: NSPoint(x: circle.midX - 6 * unit, y: circle.midY + 9 * unit))
            play.close()
            NSColor.white.setFill()
            play.fill()
            if duration > 0 {
                let label = NSAttributedString(string: MediaPickCardLogic.clock(duration), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * unit, weight: .semibold), .foregroundColor: NSColor.white,
                ])
                let text = label.size()
                let pill = NSRect(x: area.maxX - text.width - 16 * unit, y: area.minY + 6 * unit, width: text.width + 10 * unit, height: text.height + 2 * unit)
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4 * unit, yRadius: 4 * unit).fill()
                label.draw(at: NSPoint(x: pill.minX + 5 * unit, y: pill.minY + unit))
            }
            return true
        }
    }

    nonisolated static func missingPicture(name: String?, editable: Bool) -> NSImage {
        let named = name?.isEmpty == false
        let size = NSSize(width: missingPictureWidth, height: (named ? 50 : 34) + (editable ? 30 : 0))
        return NSImage(size: size, flipped: true) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            box.fill()
            NSColor.separatorColor.setStroke()
            box.setLineDash([4, 3], count: 2, phase: 0)
            box.stroke()
            let symbol = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor)))
            symbol?.draw(in: NSRect(x: 12, y: 10, width: 18, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSAttributedString(string: "Picture didn't come through", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(in: NSRect(x: 38, y: 10, width: rect.width - 48, height: 16))
            if let name, named {
                NSAttributedString(string: name, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
                ]).draw(with: NSRect(x: 38, y: 28, width: rect.width - 48, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            guard editable else { return true }
            let row = rect.height - 30
            let add = missingPictureAdd.offsetBy(dx: 0, dy: row)
            let pill = NSBezierPath(roundedRect: add, xRadius: add.height / 2, yRadius: add.height / 2)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            pill.fill()
            let addLabel = NSAttributedString(string: "Add Picture…", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
            ])
            addLabel.draw(at: NSPoint(x: add.midX - addLabel.size().width / 2, y: add.midY - addLabel.size().height / 2))
            let removeLabel = NSAttributedString(string: "Remove", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let remove = missingPictureRemove.offsetBy(dx: 0, dy: row)
            removeLabel.draw(at: NSPoint(x: remove.midX - removeLabel.size().width / 2, y: remove.midY - removeLabel.size().height / 2))
            return true
        }
    }

    nonisolated static let missingPictureWidth: CGFloat = 260

    nonisolated static let missingPictureAdd = NSRect(x: 38, y: 0, width: 96, height: 22)
    nonisolated static let missingPictureRemove = NSRect(x: 140, y: 0, width: 60, height: 22)

    func loaded(for source: String) async -> NSImage? {
        guard let url = NoteMedia.resolve(source) else { return nil }
        if let image = images[url] { return image }
        guard let data = try? await NoteMediaFiles.data(from: url), let image = NSImage(data: data) else { return nil }
        if images[url] == nil {
            images[url] = image
            version += 1
        }
        return images[url]
    }
}

@MainActor
enum NoteDocumentRenderer {
    static func separator(_ style: NoteReaderStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: font(style.fontSize)])
    }

    struct Signature: Equatable {
        var body: NoteBody
        var style: NoteReaderStyle
        var query: String
        var imagesVersion: Int
    }

    struct Rendered {
        var text: NSAttributedString

        var blockRanges: [NSRange]
    }

    static func render(
        _ body: NoteBody, style: NoteReaderStyle, query: String,
        slides: NoteSlideContext?, live: NoteSlideLive
    ) -> Rendered {
        let result = NSMutableAttributedString()
        var ranges: [NSRange] = []

        let panels = style.slideDisplay.drawsPanels ? NotePanels.panels(in: body) : []
        var wordsPanel: [Int: NotePanels.Panel] = [:]
        var cardPanel: [Int: NotePanels.Panel] = [:]
        for panel in panels {
            if let words = panel.words { for index in words { wordsPanel[index] = panel } }
            for index in panel.cards { cardPanel[index] = panel }
        }
        var folded = Set<String>()
        var wroteAny = false
        func separator() {
            if wroteAny { result.append(Self.separator(style)) }
            wroteAny = true
        }
        for (index, block) in body.blocks.enumerated() {
            var tag: NotePanelTag?
            var start = result.length
            if let panel = wordsPanel[index], style.isFolded(panel.id) {
                if !folded.contains(panel.id) {
                    folded.insert(panel.id)
                    separator()
                    start = result.length
                    result.append(foldedLine(style: style))
                    tag = NotePanelTag(panel: panel, part: .fold)
                }
            } else if let panel = cardPanel[index], style.panelLayout == .side, block.type == .slideRef {
                separator()
                start = result.length
                result.append(hostedCard(block, style: style, slides: slides, live: live))
                tag = NotePanelTag(panel: panel, part: .card)
            } else {
                separator()
                start = result.length
                append(block, to: result, style: style, depth: 0, slides: slides, live: live)
                if let panel = wordsPanel[index] {
                    tag = NotePanelTag(panel: panel, part: .words)
                } else if let panel = cardPanel[index] {
                    tag = NotePanelTag(panel: panel, part: .card)
                }
            }
            let range = NSRange(location: start, length: max(0, result.length - start))
            ranges.append(range)
            if let tag, range.length > 0 { decorate(range, tag: tag, style: style, in: result) }
        }
        finishPanels(in: result)
        highlight(query, in: result)
        return Rendered(text: result, blockRanges: ranges)
    }

    private static func decorate(_ range: NSRange, tag: NotePanelTag, style: NoteReaderStyle, in result: NSMutableAttributedString) {
        result.addAttribute(NotePanelTag.key, value: tag, range: range)
        let reserve = style.panelLayout == .side ? style.pictureWidth + NotePanelMetrics.gap : 0
        adjustParagraphs(in: result, range: range) { paragraph in
            paragraph.firstLineHeadIndent += NotePanelMetrics.inset
            paragraph.headIndent += NotePanelMetrics.inset
            paragraph.tabStops = paragraph.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + NotePanelMetrics.inset) }
            if tag.part != .card, reserve > 0 { paragraph.tailIndent = -(reserve + NotePanelMetrics.trailing + 4) }
        }
    }

    private static func finishPanels(in result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        var first: [String: NSRange] = [:]
        var last: [String: NSRange] = [:]
        result.enumerateAttribute(NotePanelTag.key, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let tag = value as? NotePanelTag else { return }
            if first[tag.panel.id] == nil { first[tag.panel.id] = range }
            last[tag.panel.id] = range
        }
        let string = result.string as NSString
        for range in first.values {
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            adjustParagraphs(in: result, range: paragraph) { $0.paragraphSpacingBefore += NotePanelMetrics.header + NotePanelMetrics.pad * 2 }
        }
        for (id, range) in last {
            let paragraph = string.paragraphRange(for: NSRange(location: max(range.location, range.location + range.length - 1), length: 0))
            var base: CGFloat = 0
            adjustParagraphs(in: result, range: paragraph) { style in
                style.paragraphSpacing += NotePanelMetrics.pad
                base = style.paragraphSpacing
            }
            result.addAttributes([NotePanelTag.spacerKey: id, NotePanelTag.spacerBaseKey: NSNumber(value: Double(base))], range: paragraph)
        }
    }

    private static func adjustParagraphs(in result: NSMutableAttributedString, range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
        result.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            change(style)
            result.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
    }

    private static func foldedLine(style: NoteReaderStyle) -> NSAttributedString {
        NSAttributedString(string: "\u{22EF}", attributes: [
            .font: font(style.fontSize * 0.9), .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle(fontSize: style.fontSize, indent: 0),
            NoteBlockMarker.key: NoteBlockMarker(.paragraph), NoteBlockMarker.prefixKey: true,
        ])
    }

    private static func hostedCard(_ block: NoteBlock, style: NoteReaderStyle, slides: NoteSlideContext?, live: NoteSlideLive) -> NSAttributedString {
        let attachment = NoteSlideAttachment(slide: block.slide ?? NoteSlideRef(), style: style, context: slides, live: live)
        attachment.panelHosted = true

        attachment.image = NSImage(size: NSSize(width: 1, height: 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 1
        paragraph.maximumLineHeight = 1
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([.font: font(1), .paragraphStyle: paragraph, NoteBlockMarker.key: NoteBlockMarker(.slide)], range: NSRange(location: 0, length: result.length))
        return result
    }

    static func sameContent(_ a: [NoteBlock], _ b: [NoteBlock]) -> Bool {
        func strip(_ blocks: [NoteBlock]) -> [NoteBlock] {
            blocks.map { block in
                var block = block
                block.slide?.thumbnailUrl = nil
                block.blocks = block.blocks.map(strip)
                block.items = block.items?.map { item in
                    var item = item
                    item.blocks = item.blocks.map(strip)
                    return item
                }
                return block
            }
        }
        return strip(a) == strip(b)
    }

    static func paragraph(_ kind: NoteBlockMarker.Kind, runs: [NoteRun], style: NoteReaderStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let block: NoteBlock = switch kind {
        case .heading(let level): NoteBlock(type: .heading, level: level, runs: runs)
        case .listItem(let ordered, _): NoteBlock(type: .list, ordered: ordered, items: [NoteListItem(runs: runs)])
        case .taskItem(let checked, _): NoteBlock(type: .taskList, items: [NoteListItem(runs: runs, checked: checked)])
        case .quote: NoteBlock(type: .quote, blocks: [NoteBlock(type: .paragraph, runs: runs)])
        case .code(let language): NoteBlock(type: .code, language: language, text: runs.map(\.text).joined())
        case .rule: NoteBlock(type: .rule)
        default: NoteBlock(type: .paragraph, runs: runs)
        }
        let depth = switch kind {
        case .listItem(_, let d), .taskItem(_, let d), .quote(let d): d
        default: 0
        }
        append(block, to: result, style: style, depth: depth, slides: nil, live: NoteSlideLive())
        return result
    }

    static func attributes(for kind: NoteBlockMarker.Kind, style: NoteReaderStyle) -> [NSAttributedString.Key: Any] {
        let rendered = paragraph(kind, runs: [NoteRun(text: " ")], style: style)
        return rendered.length > 0 ? rendered.attributes(at: rendered.length - 1, effectiveRange: nil) : [:]
    }

    static func hasMark(_ mark: NoteDocumentTextView.Mark, _ attributes: [NSAttributedString.Key: Any]) -> Bool {
        let font = attributes[.font] as? NSFont
        switch mark {
        case .bold: return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        case .italic: return font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
        case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
        case .strike: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        case .highlight: return attributes[.backgroundColor] != nil && attributes[NoteBlockMarker.findKey] == nil
        }
    }

    static func toggled(_ mark: NoteDocumentTextView.Mark, in attributes: [NSAttributedString.Key: Any], on: Bool?) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let turnOn = on ?? !hasMark(mark, attributes)
        let manager = NSFontManager.shared
        switch mark {
        case .bold:
            if let font = attributes[.font] as? NSFont {
                result[.font] = turnOn ? manager.convert(font, toHaveTrait: .boldFontMask) : manager.convert(font, toNotHaveTrait: .boldFontMask)
            }
        case .italic:
            if let font = attributes[.font] as? NSFont {
                result[.font] = turnOn ? manager.convert(font, toHaveTrait: .italicFontMask) : manager.convert(font, toNotHaveTrait: .italicFontMask)
            }
        case .underline:
            result[.underlineStyle] = turnOn ? NSUnderlineStyle.single.rawValue : nil
        case .strike:
            result[.strikethroughStyle] = turnOn ? NSUnderlineStyle.single.rawValue : nil
        case .highlight:
            result[.backgroundColor] = turnOn ? NSColor.systemYellow.withAlphaComponent(0.35) : nil
        }
        return result
    }

    private static func append(
        _ block: NoteBlock, to result: NSMutableAttributedString, style: NoteReaderStyle, depth: Int,
        slides: NoteSlideContext?, live: NoteSlideLive
    ) {
        let indent = CGFloat(depth) * 22
        let start = result.length
        defer {
            if result.length > start, let marker = marker(for: block, depth: depth) {
                result.addAttribute(NoteBlockMarker.key, value: marker, range: NSRange(location: start, length: result.length - start))
            }
        }
        switch block.type {
        case .heading:
            let level = block.level ?? 1
            let paragraph = paragraphStyle(fontSize: style.fontSize, indent: indent, spacingBefore: level == 1 ? 10 : 6)
            result.append(runs(block.runs, fontSize: style.headingSize(level), weight: .semibold, paragraph: paragraph))
        case .paragraph:
            result.append(runs(block.runs, fontSize: style.fontSize, paragraph: paragraphStyle(fontSize: style.fontSize, indent: indent)))
        case .list, .taskList:
            for (number, item) in (block.items ?? []).enumerated() {
                let done = block.type == .taskList && item.checked == true
                let marker = block.type == .taskList ? (done ? "☑" : "☐") : (block.ordered == true ? "\(number + 1)." : "•")
                let paragraph = listParagraphStyle(fontSize: style.fontSize, indent: indent)
                let itemStart = result.length
                result.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: font(style.fontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
                    NoteBlockMarker.prefixKey: true,
                ]))
                result.append(runs(item.runs, fontSize: style.fontSize, paragraph: paragraph, struck: done))
                let itemKind: NoteBlockMarker.Kind = block.type == .taskList
                    ? .taskItem(checked: done, depth: depth) : .listItem(ordered: block.ordered == true, depth: depth)
                result.addAttribute(NoteBlockMarker.key, value: NoteBlockMarker(itemKind), range: NSRange(location: itemStart, length: result.length - itemStart))
                for nested in item.blocks ?? [] {
                    result.append(NSAttributedString(string: "\n"))
                    append(nested, to: result, style: style, depth: depth + 1, slides: slides, live: live)
                }
                if number < (block.items ?? []).count - 1 { result.append(NSAttributedString(string: "\n")) }
            }
        case .quote:
            for (index, nested) in (block.blocks ?? []).enumerated() {
                let quoteStart = result.length
                append(nested, to: result, style: style, depth: depth + 1, slides: slides, live: live)
                let range = NSRange(location: quoteStart, length: result.length - quoteStart)
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                result.addAttribute(NoteBlockMarker.key, value: NoteBlockMarker(.quote(depth: depth)), range: range)
                if index < (block.blocks ?? []).count - 1 { result.append(NSAttributedString(string: "\n")) }
            }
        case .code:
            let paragraph = paragraphStyle(fontSize: style.fontSize, indent: indent)
            result.append(NSAttributedString(string: block.text ?? "", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: style.fontSize * 0.9, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                NoteBlockMarker.findKey: true,
                .paragraphStyle: paragraph,
            ]))
        case .rule:
            result.append(NSAttributedString(string: String(repeating: "\u{2500}", count: 24), attributes: [
                .font: font(style.fontSize * 0.8), .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraphStyle(fontSize: style.fontSize, indent: indent),
                NoteBlockMarker.prefixKey: true,
            ]))
        case .image:

            let source = block.url ?? ""
            if !NoteMedia.isMailChrome(source) {
                let attachment = NoteImageAttachment(url: source, width: block.width, alt: block.alt)
                var width = min(CGFloat(block.width ?? 480), 480)
                if let image = NoteImageStore.shared.image(for: source) {
                    attachment.image = image

                    if block.width == nil, image.size.width > 0 { width = min(width, image.size.width) }
                    let height = image.size.width > 0 ? width * image.size.height / image.size.width : width * 9 / 16
                    attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                } else if NoteImageStore.shared.cantShow(source) {
                    let tile = NoteImageStore.missingPicture(name: block.alt, editable: style.editable)
                    attachment.missing = true
                    attachment.image = tile
                    attachment.bounds = CGRect(origin: .zero, size: tile.size)
                } else {
                    attachment.image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
                        NSColor.labelColor.withAlphaComponent(0.06).setFill(); rect.fill(); return true
                    }
                    attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * 9 / 16)
                }
                let picture = NSMutableAttributedString(attachment: attachment)
                if let mark = mediaMark(block) {
                    picture.addAttribute(NoteBlockMarker.slideKey, value: mark, range: NSRange(location: 0, length: picture.length))
                }

                result.append(picture)
            }
        case .attachment:
            var attributes: [NSAttributedString.Key: Any] = [.font: font(style.fontSize * 0.9), .foregroundColor: NSColor.secondaryLabelColor]
            attributes[NoteBlockMarker.slideKey] = mediaMark(block)
            guard NoteMedia.isVideo(block) else {
                result.append(NSAttributedString(string: "📎 " + (block.filename ?? "Attachment"), attributes: attributes))
                return
            }

            let attachment = NoteVideoPosterAttachment()
            let poster = NoteImageStore.shared.poster(for: block)
                ?? NoteImageStore.posterImage(frame: nil, duration: 0, name: block.filename ?? "Video")
            attachment.image = poster
            attachment.bounds = CGRect(x: 0, y: 0, width: 480, height: 480 * poster.size.height / max(poster.size.width, 1))
            let row = NSMutableAttributedString(attachment: attachment)
            if let mark = mediaMark(block) {
                row.addAttribute(NoteBlockMarker.slideKey, value: mark, range: NSRange(location: 0, length: row.length))
            }
            result.append(row)
        case .slideRef:

            if style.slideDisplay == .hidden {
                result.append(hostedCard(block, style: style, slides: slides, live: live))
                return
            }
            let attachment = NoteSlideAttachment(
                slide: block.slide ?? NoteSlideRef(), style: style, context: slides, live: live)
            result.append(NSAttributedString(attachment: attachment))
        case .unknown:
            result.append(NSAttributedString(string: block.text ?? "", attributes: [
                .font: font(style.fontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
    }

    private static func mediaMark(_ block: NoteBlock) -> NoteSlideMark? {
        guard let group = block.slideGroup, !group.isEmpty else { return nil }
        return NoteSlideMark(group: group, type: block.slideType, slideId: block.slideId, state: block.slideState)
    }

    private static func marker(for block: NoteBlock, depth: Int) -> NoteBlockMarker? {
        switch block.type {
        case .heading: NoteBlockMarker(.heading(level: block.level ?? 1))
        case .paragraph: NoteBlockMarker(.paragraph)
        case .code: NoteBlockMarker(.code(language: block.language))
        case .rule: NoteBlockMarker(.rule)
        case .image: NoteBlockMarker(.image(url: block.url ?? "", width: block.width, alt: block.alt))
        case .attachment: NoteBlockMarker(.attachment(kind: block.attachmentKind ?? "file", hexId: block.hexId ?? "", filename: block.filename ?? "", url: block.url))
        case .slideRef: NoteBlockMarker(.slide)
        case .unknown: NoteBlockMarker(.unknown)
        case .list, .taskList, .quote: nil
        }
    }

    private static func runs(
        _ runs: [NoteRun]?, fontSize: CGFloat, weight: NSFont.Weight = .regular,
        paragraph: NSParagraphStyle, struck: Bool = false
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs ?? [] {
            var face = NSFont.systemFont(ofSize: fontSize, weight: run.bold == true ? .bold : weight)
            if run.italic == true { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
            if run.code == true { face = .monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: face,
                .foregroundColor: struck ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if run.underline == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strike == true || struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let highlight = run.highlight {
                attributes[.backgroundColor] = (NoteRunText.color(hex: highlight).map(NSColor.init) ?? .systemYellow).withAlphaComponent(0.35)
            }
            if let hex = run.color, let color = NoteRunText.color(hex: hex) { attributes[.foregroundColor] = NSColor(color) }
            if let href = run.href, let url = URL(string: href) { attributes[.link] = url }
            if let group = run.slideGroup, !group.isEmpty {
                attributes[NoteBlockMarker.slideKey] = NoteSlideMark(group: group, type: run.slideType, slideId: run.slideId, state: run.slideState)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "", attributes: [.font: font(fontSize), .paragraphStyle: paragraph]))
        }
        return result
    }

    private static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }

    private static func paragraphStyle(fontSize: CGFloat, indent: CGFloat, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.2
        style.paragraphSpacing = fontSize * 0.55
        style.paragraphSpacingBefore = spacingBefore
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    private static func listParagraphStyle(fontSize: CGFloat, indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let marker: CGFloat = 20
        style.lineSpacing = fontSize * 0.2
        style.paragraphSpacing = fontSize * 0.3
        style.firstLineHeadIndent = indent
        style.headIndent = indent + marker
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + marker)]
        return style
    }

    private static func highlight(_ query: String, in text: NSMutableAttributedString) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let haystack = text.string as NSString
        var search = NSRange(location: 0, length: haystack.length)
        while search.length > 0 {
            let found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            text.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.45), NoteBlockMarker.findKey: true], range: found)
            let next = found.location + found.length
            search = NSRange(location: next, length: haystack.length - next)
        }
    }
}

final class NoteImageAttachment: NoteFittedAttachment {
    let url: String
    let width: Int?
    let alt: String?

    var missing = false

    init(url: String, width: Int?, alt: String?) {
        self.url = url
        self.width = width
        self.alt = alt
        super.init()
    }
}

final class NoteVideoPosterAttachment: NoteFittedAttachment {}

class NoteFittedAttachment: NSTextAttachment {
    init() {
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let padding = (textContainer?.lineFragmentPadding ?? 0) * 2
        var room = proposedLineFragment.width - padding

        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle, let width = textContainer?.size.width {
            let tail = paragraph.tailIndent <= 0 ? -paragraph.tailIndent : max(0, width - paragraph.tailIndent)
            room = min(room, width - padding - paragraph.firstLineHeadIndent - tail)
        }
        return CGRect(origin: bounds.origin, size: NoteMedia.fitted(bounds.size, toWidth: max(room, 1)))
    }
}

final class NoteSlideAttachment: NSTextAttachment {
    final class State: ObservableObject {
        @Published var ref: NoteSlideRef
        init(_ ref: NoteSlideRef) { self.ref = ref }
    }

    let state: State
    let style: NoteReaderStyle
    let context: NoteSlideContext?
    let live: NoteSlideLive

    weak var host: NoteSlideHostingView?

    var panelHosted = false
    var slide: NoteSlideRef { state.ref }

    init(slide: NoteSlideRef, style: NoteReaderStyle, context: NoteSlideContext?, live: NoteSlideLive) {
        self.state = State(slide)
        self.style = style
        self.context = context
        self.live = live
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        guard !panelHosted else { return nil }
        return NoteSlideViewProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location)
    }
}

final class NoteSlideViewProvider: NSTextAttachmentViewProvider {
    override init(
        textAttachment: NSTextAttachment, parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation
    ) {
        super.init(textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        let provider = UncheckedBox(self)
        MainActor.assumeIsolated {
            guard let attachment = provider.value.textAttachment as? NoteSlideAttachment else { return }
            let textView = provider.value.textLayoutManager?.textContainer?.textView as? NoteDocumentTextView
            let host = NoteSlideHostingView(rootView: NoteSlideCardHost(attachment: attachment, textView: textView))

            host.sizingOptions = [.intrinsicContentSize]
            host.frame.size = host.fittingSize

            host.onSizeChange = { [weak textView, weak attachment] in
                guard let textView, let attachment else { return }
                textView.attachmentSizeDidChange(attachment)
            }
            provider.value.view = host

            attachment.host = host
            host.scheduleSizeCheck()
        }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct NoteSlideCardHost: View {
    let attachment: NoteSlideAttachment
    weak var textView: NoteDocumentTextView?
    @ObservedObject var live: NoteSlideLive
    @ObservedObject var state: NoteSlideAttachment.State
    @ObservedObject var metrics: NoteLayoutMetrics

    init(attachment: NoteSlideAttachment, textView: NoteDocumentTextView?) {
        self.attachment = attachment
        self.textView = textView
        self.live = attachment.live
        self.state = attachment.state
        self.metrics = textView?.metrics ?? NoteLayoutMetrics()
    }

    var body: some View {
        let context = attachment.context?.withLive(live.slideID)
        let editable = textView?.isEditable == true
        NoteSlideCard(
            slide: state.ref, style: attachment.style, context: context,
            onChange: editable ? { changed in
                state.ref = changed
                textView?.attachmentDidChange(attachment)
            } : nil,
            onPreview: editable ? { changed in
                state.ref = changed
                textView?.attachmentPreviewDidChange(attachment)
            } : nil,
            onRemove: editable ? { textView?.removeAttachment(attachment) } : nil,
            availableWidth: metrics.columnWidth - (attachment.style.slideDisplay.drawsPanels ? NotePanelMetrics.inset * 2 : 0),
            compact: attachment.style.slideDisplay == .compact)
            .padding(.vertical, attachment.style.slideDisplay == .compact ? 1 : 4)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak attachment] _ in
                attachment?.host?.scheduleSizeCheck()
            }
    }
}
