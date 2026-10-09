import Foundation
import Testing

@testable import PresenterCore

struct SongSiteTests {
    @Test func songSelectOpensOnTheSongsNumberElseASearchForItsTitle() {
        #expect(SongSite.songSelect.start(ccliNumber: 7_115_744, title: "Way Maker").absoluteString
            == "https://songselect.ccli.com/songs/7115744")
        #expect(SongSite.songSelect.start(title: "Way Maker").absoluteString
            == "https://songselect.ccli.com/search/results?search=Way%20Maker")
        #expect(SongSite.songSelect.searchURL("  ") == SongSite.songSelect.home)
    }

    @Test func multiTracksOpensOnThePlansSongPageElseASearch() {
        #expect(SongSite.multiTracks.start(pageURL: "https://www.multitracks.com/songs/Bethel-Music/Center/").absoluteString
            == "https://www.multitracks.com/songs/Bethel-Music/Center/")
        #expect(SongSite.multiTracks.start(title: "Center", pageURL: "javascript:alert(1)").absoluteString
            == "https://www.multitracks.com/songs/?search=Center")
        #expect(SongSite.multiTracks.start() == SongSite.multiTracks.home)
    }

    @Test(arguments: [
        ("application/pdf", "Center.pdf", nil, true, true, true),
        ("application/pdf", "preview.pdf", nil, false, true, false),
        ("text/plain", "way-maker.chordpro", nil, true, true, true),
        ("text/plain", "robots.txt", "inline", false, true, false),
        ("text/html", "song", "attachment; filename=\"Way Maker.txt\"", true, true, true),
        ("application/octet-stream", "lyrics", nil, true, false, true),
        ("text/html", "songs/7115744", nil, true, true, false),
    ] as [(String, String, String?, Bool, Bool, Bool)])
    func downloadsAreFilesNotPages(mime: String, filename: String, disposition: String?, mainFrame: Bool, canShow: Bool, expected: Bool) {
        #expect(SongSite.isDownload(
            mimeType: mime, filename: filename, contentDisposition: disposition,
            isMainFrame: mainFrame, canShow: canShow) == expected)
    }
}
