import AppKit
import PresenterCore
import UniformTypeIdentifiers

extension NoteDocumentTextView {
    func missingPicture(at point: NSPoint) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for location in [index, index - 1] where location >= 0 && location < storage.length {
            let range = NSRange(location: location, length: 1)
            if (storage.attribute(.attachment, at: location, effectiveRange: nil) as? NoteImageAttachment)?.missing == true,
               missingPictureRects(in: range).contains(where: { $0.contains(point) }) {
                return range
            }
        }
        return nil
    }

    func missingPictureRects(in range: NSRange? = nil) -> [NSRect] {
        guard let storage = textStorage, let manager = textLayoutManager else { return [] }
        var rects: [NSRect] = []
        let origin = textContainerOrigin
        storage.enumerateAttribute(.attachment, in: range ?? NSRange(location: 0, length: storage.length)) { value, found, _ in
            guard (value as? NoteImageAttachment)?.missing == true, let textRange = textRange(for: found) else { return }
            manager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
        }
        return rects
    }

    func handleMissingPictureClick(at point: NSPoint) -> Bool {
        guard let range = missingPicture(at: point), let rect = missingPictureRects(in: range).first,
              let tile = textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? NoteImageAttachment,
              let size = tile.image?.size, rect.width > 0 else { return false }

        let scale = size.width / rect.width
        let local = NSPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale - (size.height - 30))
        if NoteImageStore.missingPictureAdd.insetBy(dx: -4, dy: -4).contains(local) {
            choosePicture(for: range)
            return true
        }
        if NoteImageStore.missingPictureRemove.insetBy(dx: -4, dy: -4).contains(local) {
            removeMissingPicture(at: range)
            return true
        }
        return false
    }

    func choosePicture(for range: NSRange) {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MXU_QA_PICTURE_FILE"] {
            _ = replaceMissingPicture(at: range, with: URL(fileURLWithPath: path))
            return
        }
        #endif
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose the picture that didn't come through"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            MainActor.assumeIsolated { _ = self?.replaceMissingPicture(at: range, with: file) }
        }
    }

    func replaceMissingPicture(at range: NSRange, with file: URL) -> Bool {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length,
              let tile = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NoteImageAttachment, tile.missing,
              let save = NoteMediaFiles.save, let data = try? Data(contentsOf: file),
              let saved = save(data, file.lastPathComponent), let (context, live) = dropContext else { return false }
        let picture = NoteBlock(type: .image, url: saved, width: tile.width)
        let rendered = NoteDocumentRenderer.render(NoteBody(blocks: [picture], plainText: ""), style: style, query: "", slides: context, live: live).text
        insertText(rendered, replacementRange: range)
        return true
    }

    func removeMissingPicture(at range: NSRange) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let string = storage.string as NSString
        var line = string.paragraphRange(for: range)

        if NSMaxRange(line) == string.length, string.character(at: string.length - 1) != 0x0A, line.location > 0 {
            line = NSRange(location: line.location - 1, length: line.length + 1)
        }
        guard shouldChangeText(in: line, replacementString: "") else { return }
        storage.replaceCharacters(in: line, with: "")
        didChangeText()
    }

    var missingPictureActions: [NSAccessibilityCustomAction] {
        guard isEditable, let storage = textStorage else { return [] }
        var actions: [NSAccessibilityCustomAction] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let tile = value as? NoteImageAttachment, tile.missing else { return }
            let name = tile.alt ?? "Picture"

            actions.append(NSAccessibilityCustomAction(name: "Add picture: \(name)") { [weak self] in
                DispatchQueue.main.async { self?.choosePicture(for: range) }
                return true
            })
            actions.append(NSAccessibilityCustomAction(name: "Remove picture: \(name)") { [weak self] in
                DispatchQueue.main.async { self?.removeMissingPicture(at: range) }
                return true
            })
        }
        return actions
    }

    func pictureDrop(_ sender: any NSDraggingInfo) -> (range: NSRange, file: URL)? {
        guard isEditable,
              let file = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
                  .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
              ]) as? [URL])?.first,
              let range = missingPicture(at: convert(sender.draggingLocation, from: nil)) else { return nil }
        return (range, file)
    }
}
