import Foundation
import Testing
@testable import PresenterCore

@Suite struct MakeSlidesQAFixesSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    private func block(after marker: String, closedBy end: String, in source: String) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker) expected")
        let tail = source[start.upperBound...]
        return String(tail[..<(try #require(tail.range(of: end), "\(marker) closes")).lowerBound])
    }

    @Test func aPictureThatDidntComeThroughDrawsTheTile() throws {
        let view = try source("NoteDocumentView.swift")
        let image = try block(after: "        case .image:", closedBy: "        case .attachment:", in: view)
        #expect(image.contains("!NoteMedia.isMailChrome(source)"))
        #expect(image.contains("NoteImageStore.shared.cantShow(source)"))
        #expect(image.contains("NoteImageStore.missingPicture(name: block.alt, editable: style.editable)"))
        #expect(view.contains("failed.insert(url)"), "a failed fetch is remembered, so the tile replaces the box")
        #expect(!image.contains("\"\\n\" + alt"), "an alt caption line under a picture parses back as a second picture")
    }

    @Test func anEmptyLineIsNeverAPicture() throws {
        let editing = try source("NoteDocumentEditing.swift")
        let empty = try block(after: "if range.length == 0 {", closedBy: "return Paragraph(marker: marker, runs: [], slide: nil, attachmentText: \"\")", in: editing)
        #expect(empty.contains("case .image, .attachment, .slide: marker = .paragraph"))
    }

    @Test func theMissingPictureTileAddsOrRemovesThePicture() throws {
        let view = try source("NoteDocumentView.swift")
        #expect(view.contains("attachment.missing = true"))
        #expect(view.contains("NoteImageStore.missingPicture(name: block.alt, editable: style.editable)"))
        #expect(view.contains("if isEditable, handleMissingPictureClick(at: clicked) { return }"))
        #expect(view.contains("if let picture = pictureDrop(sender) { return replaceMissingPicture(at: picture.range, with: picture.file) }"))
        #expect(view.contains("\"Picture didn't come through\""))
        #expect(!view.contains("didn't come through, add it"))
        #expect(view.contains("style.editable = editable"))
        let fix = try source("NoteMissingPicture.swift")
        #expect(fix.contains("let saved = save(data, file.lastPathComponent)"), "kept like a pasted picture")
        #expect(fix.contains("insertText(rendered, replacementRange: range)"), "an edit: undo and the save follow")
        #expect(fix.contains("guard shouldChangeText(in: line, replacementString: \"\") else { return }"), "Remove is an undoable edit")
    }

    @Test func aPictureFitsInsideItsPanel() throws {
        let view = try source("NoteDocumentView.swift")
        let fit = try block(after: "class NoteFittedAttachment: NSTextAttachment {", closedBy: "\n}\n", in: view)
        #expect(fit.contains("width - padding - paragraph.firstLineHeadIndent - tail"))
    }

    @Test func theSlidesColumnFollowsTheNotesScroll() throws {
        let sheet = try source("MakeSlidesSheet.swift")
        #expect(sheet.contains("NSView.boundsDidChangeNotification"))
        #expect(try source("NoteDocumentView.swift").contains("guard !jumping, let clip"), "a tile click's own note scroll doesn't count")
        #expect(sheet.contains("scroller.firstVisibleGroup()"))
        #expect(sheet.contains("proxy.scrollTo(first.id, anchor: .top)"))
    }

    @Test func anEmptyNoteSaysHowToStart() throws {
        #expect(try source("NoteReaderView.swift").contains("Paste your notes, or start typing…"))
    }
}
