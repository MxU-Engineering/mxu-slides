import XCTest
@testable import NDIKit

final class NDISearchPathTests: XCTestCase {
    func testAppProcessReachesTheHelperEmbeddedRedist() {
        let paths = NDILibrary.candidatePaths(
            bundlePath: "/Applications/MxU Slides.app",
            privateFrameworksPath: "/Applications/MxU Slides.app/Contents/Frameworks")
        XCTAssertEqual(paths.first, "/Applications/MxU Slides.app/Contents/Frameworks/libndi.dylib")
        XCTAssertEqual(
            paths.dropFirst().first,
            "/Applications/MxU Slides.app/Contents/XPCServices/NDIHelper.xpc/Contents/Frameworks/libndi.dylib")
        XCTAssertTrue(paths.contains("/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"))
    }

    func testHelperProcessFindsItsOwnCopyFirst() {
        let helper = "/Applications/MxU Slides.app/Contents/XPCServices/NDIHelper.xpc"
        let paths = NDILibrary.candidatePaths(
            bundlePath: helper,
            privateFrameworksPath: helper + "/Contents/Frameworks")
        XCTAssertEqual(paths.first, helper + "/Contents/Frameworks/libndi.dylib")
    }
}
