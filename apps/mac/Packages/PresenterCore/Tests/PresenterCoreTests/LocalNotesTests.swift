import Foundation
import Testing
@testable import PresenterCore

@Test func aNewNoteIsEmptyAndLocal() {
    let note = LocalNotes.note(name: "Sunday", body: nil)
    #expect(note.origin == LocalNotes.origin)
    #expect(note.name == "Sunday")
    #expect(note.body == NoteBody(blocks: [], plainText: ""))
    #expect(LocalNotes.note(name: "A", body: nil).id != note.id)
}

@Test func aPastedNoteIsNamedAfterItsFirstLine() {
    #expect(LocalNotes.pastedName("\n  Unshakable \nHebrews 12") == "Unshakable")
    #expect(LocalNotes.pastedName(" \n\n") == "Untitled Note")
    let long = String(repeating: "a", count: 80)
    #expect(LocalNotes.pastedName(long) == String(repeating: "a", count: 59) + "…")
}
