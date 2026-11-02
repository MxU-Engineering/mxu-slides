import AppKit
import PresenterCore

extension NoteDocumentTextView {
    static let markGutterWidth: CGFloat = 128
    static let readOnlyGutterWidth: CGFloat = 92

    static func kindColor(_ type: String?) -> NSColor {
        switch type {
        case "title": NSColor(srgbRed: 0.77, green: 0.65, blue: 1.0, alpha: 1)
        case "points": NSColor(srgbRed: 0.42, green: 0.72, blue: 1.0, alpha: 1)
        case "scripture": NSColor(srgbRed: 1.0, green: 0.71, blue: 0.36, alpha: 1)
        case "quote": NSColor(srgbRed: 0.37, green: 0.84, blue: 0.78, alpha: 1)
        case "lyrics": NSColor(srgbRed: 0.95, green: 0.55, blue: 0.70, alpha: 1)
        case "picture": NSColor(srgbRed: 0.55, green: 0.85, blue: 0.45, alpha: 1)
        case "video": NSColor(srgbRed: 1.0, green: 0.50, blue: 0.45, alpha: 1)
        default: NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }

    static func kindLabel(_ type: String?) -> String {
        guard let type, !type.isEmpty else { return "Slide" }
        if let known = NoteSlideMarks.SlideType(rawValue: type) { return known.label }
        return SlideKind(rawValue: type) == nil ? type : type.capitalized
    }

    @MainActor static var ownSlideTypes: () -> [String] = { [] }

    func updateMarkGutter() {
        greyOffScreenWords()
        let groups = marksInMargin ? markGroups() : []
        let next: CGFloat = groups.isEmpty ? 0 : isEditable ? Self.markGutterWidth : Self.readOnlyGutterWidth
        guard next != markGutter else { return }
        markGutter = next
        applyInset()
        placeGutterView()
        needsDisplay = true
    }

    func placeGutterView() {
        guard markGutter > 0 else {
            gutterView?.removeFromSuperview()
            gutterView = nil
            return
        }
        let view = gutterView ?? MarginGutterView()
        if view.superview !== self { addSubview(view) }
        gutterView = view
        if view.frame != bounds { view.frame = bounds }
    }

    func greyOffScreenWords() {
        guard let storage = textStorage else { return }
        var grey: [NSRange] = []
        if marksInMargin {
            let string = storage.string as NSString
            var labelled = Set<Int>()
            for group in markGroups() {
                let asides = (parenthesesByGroup[group.mark.group] ?? parenthesesToNotes)
                    && ![SlideKind.lyrics.rawValue, SlideKind.media.rawValue].contains(group.mark.type ?? "")
                for range in group.ranges {
                    let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
                    let line = string.substring(with: paragraph)
                    if labelled.insert(paragraph.location).inserted, let count = NoteSlides.inlineMarkerLabelLength(in: line) {
                        grey.append(NSRange(location: paragraph.location, length: NSRange(line.startIndex ..< line.index(line.startIndex, offsetBy: count), in: line).length))
                    }
                    guard asides else { continue }
                    let words = string.substring(with: range)
                    grey += DeterministicSlidePlanner.asideRanges(in: words).map {
                        let local = NSRange($0, in: words)
                        return NSRange(location: range.location + local.location, length: local.length)
                    }
                }
            }
        }
        let whole = NSRange(location: 0, length: storage.length)
        var current: [NSRange] = []
        storage.enumerateAttribute(NoteBlockMarker.greyKey, in: whole) { value, range, _ in
            if value != nil { current.append(range) }
        }
        let wanted = grey.sorted { $0.location < $1.location }
        guard Set(current.map { [$0.location, $0.length] }) != Set(wanted.map { [$0.location, $0.length] }) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(NoteBlockMarker.greyKey, in: whole) { value, range, _ in
            guard let value else { return }
            if let color = value as? NSColor {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            } else {
                storage.removeAttribute(.foregroundColor, range: range)
            }
            storage.removeAttribute(NoteBlockMarker.greyKey, range: range)
        }
        for range in wanted where NSMaxRange(range) <= storage.length {
            storage.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
                storage.addAttribute(NoteBlockMarker.greyKey, value: value ?? NSNull(), range: subrange)
            }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        storage.endEditing()
    }

    func markGroups() -> [(mark: NoteSlideMark, ranges: [NSRange])] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
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
        return groups
    }

