import CoreGraphics
import Testing
@testable import PresenterCore

private let frames: [Int: CGRect] = Dictionary(uniqueKeysWithValues: (0 ..< 6).map { index in
    (index, CGRect(x: CGFloat(index % 3) * 112, y: CGFloat(index / 3) * 72, width: 100, height: 60))
})

private func spot(_ x: CGFloat, _ y: CGFloat, count: Int = 6) -> SlideGridDrop.Spot {
    SlideGridDrop.spot(at: CGPoint(x: x, y: y), tileFrames: frames, count: count, rowGap: 12)
}

@Test func theGapBetweenTwoTilesInsertsBetweenThem() {
    #expect(spot(106, 30) == .before(1))
    #expect(spot(106, 30).insertionIndex == 1)
    #expect(spot(218, 100) == .before(5), "second row, between slides 4 and 5")
}

@Test func pastARowsLastTileLandsAfterIt() {
    #expect(spot(400, 30) == .after(2))
    #expect(spot(400, 30).insertionIndex == 3)
}

@Test func theGapBelowARowBelongsToItsNearerHalf() {
    #expect(spot(10, 64) == .before(0), "upper half of the row gap: the first row")
    #expect(spot(10, 70) == .before(3), "lower half: the next row")
}

@Test func belowEveryRowLandsAfterTheLastSlide() {
    #expect(spot(10, 500) == .after(5))
    #expect(SlideGridDrop.spot(at: .zero, tileFrames: [:], count: 0, rowGap: 12) == .before(0), "an empty deck")
}
