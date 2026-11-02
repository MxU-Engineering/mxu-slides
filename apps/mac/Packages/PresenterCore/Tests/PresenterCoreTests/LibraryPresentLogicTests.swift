import Foundation
import Testing
@testable import PresenterCore

@Suite struct LibraryPresentLogicTests {
    @Test func onlyMediaMusicAndOverlaysFireFromTheirRow() {
        #expect(LibraryPresentLogic.fires(.media))
        #expect(LibraryPresentLogic.fires(.audio))
        #expect(LibraryPresentLogic.fires(.overlay))
        #expect(!LibraryPresentLogic.fires(.presentation))
        #expect(!LibraryPresentLogic.fires(.theme))
    }

    @Test func decksAndThemesEditFromTheirRowButNeverFire() {
        for kind in [DocumentKind.presentation, .theme] {
            #expect(LibraryPresentLogic.editsFromRow(kind))
            #expect(!LibraryPresentLogic.fires(kind))
        }
        for kind in [DocumentKind.media, .audio, .overlay] {
            #expect(LibraryPresentLogic.editsFromRow(kind))
        }
        #expect(!LibraryPresentLogic.editsFromRow(.service))
    }

    @Test func volunteersGetTheFiringLibrariesByDefault() {
        #expect(LibraryPresentLogic.volunteerKinds(stored: nil) == [.presentation, .overlay, .media, .audio])
        #expect(LibraryPresentLogic.volunteerKinds(stored: "media,overlay") == [.overlay, .media], "kept in tab order")
        #expect(LibraryPresentLogic.volunteerKinds(stored: "").isEmpty, "the admin turned every library off")
        #expect(LibraryPresentLogic.volunteerKinds(stored: "theme,media") == [.media], "only firing libraries")
    }

    @Test func onlyDecksTakeTheCenter() {
        #expect(LibraryPresentLogic.takesCenter(.presentation))
        for kind in [DocumentKind.media, .audio, .overlay, .note] {
            #expect(!LibraryPresentLogic.takesCenter(kind))
        }
    }

    @Test func fireLabelSaysWhatAClickDoes() {
        #expect(LibraryPresentLogic.fireLabel(.media, live: false) == "Play")
        #expect(LibraryPresentLogic.fireLabel(.media, live: true) == "Stop")
        #expect(LibraryPresentLogic.fireLabel(.audio, live: true) == "Stop")
        #expect(LibraryPresentLogic.fireLabel(.overlay, live: false) == "Go Live")
        #expect(LibraryPresentLogic.fireLabel(.overlay, live: true) == "Take Down")
    }

    @Test func thumbnailsOnVisualKinds() {
        for kind in [DocumentKind.presentation, .media, .audio, .overlay, .theme, .confidenceLayout] {
            #expect(LibraryPresentLogic.showsThumbnail(kind))
        }
        #expect(!LibraryPresentLogic.showsThumbnail(.note))
        #expect(!LibraryPresentLogic.showsThumbnail(.service))
    }

    @Test func lastUsedOnFiredKinds() {
        for kind in [DocumentKind.presentation, .media, .audio, .overlay] {
            #expect(LibraryPresentLogic.showsLastUsed(kind))
        }
        #expect(!LibraryPresentLogic.showsLastUsed(.theme))
        #expect(!LibraryPresentLogic.showsLastUsed(.note))
    }

    @Test func lastUsedReadsAsADay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        calendar.locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10)))
        func ago(days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now)! }
        #expect(LibraryPresentLogic.lastUsedText(nil, now: now, calendar: calendar) == "Not used yet")
        #expect(LibraryPresentLogic.lastUsedText(now, now: now, calendar: calendar) == "Used today")
        #expect(LibraryPresentLogic.lastUsedText(ago(days: 1), now: now, calendar: calendar) == "Used yesterday")
        #expect(LibraryPresentLogic.lastUsedText(ago(days: 4), now: now, calendar: calendar) == "Used Oct 26")
        #expect(LibraryPresentLogic.lastUsedText(ago(days: 400), now: now, calendar: calendar) == "Used Sep 25, 2025")
    }
}
