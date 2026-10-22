import Foundation
import Testing
@testable import PresenterCore

struct ThumbnailResolutionTests {
    @Test func unknownWidthRendersAtTheBase() {
        #expect(ThumbnailResolution.pixelWidth(tileWidth: nil, scale: 2) == 480)
        #expect(ThumbnailResolution.pixelWidth(tileWidth: 0, scale: 2) == 480)
    }

    @Test func picksTheSmallestStepThatCoversTheTile() {

        #expect(ThumbnailResolution.pixelWidth(tileWidth: 230, scale: 2) == 480)

        #expect(ThumbnailResolution.pixelWidth(tileWidth: 470, scale: 2) == 960)

        #expect(ThumbnailResolution.pixelWidth(tileWidth: 950, scale: 2) == 1920)
        #expect(ThumbnailResolution.pixelWidth(tileWidth: 1400, scale: 2) == 1920)

        #expect(ThumbnailResolution.pixelWidth(tileWidth: 470, scale: 1) == 480)
    }

    @Test func postersMatchTheTileAboveTheBase() {
        #expect(ThumbnailResolution.posterPixels(forWidth: 480) == PosterDecode.maxPixelSize)
        #expect(ThumbnailResolution.posterPixels(forWidth: 960) == 960)
        #expect(ThumbnailResolution.posterPixels(forWidth: 1920) == 1920)
    }
}
