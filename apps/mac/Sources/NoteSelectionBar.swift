import AppKit
import PresenterCore

extension NoteDocumentTextView {
    static let selectionPreviewGroup = "selection-preview"

    func updateSelectionBar() {
        let range = selectedRange()
        guard isEditable, NSEvent.pressedMouseButtons & 1 == 0, let storage = textStorage,
              range.length > 0, NSMaxRange(range) <= storage.length,
              let words = selectedWords(range, in: storage), !words.isEmpty
        else { return hideSelectionBar() }
        let guess = NoteSlideMarks.guessedType(of: words, shape: selectionShape(range, in: storage), ownTypes: Self.ownSlideTypes())
        if selectionBar?.range != range || selectionBar?.guess != guess {
            selectionBar?.removeFromSuperview()
            let bar = NoteSelectionBarView(guess: guess, range: range, textView: self)
            addSubview(bar)
            selectionBar = bar
            onSelectionPreview?(previewBody(range, guess: guess, in: storage))
        }
        placeSelectionBar()
    }

    func hideSelectionBar() {
        guard let bar = selectionBar else { return }
        bar.removeFromSuperview()
        selectionBar = nil
        onSelectionPreview?(nil)
    }

    func takeSelectionBarGuess() -> Bool {
        guard let bar = selectionBar else { return false }
        markFromBar(type: bar.guess)
        return true
    }

    func markFromBar(type: String?) {
        let end = NSMaxRange(selectedRange())
        hideSelectionBar()
        markWillBeSlide(type: type)
        setSelectedRange(NSRange(location: end, length: 0))
    }

    func wrapSelectionInSlideNote() {
        guard isEditable, let storage = textStorage else { return }
        var range = selectedRange()
        let string = storage.string as NSString
        while range.length > 0, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: NSMaxRange(range) - 1)) ?? " ") {
            range.length -= 1
        }
        guard range.length > 0 else { return }

        let words = string.substring(with: range)
        let before = range.location > 0 ? string.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let after = NSMaxRange(range) < string.length ? string.substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        if (words.hasPrefix("(") && words.hasSuffix(")")) || (before == "(" && after == ")") { return hideSelectionBar() }
        hideSelectionBar()

        guard replaceKeepingAttributes(range, with: storage.slideNoteWrapped(range)) else { return }
        setSelectedRange(NSRange(location: NSMaxRange(range) + 2, length: 0))
    }

    func placeSelectionBar() {
        guard let bar = selectionBar, let manager = textLayoutManager, let textRange = textRange(for: bar.range) else { return }
        var lines: [NSRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            lines.append(frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        guard let first = lines.min(by: { $0.minY < $1.minY }), let last = lines.max(by: { $0.maxY < $1.maxY }) else { return }
        let size = bar.fittingSize
        let visible = visibleRect
        var origin = NSPoint(x: first.minX, y: first.minY - size.height - 6)
        if origin.y < visible.minY + 2 { origin.y = last.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
        bar.frame = NSRect(origin: origin, size: size)
    }

    private func selectedWords(_ range: NSRange, in storage: NSTextStorage) -> String? {
        let text = (storage.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
        let lines = text.components(separatedBy: "\n").map { line in
            String(line.dropFirst(NoteBlockMarker.prefixLength(of: line))).trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func selectionShape(_ range: NSRange, in storage: NSTextStorage) -> NoteSlideMarks.Shape {
        switch (storage.attribute(NoteBlockMarker.key, at: range.location, effectiveRange: nil) as? NoteBlockMarker)?.kind {
        case .heading: .heading
        case .listItem, .taskItem: .list
        case .quote: .quote
        default: .paragraph
        }
    }

    private func previewBody(_ range: NSRange, guess: String?, in storage: NSTextStorage) -> NoteBody? {
        guard onSelectionPreview != nil else { return nil }
        let copy = NSMutableAttributedString(attributedString: storage)
        let mark = NoteSlideMark(group: Self.selectionPreviewGroup, type: guess)
        copy.enumerateAttributes(in: range) { attributes, subrange, _ in
            if attributes[NoteBlockMarker.prefixKey] != nil || attributes[.attachment] != nil { return }
            copy.addAttribute(NoteBlockMarker.slideKey, value: mark, range: subrange)
        }
        return NoteDocumentParser.body(from: copy)
    }
}

final class NoteSelectionBarView: NSView {
    let guess: String?
    let range: NSRange
    private weak var textView: NoteDocumentTextView?

    init(guess: String?, range: NSRange, textView: NoteDocumentTextView) {
        self.guess = guess
        self.range = range
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.masksToBounds = true

        let kinds = NoteSlideMarks.selectionBarKinds(guess: guess, ownTypes: NoteDocumentTextView.ownSlideTypes())
        var buttons: [NSView] = kinds.shown.enumerated().map { index, kind in
            button(NoteSlideMarks.selectionBarLabel(kind), kind: kind, primary: index == 0)
        }
        let more = button("⋯", kind: nil, primary: false, picks: false)
        more.action = #selector(showMore(_:))
        more.setAccessibilityLabel("More kinds")
        more.toolTip = kinds.more.map(NoteSlideMarks.selectionBarLabel).joined(separator: ", ")
        buttons.append(more)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        buttons.append(divider)
        let note = button("Slide Note", kind: nil, primary: false, picks: false)
        note.action = #selector(slideNote(_:))
        note.toolTip = "Keep it off the screen, in the slide notes"
        buttons.append(note)

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        addSubview(background)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Make the selection a slide")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ title: String, kind: String?, primary: Bool, picks: Bool = true) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(pick(_:)))
        if picks { button.identifier = NSUserInterfaceItemIdentifier(kind ?? "") }
        button.isBordered = false
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        if primary {
            button.attributedTitle = NSAttributedString(string: "\(title)  ↩", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black,
            ])
            button.layer?.backgroundColor = NoteDocumentTextView.kindColor(kind).cgColor
            button.toolTip = "Press Return for \(title)"
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: button.intrinsicContentSize.width + (primary ? 14 : 12)).isActive = true
        return button
    }

    @objc private func pick(_ sender: NSButton) {
        guard let kind = sender.identifier?.rawValue else { return }
        textView?.markFromBar(type: kind.isEmpty ? nil : kind)
    }

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        for kind in NoteSlideMarks.selectionBarKinds(guess: guess, ownTypes: NoteDocumentTextView.ownSlideTypes()).more {
            let item = NSMenuItem(title: NoteSlideMarks.selectionBarLabel(kind), action: #selector(pickFromMenu(_:)), keyEquivalent: "")
            item.representedObject = kind
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    @objc private func pickFromMenu(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        textView?.markFromBar(type: kind)
    }

    @objc private func slideNote(_ sender: NSButton) {
        textView?.wrapSelectionInSlideNote()
    }
}
