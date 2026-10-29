import Foundation
import PresenterCore
import SlideScene
import Testing
@testable import BibleKit

@Suite struct BibleTests {
    let corpus: BibleCorpus
    init() throws { corpus = try BibleCorpus(.bundledWEB()) }

    @Test func completePublisherTextLoadsOffline() throws {
        #expect(corpus.books.count == 66)
        #expect(corpus.verses.count == 31_098)
        #expect(corpus.verses.first?.reference == "Genesis 1:1")
        #expect(corpus.verses.last?.reference == "Revelation 22:21")
        #expect(try corpus.passage("John 3:16").first?.text.contains("For God so loved the world") == true)
        #expect(corpus.chapters(in: "PSA").count == 150)
    }

    @Test func referencesResolveRangesAliasesAndNumberedBooks() throws {
        #expect(try corpus.passage("John 3:16–18").count == 3)
        #expect(try corpus.passage("Jn.3:16-18").count == 3)
        #expect(try corpus.passage("1 John 4:7–12").count == 6)
        #expect(try corpus.passage("1John4:7").first?.book == "1JN")
        #expect(try corpus.passage("Psalm 23").count == 6)
        #expect(try corpus.passage("Song of Solomon 1:1").first?.book == "SNG")
        let crossing = try corpus.passage("John 3:36–4:2")
        #expect(crossing.map(\.verse) == [36, 1, 2])
        #expect(BibleCorpus.reference(for: crossing) == "John 3:36–4:2")
        for invalid in ["", "Love", "Fake 1:1", "John 999", "John 3:99", "John 3:18–16", "John 0", "John 3:16 rubbish"] {
            #expect(throws: BibleError.self) { try corpus.passage(invalid) }
        }
    }

    @Test func searchIsCaseInsensitiveBoundedAndRequiresEveryWord() {
        #expect(corpus.search("").isEmpty)
        #expect(corpus.search("LORD shepherd").contains { $0.reference == "Psalms 23:1" })
        #expect(corpus.search("love", limit: 10).count == 10)
        #expect(corpus.search("impossiblewordthatcannotoccur").isEmpty)
    }

    @Test func navigationCrossesChapterAndBookBoundaries() throws {
        let end = try #require(corpus.passage("John 3:36").first)
        #expect(corpus.adjacent(to: end, offset: 1)?.reference == "John 4:1")
        let genesis = try #require(corpus.verses.first)
        #expect(corpus.adjacent(to: genesis, offset: -1) == nil)
        let jude = try #require(corpus.passage("Jude 1:25").first)
        #expect(corpus.adjacent(to: jude, offset: 1)?.book == "REV")
    }

    @Test func longVersesAndMultiVersePagesNeverLoseWords() throws {
        let verses = try corpus.passage("Esther 8:9")
        let pages = BibleSlides.pages(verses: verses, verseNumbers: false, maxCharacters: 100)
        #expect(pages.count > 1)
        let source = verses.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.map(String.init)
        let pagedWords: [String] = pages.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(pagedWords == source)
        #expect(pages.allSatisfy { $0.reference == "Esther 8:9" })
        let chapter = try corpus.passage("Psalm 23")
        let combined = BibleSlides.pages(verses: chapter, oneVersePerSlide: false, verseNumbers: false, maxCharacters: 300)
        let combinedWords: [String] = combined.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        let chapterWords: [String] = chapter.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(combinedWords == chapterWords)
        #expect(BibleSlides.pages(verses: chapter).count == 6)
    }

