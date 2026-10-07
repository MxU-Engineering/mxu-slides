import Foundation
import MachO
import Testing
@testable import PresenterCore

@Test func buildIdentityReadsTheCommitAndCallsAMissingOneUnknown() {
    let release = BuildIdentity(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "4210", "MXUGitCommit": "1a2b3c4d5e"])
    #expect(release == BuildIdentity(version: "0.1.0", build: "4210", commit: "1a2b3c4d5e"))
    #expect(release.reportFields == ["app_version": "0.1.0", "app_build": "4210", "app_commit": "1a2b3c4d5e"])

    let dev = BuildIdentity(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "MXUGitCommit": ""])
    let unexpanded = BuildIdentity(info: ["MXUGitCommit": "$(MXU_GIT_COMMIT)"])
    #expect(dev.commit == nil && dev.reportFields["app_commit"] == "unknown")
    #expect(unexpanded.commit == nil && unexpanded.version == "?" && unexpanded.build == "?")
    #expect(BuildIdentity(info: nil).commitLabel == "unknown")
}

@Test func launchLineCarriesVersionCommitAndImage() {
    let identity = BuildIdentity(version: "0.1.0", build: "4210", commit: "1a2b3c4d5e")
    let uuid = UUID(uuidString: "5B1E0F4A-0000-4000-8000-00000000ABCD")
    let image = LoadedImage(name: "MxU Slides", loadAddress: 0x1_0450_0000, uuid: uuid)
    #expect(
        identity.launchLine(os: "Version 26.5.1 (Build 25F80)", image: image)
            == "v0.1.0 (4210) commit 1a2b3c4d5e on macOS Version 26.5.1 (Build 25F80), image MxU Slides at 0x104500000 uuid 5B1E0F4A-0000-4000-8000-00000000ABCD")
    #expect(BuildIdentity(info: nil).launchLine(os: "x", image: nil) == "v? (?) commit unknown on macOS x, image unknown")
}

@Test func uuidWalkFindsLCUUIDPastOtherCommandsAndRejectsNonMachO() {

    let expected = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    var bytes = [UInt8](repeating: 0, count: 32 + 16 + 24)
    func put(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
    }
    put(MH_MAGIC_64, at: 0)
    put(2, at: 16)  
    put(UInt32(LC_SOURCE_VERSION), at: 32)
    put(16, at: 36)
    put(UInt32(LC_UUID), at: 48)
    put(24, at: 52)
    withUnsafeBytes(of: expected.uuid) { bytes.replaceSubrange(56..<72, with: $0) }
    #expect(bytes.withUnsafeBytes { LoadedImage.uuid(inMachHeader: $0.baseAddress!) } == expected)

    put(0xFEED_FACE, at: 0)
    #expect(bytes.withUnsafeBytes { LoadedImage.uuid(inMachHeader: $0.baseAddress!) } == nil, "a 32-bit or foreign header is not walked")
}

@Test func loadedImageDescribesTheCallersOwnImage() throws {
    let image = try #require(LoadedImage(containing: #dsohandle))
    #expect(image.loadAddress == UInt(bitPattern: #dsohandle))
    #expect(image.uuid != nil && !image.name.isEmpty)
    #expect(image.description.hasPrefix("\(image.name) at 0x"))
}
