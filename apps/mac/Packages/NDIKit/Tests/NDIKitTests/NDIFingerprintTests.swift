import XCTest
@testable import NDIKit

final class NDIFingerprintTests: XCTestCase {
    func testFingerprintIsOrderInsensitive() {
        let wifi = NDIAdapter(bsdName: "en0", displayName: "Wi-Fi", ipv4: "192.168.1.4")
        let wire = NDIAdapter(bsdName: "en5", displayName: "LAN", ipv4: "10.1.20.7")
        XCTAssertEqual(
            NDIAdapterList.fingerprint([wifi, wire]),
            NDIAdapterList.fingerprint([wire, wifi]))
    }

    func testReaddressChangesTheFingerprint() {
        let before = NDIAdapter(bsdName: "en0", displayName: "Wi-Fi", ipv4: "192.168.1.4")
        let after = NDIAdapter(bsdName: "en0", displayName: "Wi-Fi", ipv4: "192.168.2.4")
        XCTAssertNotEqual(
            NDIAdapterList.fingerprint([before]),
            NDIAdapterList.fingerprint([after]))
    }
}