    func drawMarginMarks(tinted: Bool) {
        let oldLabels = markLabelHits.map(\.rect)
        markLabelHits = []
        markBoxes = []
        slideTagHits = []
        var items: [MarginGutterView.Item] = []
        defer {
            if gutterView?.items != items {
                gutterView?.items = items
                gutterView?.needsDisplay = true
            }

            if markLabelHits.map(\.rect) != oldLabels { window?.invalidateCursorRects(for: self) }
        }
        guard let manager = textLayoutManager else { return }
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? 0
        for group in markGroups() {
            var lines: [NSRect] = []
            for range in group.ranges {
                guard let textRange = textRange(for: range) else { continue }
                manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                    lines.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                    return true
                }
            }
            guard let top = lines.map(\.minY).min(), let bottom = lines.map(\.maxY).max(), let first = lines.min(by: { $0.minY < $1.minY }) else { continue }
            let color = Self.kindColor(group.mark.type)
            let selected = group.mark.group == selectedGroup
            let box = NSRect(x: origin.x, y: top - 3, width: width, height: bottom - top + 6)
            let shape = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            if tinted {
                color.withAlphaComponent(selected ? 0.2 : 0.07).setFill()
                shape.fill()
            }
            if tinted, selected {
                color.setStroke()
                shape.lineWidth = 1
                shape.stroke()
            }
            markBoxes.append((box, group.mark.group))
            let railX = origin.x - 10

            let label = NSAttributedString(
                string: Self.kindLabel(group.mark.type).uppercased() + (isEditable ? " ▾" : ""),
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: color, .kern: 0.5])
            let size = label.size()
            let labelOrigin = NSPoint(x: railX - (isEditable ? 15 : 10) - size.width, y: first.minY + max(0, (first.height - size.height) / 2))
            let hit = NSRect(origin: labelOrigin, size: size).insetBy(dx: isEditable ? -7 : -5, dy: isEditable ? -2 : -3)
            items.append(MarginGutterView.Item(
                railX: railX, top: box.minY, bottom: box.maxY, color: color, label: label, labelOrigin: labelOrigin,
                labelBackground: isEditable ? hit : nil, labelHighlighted: group.mark.group == hoveredLabel))
            if isEditable { markLabelHits.append((hit, group.mark.group)) }

