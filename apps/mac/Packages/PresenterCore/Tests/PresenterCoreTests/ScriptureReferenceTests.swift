import Foundation
import Testing
@testable import PresenterCore

@Test func referencesAreFoundInEveryUsualShape() {
    let lines: [(String, String, Bool)] = [
        ("John 3:16", "John 3:16", true),
        ("see Matthew 5:3-12 for the list", "Matthew 5:3-12", true),
        ("1 John 4:8", "1 John 4:8", true),
        ("Song of Songs 2:1", "Song of Songs 2:1", true),
        ("Ps. 23:1 (ESV)", "Ps. 23:1 (ESV)", true),
        ("Matthew 3 v 28", "Matthew 3 v 28", true),
        ("Rom 8:28, 31", "Rom 8:28, 31", true),
        ("Psalm 23", "Psalm 23", false),
        ("Isaiah 53:4-6; 1 Peter 2:24", "Isaiah 53:4-6", true),
    ]
    for (line, expected, hasVerse) in lines {
        let found = ScriptureReference.matches(in: line)
        #expect(found.first?.text == expected, Comment(rawValue: line))
        #expect(found.first?.hasVerse == hasVerse, Comment(rawValue: line))
    }
    #expect(ScriptureReference.matches(in: "Isaiah 53:4-6; 1 Peter 2:24").count == 2)
}

@Test func namesAndClocksAreNotReferences() {
    for trap in ["Matthew and Mark helped", "Chapter 3", "3:16 pm", "Psalm", "John went home", "Jobs 3:16"] {
        #expect(ScriptureReference.matches(in: trap).isEmpty, Comment(rawValue: trap))
    }
    #expect(ScriptureReference.isReferenceLine("John 3:16; Romans 5:8"))
    #expect(ScriptureReference.isReferenceLine("(Psalm 23)"))
    #expect(!ScriptureReference.isReferenceLine("John 3:16 says it all"))
    #expect(!ScriptureReference.isReferenceLine(""))
}

@Test func passagesSplitIntoVerseAndReference() {
    #expect(ScriptureReference.split("For God so loved the world\nJohn 3:16")
        == ScriptureReference.Split(verse: "For God so loved the world", reference: "John 3:16"))
    #expect(ScriptureReference.split("John 3:16\nFor God so loved the world")
        == ScriptureReference.Split(verse: "For God so loved the world", reference: "John 3:16"))
    #expect(ScriptureReference.split("For God so loved the world (John 3:16)")
        == ScriptureReference.Split(verse: "For God so loved the world", reference: "John 3:16"))
    #expect(ScriptureReference.split("The Lord is my shepherd - Psalm 23")
        == ScriptureReference.Split(verse: "The Lord is my shepherd", reference: "Psalm 23"))
    #expect(ScriptureReference.split("John 3:16: For God so loved the world")
        == ScriptureReference.Split(verse: "For God so loved the world", reference: "John 3:16"))
    #expect(ScriptureReference.split("Trust in the Lord Proverbs 3:5")
        == ScriptureReference.Split(verse: "Trust in the Lord", reference: "Proverbs 3:5"))
    #expect(ScriptureReference.split("Romans 8:28") == ScriptureReference.Split(verse: "", reference: "Romans 8:28"))

    #expect(ScriptureReference.split("We read Psalm 23 together") == nil)
    #expect(ScriptureReference.split("Grace upon grace") == nil)
}

@Test func aPassageCutsAtTheVerseNumbersItsReferenceNames() {
    #expect(ScriptureReference.verses(of: "Hebrews 12:27–28 (WEB)")! == ("Hebrews 12", 27 ... 28))
    #expect(ScriptureReference.verses(of: "1 John 4:8")! == ("1 John 4", 8 ... 8))
    #expect(ScriptureReference.verses(of: "Psalm 23") == nil && ScriptureReference.verses(of: "Mark 5:3-6:1") == nil)

    let text = "He rose after 3 days. 2 Then he said\n3 Go."
    #expect(ScriptureReference.verses(in: text, numbered: 1 ... 3) == [
        .init(number: nil, text: "He rose after 3 days."), .init(number: 2, text: "Then he said"), .init(number: 3, text: "Go."),
    ])
    #expect(ScriptureReference.verses(in: "No numbers here", numbered: 4 ... 5) == [.init(number: nil, text: "No numbers here")])
    #expect(ScriptureReference.removingVerseNumbers(from: "27 This phrase\n28 Therefore 3 days", numbered: 27 ... 28)
        == "This phrase\nTherefore 3 days")
    #expect(ScriptureReference.Verse(number: 4, text: "Rejoice").numbered == "4 Rejoice")
}

@Test func aReferenceThenASpacedDashLeadsTheVerseAndWEBIsATranslation() {
    #expect(ScriptureReference.split("Psalm 46:1 – God is our refuge") == .init(verse: "God is our refuge", reference: "Psalm 46:1"))
    #expect(ScriptureReference.isReferenceLine("Hebrews 12:27–28 (WEB)"))
}
