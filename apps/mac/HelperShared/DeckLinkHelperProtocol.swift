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

    func sendFrame(
        _ surface: IOSurface, reply: @escaping (_ delivered: Bool, _ timing: Data) -> Void)

    func stopOutput()

    func ping(reply: @escaping (Bool) -> Void)

    func startInput(
        devicePersistentID: Int64, reply: @escaping (_ error: String?) -> Void)

    func stopInput()
}

@objc protocol DeckLinkInputSinkProtocol {

    func inputFrame(_ surface: IOSurface, hostTime: Double, reply: @escaping () -> Void)

    func inputAudio(_ samples: Data, frames: Int32, channels: Int32, hostTime: Double)

    func inputFormat(_ name: String, interlaced: Bool)

    func inputSignal(_ present: Bool)
}

struct DeckLinkHelperDevice: Codable, Equatable, Identifiable {
    let name: String
    let persistentID: Int64
    let supportsPlayback: Bool
    let supportsInternalKeying: Bool
    let supportsExternalKeying: Bool

    var supportsCapture = false

    var captureAudioChannels = 2

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

struct DeckLinkCardTiming: Codable, Equatable {

    let completions: UInt64
    let lastCompletionHostTime: Double

    let repeats: UInt64
    let skips: UInt64

    let late: UInt64
    let dropped: UInt64

    let jumps: UInt64
}

enum DeckLinkHelperIdentity {

    static let serviceName = "com.example.mxuslides.DeckLinkHelper"
}
