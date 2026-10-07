import XCTest
@testable import NDIKit

final class NDIRuntimeConfigTests: XCTestCase {
    func testPinnedConfigListsTheAdapter() {
        let json = String(
            decoding: NDIRuntimeConfig.configJSON(allowedAdapterIPs: ["10.1.20.7"]),
            as: UTF8.self)
        XCTAssertEqual(json, #"{"ndi":{"adapters":{"allowed":["10.1.20.7"]}}}"#)
    }

    func testAutomaticConfigRestrictsNothing() {
        let json = String(
            decoding: NDIRuntimeConfig.configJSON(allowedAdapterIPs: []),
            as: UTF8.self)
        XCTAssertEqual(json, #"{"ndi":{}}"#)
    }

    func testActivateWritesTheFileAndPointsTheProcessAtIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndi-config-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer {
            try? FileManager.default.removeItem(at: dir)

            unsetenv("NDI_CONFIG_DIR")
        }
        try NDIRuntimeConfig.activate(directory: dir, allowedAdapterIPs: ["192.168.4.9"])
        XCTAssertEqual(String(cString: getenv("NDI_CONFIG_DIR")), dir.path)
        let written = try Data(contentsOf: dir.appendingPathComponent(NDIRuntimeConfig.fileName))
        XCTAssertEqual(written, NDIRuntimeConfig.configJSON(allowedAdapterIPs: ["192.168.4.9"]))
    }

    func testAdapterListIsLoopbackFreeAndAddressed() {

        for adapter in NDIAdapterList.current() {
            XCTAssertFalse(adapter.bsdName.hasPrefix("lo"))
            XCTAssertFalse(adapter.ipv4.isEmpty)
            XCTAssertFalse(adapter.displayName.isEmpty)
        }
    }
}