            if let slideId = group.mark.slideId, style.slideDisplay == .compact, let index = cardIndex(ofSlide: slideId),
               let last = lines.max(by: { $0.maxY < $1.maxY }) {
                let tag = NSAttributedString(string: "SLIDE \(index + 1)", attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.systemGreen,
                ])
                let tagSize = tag.size()
                let x = last.maxX + 8
                if x + tagSize.width + 8 <= origin.x + width {
                    let tagBox = NSRect(x: x, y: last.midY - tagSize.height / 2 - 1, width: tagSize.width + 8, height: tagSize.height + 2)
                    NSColor.systemGreen.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: tagBox, xRadius: 3, yRadius: 3).fill()
                    tag.draw(at: NSPoint(x: tagBox.minX + 4, y: tagBox.minY + 1))
                    slideTagHits.append((tagBox, group.mark))
                }
            }
        }
    }

    func handleMarginMarkClick(at point: NSPoint) -> Bool {
        if let hit = markLabelHits.first(where: { $0.rect.contains(point) }) {
            showKindMenu(group: hit.group, at: NSPoint(x: hit.rect.minX, y: hit.rect.maxY))
            return true
        }
        return false
    }

    private func showKindMenu(group: String, at point: NSPoint) {
        kindMenu(group: group)?.popUp(positioning: nil, at: point, in: self)
    }

    func kindMenu(group: String) -> NSMenu? {
        guard isEditable else { return nil }
        let current = markGroups().first { $0.mark.group == group }?.mark
        let menu = NSMenu()

        let media = [NoteSlideMarks.SlideType.picture.rawValue, NoteSlideMarks.SlideType.video.rawValue].contains(current?.type)
        var kinds: [String?] = media ? [current?.type] : [nil] + NoteSlideMarks.SlideType.textKinds.map(\.rawValue) + Self.ownSlideTypes()

        if let type = current?.type, !kinds.contains(type) { kinds.append(type) }
        for kind in kinds {
            let item = NSMenuItem(title: Self.kindLabel(kind), action: #selector(pickKindFromMenu(_:)), keyEquivalent: "")
            item.representedObject = MarkMenuPick(group: group, type: kind)
            item.state = current?.type == kind ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        if let extras = kindMenuExtras?(group, current?.type), !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from slides", action: #selector(removeMarkFromMenu(_:)), keyEquivalent: "")
        remove.representedObject = group
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func pickKindFromMenu(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? MarkMenuPick else { return }
        rewriteMarks(ofGroup: pick.group) { mark in
            NoteSlideMark(group: mark.group, type: pick.type, slideId: mark.slideId, state: mark.state)
        }
    }

    @objc private func removeMarkFromMenu(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? String else { return }
        rewriteMarks(ofGroup: group, Self.removing)
    }

    static func removing(_ mark: NoteSlideMark) -> NoteSlideMark? {
        mark.state == NoteSlideMarks.suggested
            ? NoteSlideMark(group: mark.group, type: mark.type, slideId: mark.slideId, state: NoteSlideMarks.declined)
            : nil
    }

    func rewriteMarks(ofGroup id: String, _ transform: (NoteSlideMark) -> NoteSlideMark?) {
        guard isEditable, let storage = textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        guard shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(NoteBlockMarker.slideKey, in: whole) { value, range, _ in
            guard let mark = value as? NoteSlideMark, mark.group == id else { return }
            if let next = transform(mark) {
                storage.addAttribute(NoteBlockMarker.slideKey, value: next, range: range)
            } else {
                storage.removeAttribute(NoteBlockMarker.slideKey, range: range)
            }
        }
        storage.endEditing()
        didChangeText()
        needsDisplay = true
    }

    func reportSelectedGroup() {
        guard let onSelectGroup, let storage = textStorage, storage.length > 0 else { return }
        let location = min(selectedRange().location, storage.length - 1)
        var group = (storage.attribute(NoteBlockMarker.slideKey, at: location, effectiveRange: nil) as? NoteSlideMark)
        if group == nil, location > 0 {
            group = storage.attribute(NoteBlockMarker.slideKey, at: location - 1, effectiveRange: nil) as? NoteSlideMark
        }
        let id = group.flatMap { $0.state == NoteSlideMarks.declined ? nil : $0.group }
        guard id != reportedGroup else { return }
        reportedGroup = id
        guard let id else { return }
        onSelectGroup(id)
    }

    func trackMarkHover(at point: NSPoint) {
        guard markGutter > 0 else { return }
        let label = markLabelHits.first { $0.rect.contains(point) }?.group
        let passage = label ?? markBoxes.first { $0.rect.insetBy(dx: -Self.markGutterWidth, dy: 0).contains(point) }?.group
        guard label != hoveredLabel || passage != hoveredGroup else { return }
        hoveredLabel = label
        hoveredGroup = passage
        needsDisplay = true
    }

    func scrollToGroup(_ id: String) {
        guard let range = markGroups().first(where: { $0.mark.group == id })?.ranges.first else { return }
        scrollRangeToVisible(range)
    }
}

final class MarkMenuPick: NSObject {
    let group: String
    let type: String?

    init(group: String, type: String?) {
        self.group = group
        self.type = type
    }
}

final class MarginGutterView: NSView {
    struct Item: Equatable {
        var railX: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var color: NSColor
        var label: NSAttributedString
        var labelOrigin: NSPoint
        var labelBackground: NSRect?
        var labelHighlighted = false
    }

    var items: [Item] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for item in items {
            let rail = NSBezierPath()
            rail.move(to: NSPoint(x: item.railX, y: item.top))
            rail.line(to: NSPoint(x: item.railX, y: item.bottom))
            rail.lineWidth = 3
            item.color.setStroke()
            rail.stroke()
            if let background = item.labelBackground {
                item.color.withAlphaComponent(item.labelHighlighted ? 0.32 : 0.2).setFill()
                NSBezierPath(roundedRect: background, xRadius: background.height / 2, yRadius: background.height / 2).fill()
            }
            item.label.draw(at: item.labelOrigin)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, indent: Int = 0, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        indentationLevel = indent
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
