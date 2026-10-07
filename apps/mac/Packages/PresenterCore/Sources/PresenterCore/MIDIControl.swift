import Foundation

public enum MIDIDeviceDirection: String, Codable, CaseIterable, Sendable {
    case output
    case input
    case both

    public var displayName: String {
        switch self {
        case .output: "Output"
        case .input: "Input"
        case .both: "In + Out"
        }
    }
}

public struct MIDIDeviceEntry: Codable, Identifiable, Equatable, Sendable {
    public var uid: Int32
    public var name: String

    public var sourceUid: Int32?

    public var enabled: Bool?

    public var direction: MIDIDeviceDirection?

    public var channel: Int?

    public var id: Int32 { uid }
    public var isEnabled: Bool { enabled ?? true }
    public var effectiveDirection: MIDIDeviceDirection { direction ?? .output }
    public var wantsOutput: Bool { effectiveDirection != .input }
    public var wantsInput: Bool { effectiveDirection != .output }

    public init(
        uid: Int32, name: String, sourceUid: Int32? = nil,
        enabled: Bool? = nil, direction: MIDIDeviceDirection? = nil,
        channel: Int? = nil
    ) {
        self.uid = uid
        self.name = name
        self.sourceUid = sourceUid
        self.enabled = enabled
        self.direction = direction
        self.channel = channel
    }

    public func acceptsChannel(ofStatus status: UInt8) -> Bool {
        guard let channel else { return true }
        return channel == Int(status & 0x0F) + 1
    }

    public func isConnected(destinations: Set<Int32>, sources: Set<Int32>) -> Bool {
        let outputOK = !wantsOutput || destinations.contains(uid)
        let inputOK = !wantsInput || sources.contains(sourceUid ?? uid)
        return outputOK && inputOK
    }
}

extension Array where Element == MIDIDeviceEntry {

    public var outputTargetUIDs: Set<Int32>? {
        isEmpty ? nil : Set(filter { $0.isEnabled && $0.wantsOutput }.map(\.uid))
    }

    public var inputSourceUIDs: Set<Int32> {
        Set(compactMap { $0.isEnabled && $0.wantsInput ? ($0.sourceUid ?? $0.uid) : nil })
    }
}

public struct MIDIDeviceBinding: Codable, Equatable, Sendable {
    public var destinationUID: Int32?
    public var sourceUID: Int32?

    public init(destinationUID: Int32? = nil, sourceUID: Int32? = nil) {
        self.destinationUID = destinationUID
        self.sourceUID = sourceUID
    }
}

public struct MIDIEndpoint: Equatable, Sendable {
    public var uid: Int32
    public var name: String

    public init(uid: Int32, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct ResolvedMIDIDevice: Equatable, Sendable, Identifiable {
    public var device: MIDIDevice
    public var destinationUID: Int32?
    public var sourceUID: Int32?

    public var id: String { device.id }
    public var isEnabled: Bool { device.enabled ?? true }

    public var effectiveDirection: MIDIDeviceItemDirection { device.direction ?? .both }
    public var wantsOutput: Bool { effectiveDirection != .input }
    public var wantsInput: Bool { effectiveDirection != .output }

    public func acceptsChannel(ofStatus status: UInt8) -> Bool {
        guard let channel = device.channel else { return true }
        return channel == Int(status & 0x0F) + 1
    }

    public func isConnected(destinations: Set<Int32>, sources: Set<Int32>) -> Bool {
        let outputOK = !wantsOutput || destinationUID.map(destinations.contains) == true
        let inputOK = !wantsInput || sourceUID.map(sources.contains) == true
        return outputOK && inputOK
    }

    public init(device: MIDIDevice, destinationUID: Int32? = nil, sourceUID: Int32? = nil) {
        self.device = device
        self.destinationUID = destinationUID
        self.sourceUID = sourceUID
    }
}

extension MIDIDeviceItemDirection {
    public var displayName: String {
        switch self {
        case .output: "Output"
        case .input: "Input"
        case .both: "In + Out"
        }
    }
}

public enum MIDIDeviceResolver {
    public static func resolve(
        devices: [MIDIDevice],
        bindings: [String: MIDIDeviceBinding],
        destinations: [MIDIEndpoint],
        sources: [MIDIEndpoint]
    ) -> [ResolvedMIDIDevice] {
        devices.map { device in
            let binding = bindings[device.id]
            return ResolvedMIDIDevice(
                device: device,
                destinationUID: binding?.destinationUID ?? autoBind(
                    names: device.destinationNames, fallback: device.name, in: destinations),
                sourceUID: binding?.sourceUID ?? autoBind(
                    names: device.sourceNames, fallback: device.name, in: sources)
            )
        }
    }

    public static func discovered(
        destinations: [MIDIEndpoint], sources: [MIDIEndpoint]
    ) -> [MIDIDeviceEntry] {
        var unclaimed = sources
        var devices = destinations.map { destination in
            var device = MIDIDeviceEntry(uid: destination.uid, name: destination.name)
            if let match = unclaimed.firstIndex(where: { $0.name == destination.name }) {
                device.sourceUid = unclaimed.remove(at: match).uid
            }
            return device
        }
        devices.append(contentsOf: unclaimed.map {
            MIDIDeviceEntry(uid: $0.uid, name: $0.name, sourceUid: $0.uid, direction: .input)
        })
        return devices
    }

    private static func autoBind(
        names: [String]?, fallback: String, in endpoints: [MIDIEndpoint]
    ) -> Int32? {
        for name in (names?.isEmpty == false ? names! : [fallback]) {
            if let match = endpoints.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return match.uid
            }
        }
        return nil
    }
}

public enum MIDINote {
    private static let letters = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    public static func name(_ number: Int) -> String {
        let clamped = min(max(number, 0), 127)
        return "\(letters[clamped % 12])\(clamped / 12 - 2)"
    }
}

public enum MIDIOutTarget: Equatable, Sendable {
    case settingsSelection
    case device(Int32)
    case skip(String)

