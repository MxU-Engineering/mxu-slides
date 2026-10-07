import XCTest
@testable import MediaEngine

final class CaptureFormatChoiceTests: XCTestCase {
    private typealias Candidate = CaptureFormatChoice.Candidate
    private let yuv: UInt32 = 0x3276_7579  
    private let nv12: UInt32 = 0x3432_3076  

    private func hd(_ index: Int, _ rates: [Double], subtype: UInt32? = nil) -> Candidate {
        Candidate(index: index, width: 1920, height: 1080, subtype: subtype ?? yuv, frameRates: rates)
    }

    func testADefault25ModeMovesToTheThirtyClassAtTheSameSize() {
        let active = hd(0, [25])
        let choice = CaptureFormatChoice.best(
            among: [active, hd(1, [29.97, 30]), hd(2, [50, 59.94, 60])], active: active)
        XCTAssertEqual(choice, CaptureFormatChoice(index: 1, frameRate: 29.97))
    }

    func testWithoutAThirtyClassTheFastestRateWins() {
        let active = hd(0, [25])
        let choice = CaptureFormatChoice.best(among: [active, hd(1, [50, 59.94, 60])], active: active)
        XCTAssertEqual(choice, CaptureFormatChoice(index: 1, frameRate: 59.94))
    }

    func testInputsOnOneDeviceShareTheFirstPick() {
        let shared = CaptureFormatChoice.sharedRates([
            (device: "elgato", rate: nil), (device: "elgato", rate: 30),
            (device: "elgato", rate: 60), (device: "webcam", rate: nil),
        ])
        XCTAssertEqual(shared, ["elgato": 30])
    }

    func testRatesPastSixtyAndOtherSizesAreIgnored() {
        let active = hd(0, [30])
        let uhd = Candidate(index: 1, width: 3840, height: 2160, subtype: yuv, frameRates: [60])
        let choice = CaptureFormatChoice.best(among: [active, uhd, hd(2, [120])], active: active)
        XCTAssertEqual(choice, CaptureFormatChoice(index: 0, frameRate: 30))
    }

    func testATieKeepsTheActivePixelFormatThenTheLowerIndex() {
        let active = hd(2, [25], subtype: nv12)
        let choice = CaptureFormatChoice.best(
            among: [hd(0, [59.94]), hd(1, [59.94], subtype: nv12), active, hd(3, [59.94], subtype: nv12)],
            active: active)
        XCTAssertEqual(choice, CaptureFormatChoice(index: 1, frameRate: 59.94))
    }

    func testThePreferredRateWinsWhenTheDeviceOffersIt() {
        let active = hd(0, [25])
        let formats = [active, hd(1, [29.97002997, 30]), hd(2, [59.94, 60])]
        XCTAssertEqual(
            CaptureFormatChoice.best(among: formats, active: active, preferred: 29.97),
            CaptureFormatChoice(index: 1, frameRate: 29.97002997))
        XCTAssertEqual(
            CaptureFormatChoice.best(among: formats, active: active, preferred: 60),
            CaptureFormatChoice(index: 2, frameRate: 60))
    }

    func testAPreferredRateTheDeviceLacksFallsBackToAutomatic() {
        let active = hd(0, [25, 50])
        XCTAssertEqual(
            CaptureFormatChoice.best(among: [active], active: active, preferred: 59.94),
            CaptureFormatChoice(index: 0, frameRate: 50))
    }

    func testRatesListsTheActiveSizeOnceEachSlowestFirst() {
        let active = hd(0, [25])
        let uhd = Candidate(index: 3, width: 3840, height: 2160, subtype: yuv, frameRates: [24])
        let rates = CaptureFormatChoice.rates(
            among: [active, hd(1, [59.94005994, 29.97002997]), hd(2, [29.97, 120], subtype: nv12), uhd],
            active: active)
        XCTAssertEqual(rates, [25, 29.97, 59.94])
    }

    func testNoUsableRateAnswersNil() {
        let active = hd(0, [120])
        XCTAssertNil(CaptureFormatChoice.best(among: [active], active: active))
    }
}