    @Test func importedFormatRoundTripsAndRejectsBadRecords() throws {
        let valid = BibleTranslation(id: "TEST", name: "Test translation", copyright: "Test copyright",
                                    verses: [BibleVerse(book: "JHN", chapter: 3, verse: 16, text: "Test text")])
        let data = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(BibleTranslation.self, from: data) == valid)
        #expect(try BibleCorpus(valid).passage("John 3:16").first?.text == "Test text")
        for bad in [
            BibleTranslation(id: "../bad", name: "Bad", copyright: "Test", verses: valid.verses),
            BibleTranslation(id: "BAD", name: "Bad", copyright: "", verses: valid.verses),
            BibleTranslation(id: "BAD", name: "Bad", copyright: "Test", verses: valid.verses + valid.verses),
            BibleTranslation(id: "BAD", name: "Bad", copyright: "Test", verses: [.init(book: "XX", chapter: 1, verse: 1, text: "x")]),
            BibleTranslation(id: "BAD", name: "Bad", copyright: "Test", verses: [.init(book: "GEN", chapter: 0, verse: 1, text: "x")]),
            BibleTranslation(id: "BAD", name: "Bad", copyright: "Test", verses: [.init(book: "GEN", chapter: 1, verse: 1, text: " ")]),
        ] { #expect(throws: BibleError.self) { try BibleCorpus(bad) } }
    }

    @Test func slidesRetainAttributionAndRenderWithoutClippedText() throws {
        let verses = try corpus.passage("Esther 8:9")
        for style in BibleSlideStyle.allCases {
            let pages = BibleSlides.pages(verses: verses, maxCharacters: style == .lowerThird ? 240 : 450)
            for page in pages {
                let slide = BibleSlides.slide(page: page, translation: corpus.translation, style: style)
                #expect(slide.objects.first { $0.name == "Copyright" }?.text == corpus.translation.copyright)
                #expect(slide.objects.first { $0.name == "Reference" }?.text.contains("(WEB)") == true)
                #expect(SlideSceneBuilder.clippedTextObjectIDs(for: slide, theme: nil).isEmpty)
            }
        }
    }

    @Test func copyrightVisibilityIsIndependentOfTranslationAndVerseText() throws {
        let verses = try corpus.passage("John 3:16")
        let page = try #require(BibleSlides.pages(verses: verses).first)
        let visible = BibleSlides.slide(page: page, translation: corpus.translation)
        let hidden = BibleSlides.slide(page: page, translation: corpus.translation, showCopyright: false)
        #expect(visible.objects.contains { $0.name == "Copyright" })
        #expect(!hidden.objects.contains { $0.name == "Copyright" })
        #expect(hidden.objects.first { $0.name == "Verse" }?.text == visible.objects.first { $0.name == "Verse" }?.text)
        #expect(hidden.objects.first { $0.name == "Reference" }?.text.contains("(WEB)") == true)
        #expect(hidden.notes?.contains(corpus.translation.copyright) == true)
        let noLabels = BibleSlides.slide(page: page, translation: corpus.translation, showTranslation: false, showCopyright: false)
        #expect(noLabels.objects.first { $0.name == "Reference" }?.text == "John 3:16")
        #expect(SlideSceneBuilder.clippedTextObjectIDs(for: hidden, theme: nil).isEmpty)
    }

    @Test func anUnsavedPassageCanBePresentedAndClearedInMemory() throws {
        let verses = try corpus.passage("John 3:16–18")
        let slides = BibleSlides.pages(verses: verses).map { BibleSlides.slide(page: $0, translation: corpus.translation) }
        let draft = Presentation(id: "bible-preview-test", name: "John 3:16–18", presentationKind: .deck, themeId: "", slides: slides)
        // This is the same show-state path used by the live Bible grid. No library
        // or database is constructed, and the entire passage stays available.
        var show = ShowState()
        show.fire(slide: slides[1], presentation: draft)
        #expect(show.liveSlide?.slide.id == slides[1].id)
        #expect(show.liveSlide?.presentation?.slides.count == 3)
        show.fire(slide: slides[2], presentation: draft)
        #expect(show.liveSlide?.slide.name == "John 3:18")
        show.clear(function: .slides)
        #expect(show.liveSlide == nil)
    }
}