    public static func resolve(
        deviceId: String?, items: [ResolvedMIDIDevice]
    ) -> MIDIOutTarget {
        guard let deviceId, !deviceId.isEmpty else { return .settingsSelection }
        guard let item = items.first(where: { $0.id == deviceId }) else {
            return .skip("device missing")
        }
        guard item.isEnabled else { return .skip("device off") }
        guard item.wantsOutput else { return .skip("device is input-only") }
        guard let uid = item.destinationUID else { return .skip("port not present") }
        return .device(uid)
    }
}

extension Array where Element == ResolvedMIDIDevice {

    public var outputTargetUIDs: Set<Int32>? {
        isEmpty ? nil : Set(compactMap { $0.isEnabled && $0.wantsOutput ? $0.destinationUID : nil })
    }

    public var inputSourceUIDs: Set<Int32> {
        Set(compactMap { $0.isEnabled && $0.wantsInput ? $0.sourceUID : nil })
    }
}

public enum MIDICommandGroup: String, CaseIterable, Sendable {
    case clears
    case video
    case presentation
    case selectByIndex

    public var displayName: String {
        switch self {
        case .clears: "Clear Commands"
        case .video: "Video Controls"
        case .presentation: "Presentation Actions"
        case .selectByIndex: "Select by Index"
        }
    }
}

public enum MIDICommand: String, Codable, CaseIterable, Sendable {
    case clearAll
    case clearSlides
    case clearMedia
    case clearOverlays
    case clearAudio
    case clearAlerts
    case clearSignage
    case videoGoToBeginning
    case videoPlayPause
    case videoPlay
    case videoPause
    case nextServiceItem
    case previousServiceItem
    case nextSlide
    case previousSlide
    case selectService
    case selectServiceItem
    case triggerSlide
    case selectMediaPlaylist
    case triggerMedia
    case selectAudioPlaylist
    case triggerAudio
    case toggleOverlay
    case selectOverlayFolder
    case selectActionComboFolder
    case startTimer
    case stopTimer
    case resetTimer
    case triggerActionCombo
    case fireAlert

    public var defaultNote: Int {
        switch self {
        case .clearAll: 0
        case .clearSlides: 1
        case .clearMedia: 2
        case .clearOverlays: 3
        case .clearAudio: 4
        case .clearAlerts: 28
        case .clearSignage: 34 
        case .videoGoToBeginning: 6
        case .videoPlayPause: 7
        case .videoPlay: 8
        case .videoPause: 9
        case .nextServiceItem: 10
        case .previousServiceItem: 11
        case .nextSlide: 12
        case .previousSlide: 13
        case .selectService: 17
        case .selectServiceItem: 18
        case .triggerSlide: 19
        case .selectMediaPlaylist: 20
        case .triggerMedia: 21
        case .selectAudioPlaylist: 22
        case .triggerAudio: 23
        case .toggleOverlay: 24
        case .selectOverlayFolder: 32
        case .selectActionComboFolder: 31
        case .startTimer: 25
        case .stopTimer: 26
        case .resetTimer: 27
        case .triggerActionCombo: 29
        case .fireAlert: 33
        }
    }

    public var usesVelocityIndex: Bool {
        group == .selectByIndex
    }

    public var group: MIDICommandGroup {
        switch self {
        case .clearAll, .clearSlides, .clearMedia, .clearOverlays, .clearAudio, .clearAlerts,
             .clearSignage:
            .clears
        case .videoGoToBeginning, .videoPlayPause, .videoPlay, .videoPause:
            .video
        case .nextServiceItem, .previousServiceItem, .nextSlide, .previousSlide:
            .presentation
        case .selectService, .selectServiceItem, .triggerSlide,
             .selectMediaPlaylist, .triggerMedia, .selectAudioPlaylist, .triggerAudio,
             .toggleOverlay, .selectOverlayFolder, .selectActionComboFolder,
             .startTimer, .stopTimer, .resetTimer, .triggerActionCombo, .fireAlert:
            .selectByIndex
        }
    }

