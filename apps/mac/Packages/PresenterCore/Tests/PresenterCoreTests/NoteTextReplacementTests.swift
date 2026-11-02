import AppKit
import Testing
@testable import PresenterCore

@MainActor
@Suite struct NoteTextReplacementTests {
    private let mark = NSAttributedString.Key("test.slideMark")

    @MainActor private final class Undo: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    @Test func eachRunKeepsOnlyItsOwnMarkWithTheCaretInAMarkedPassage() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.textStorage?.setAttributedString(NSAttributedString(string: "Title", attributes: [mark: "title"]))
        view.setSelectedRange(NSRange(location: 2, length: 0))

        let note = NSMutableAttributedString(string: "Unshakable", attributes: [mark: "title"])
        note.append(NSAttributedString(string: "\nIntro: the earthquake"))
        #expect(view.replaceKeepingAttributes(NSRange(location: 0, length: view.textStorage!.length), with: note))

        let storage = view.textStorage!
        #expect(storage.string == "Unshakable\nIntro: the earthquake")
        #expect(storage.attribute(mark, at: 0, effectiveRange: nil) as? String == "title")
        #expect(storage.attribute(mark, at: 12, effectiveRange: nil) == nil)
    }

    @Test func theRewriteIsOneUndoableEdit() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let undo = Undo()
        view.delegate = undo
        view.allowsUndo = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "Before"))

        view.replaceKeepingAttributes(NSRange(location: 0, length: 6), with: NSAttributedString(string: "After, with more"))
        #expect(view.textStorage?.string == "After, with more")
        undo.manager.undo()
        #expect(view.textStorage?.string == "Before")
    }

    @Test func slideNoteParenthesesWearTheWordsAttributesNotTheCardAbove() {
        let card = NSMutableParagraphStyle()
        card.maximumLineHeight = 2
        card.paragraphSpacing = 120
        let body = NSMutableParagraphStyle()
        body.paragraphSpacing = 8
        let note = NSMutableAttributedString(string: "\u{FFFC}\n", attributes: [.paragraphStyle: card, mark: "card"])
        note.append(NSAttributedString(string: "Intro: the earthquake", attributes: [.paragraphStyle: body]))
        let words = NSRange(location: 2, length: 21)

        let wrapped = note.slideNoteWrapped(words)
        #expect(wrapped.string == "(Intro: the earthquake)")
        for location in [0, wrapped.length - 1] {
            #expect((wrapped.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing == 8)
            #expect(wrapped.attribute(mark, at: location, effectiveRange: nil) == nil)
        }
    }

    @Test func slideNoteIsOneUndoableEdit() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let undo = Undo()
        view.delegate = undo
        view.allowsUndo = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "Intro: the earthquake"))
        let range = NSRange(location: 0, length: 21)

        view.replaceKeepingAttributes(range, with: view.textStorage!.slideNoteWrapped(range))
        #expect(view.textStorage?.string == "(Intro: the earthquake)")
        undo.manager.undo()
        #expect(view.textStorage?.string == "Intro: the earthquake")
    }
}
