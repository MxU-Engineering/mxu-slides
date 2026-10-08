import Foundation
import IOSurface

@objc protocol DeckLinkHelperProtocol {

    func listDevices(reply: @escaping (Data) -> Void)

    func runtimeVersion(reply: @escaping (String, Bool) -> Void)

    func listDisplayModes(devicePersistentID: Int64, reply: @escaping (Data) -> Void)

    func startOutput(
        devicePersistentID: Int64,
        width: Int32,
        height: Int32,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        keying: Int32,
        modeID: Int64,
        reply: @escaping (_ error: String?, _ wireDetail: String) -> Void
    )

    func sendFrame(_ surface: IOSurface, reply: @escaping (_ delivered: Bool) -> Void)

    func stopOutput()

    func ping(reply: @escaping (Bool) -> Void)
}

struct DeckLinkHelperDevice: Codable, Equatable, Identifiable {
    let name: String
    let persistentID: Int64
    let supportsPlayback: Bool
    let supportsInternalKeying: Bool
    let supportsExternalKeying: Bool

    var id: Int64 { persistentID }
}

struct DeckLinkHelperDisplayMode: Codable, Equatable, Identifiable {
    let name: String

    let modeID: Int64
    let width: Int
    let height: Int

    let frameDuration: Int64
    let timeScale: Int64
    let progressive: Bool

    let supportsKeying: Bool

    var id: Int64 { modeID }

    var framesPerSecond: Double {
        Double(timeScale) / Double(frameDuration)
    }

    var mirrorFramesPerSecond: Int {
        Int((framesPerSecond).rounded())
    }
}

enum DeckLinkHelperIdentity {

    static let serviceName = (Bundle.main.bundleIdentifier ?? "com.example.mxuslides") + ".DeckLinkHelper"
}