    public var displayName: String {
        switch self {
        case .clearAll: "Clear All"
        case .clearSlides: "Clear Slides"
        case .clearMedia: "Clear Media"
        case .clearOverlays: "Clear Overlays"
        case .clearAudio: "Clear Music"
        case .clearAlerts: "Clear Alerts"
        case .clearSignage: "Clear Signage"
        case .videoGoToBeginning: "Go to Beginning"
        case .videoPlayPause: "Play/Pause"
        case .videoPlay: "Play"
        case .videoPause: "Pause"
        case .nextServiceItem: "Next Service Item"
        case .previousServiceItem: "Previous Service Item"
        case .nextSlide: "Next Slide"
        case .previousSlide: "Previous Slide"
        case .selectService: "Select Service"
        case .selectServiceItem: "Select Service Item"
        case .triggerSlide: "Trigger Slide"
        case .selectMediaPlaylist: "Select Media Playlist"
        case .triggerMedia: "Trigger Media"
        case .selectAudioPlaylist: "Select Music Playlist"
        case .triggerAudio: "Trigger Music"
        case .toggleOverlay: "Toggle Overlay"
        case .selectOverlayFolder: "Select Overlay Folder"
        case .selectActionComboFolder: "Select Combo Folder"
        case .startTimer: "Start Timer"
        case .stopTimer: "Stop Timer"
        case .resetTimer: "Reset Timer"
        case .triggerActionCombo: "Run Action Combo"
        case .fireAlert: "Fire Alert"
        }
    }
}

public struct MIDICommandMap: Codable, Equatable, Sendable {

    public var channel: Int?

    public var notes: [String: Int]

    public init(channel: Int? = nil, notes: [String: Int] = [:]) {
        self.channel = channel
        self.notes = notes
    }

    public func note(for command: MIDICommand) -> Int {
        notes[command.rawValue] ?? command.defaultNote
    }

    public mutating func setNote(_ note: Int, for command: MIDICommand) {
        let clamped = max(0, min(127, note))
        if clamped == command.defaultNote {
            notes.removeValue(forKey: command.rawValue)
        } else {
            notes[command.rawValue] = clamped
        }
    }

    public func command(forNote note: Int) -> MIDICommand? {
        MIDICommand.allCases.first { self.note(for: $0) == note }
    }

    public func resolve(
        status: UInt8, data1: UInt8, data2: UInt8
    ) -> (command: MIDICommand, velocity: Int)? {
        guard status & 0xF0 == 0x90, data2 > 0 else { return nil }
        if let channel, channel != Int(status & 0x0F) + 1 { return nil }
        guard let command = command(forNote: Int(data1)) else { return nil }
        return (command, Int(data2))
    }

    public static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = max(0, min(127, note))
        return "\(names[clamped % 12])\(clamped / 12 - 2)"
    }
}

public enum MIDIParse {
    public struct ChannelMessage: Equatable, Sendable {
        public var status: UInt8
        public var data1: UInt8
        public var data2: UInt8

        public init(status: UInt8, data1: UInt8, data2: UInt8) {
            self.status = status
            self.data1 = data1
            self.data2 = data2
        }
    }

    public static func channelMessages(in bytes: [UInt8]) -> [ChannelMessage] {
        var result: [ChannelMessage] = []
        var index = 0
        var running: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0xF8 {
                index += 1
                continue
            }
            let status: UInt8
            if byte & 0x80 != 0 {
                index += 1
                if byte >= 0xF0 {
                    running = nil
                    switch byte {
                    case 0xF0:
                        while index < bytes.count, bytes[index] != 0xF7 { index += 1 }
                        index += 1
                    case 0xF1, 0xF3: index += 1
                    case 0xF2: index += 2
                    default: break
                    }
                    continue
                }
                status = byte
                running = byte
            } else if let current = running {
                status = current
            } else {
                index += 1
                continue
            }
            let dataCount = (0xC0 ... 0xDF).contains(status) ? 1 : 2
            var data: [UInt8] = []
            while data.count < dataCount, index < bytes.count {
                let next = bytes[index]
                if next >= 0xF8 {
                    index += 1
                    continue
                }

                if next & 0x80 != 0 { break }
                data.append(next)
                index += 1
            }
            guard data.count == dataCount else { continue }
            result.append(ChannelMessage(
                status: status,
                data1: data[0],
                data2: dataCount == 2 ? data[1] : 0
            ))
        }
        return result
    }
}
