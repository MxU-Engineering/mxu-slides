import Foundation

public enum StreamAudioSource: Equatable, Sendable {

    case program

    case mix(String)

    case input(String)

    public func apply(to preset: inout StreamRecordPreset, includingProgram: Bool) {
        switch self {
        case .program:
            preset.audioMixId = nil
            preset.audioInputId = nil
            preset.audioInputUid = nil
            preset.audioIncludesProgram = nil
        case .mix(let id):
            preset.audioMixId = id
            preset.audioInputId = nil
            preset.audioInputUid = nil
            preset.audioIncludesProgram = includingProgram ? true : nil
        case .input(let id):
            preset.audioMixId = nil
            preset.audioInputId = id
            preset.audioInputUid = nil
            preset.audioIncludesProgram = includingProgram ? true : nil
        }
    }

    public var storageValue: String {
        switch self {
        case .program: ""
        case .mix(let id): "mix:\(id)"
        case .input(let id): "input:\(id)"
        }
    }

    public init(storageValue: String) {
        if storageValue.hasPrefix("mix:"), storageValue.count > 4 {
            self = .mix(String(storageValue.dropFirst(4)))
        } else if storageValue.hasPrefix("input:"), storageValue.count > 6 {
            self = .input(String(storageValue.dropFirst(6)))
        } else {
            self = .program
        }
    }
}
