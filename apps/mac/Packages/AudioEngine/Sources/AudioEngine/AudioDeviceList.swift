import CoreAudio
import Foundation

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String

    public let channelCount: Int
}

public enum AudioDeviceList {

    public static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioOutputDevice(
                id: id, uid: uid, name: name, channelCount: outputChannelCount(id)
            )
        }
    }

    public static func defaultOutputDevice() -> AudioOutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0,
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return AudioOutputDevice(
            id: id, uid: uid, name: name, channelCount: outputChannelCount(id)
        )
    }

    public struct AudioInputDevice: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        public let uid: String
        public let name: String
        public let channelCount: Int
    }

    public static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasStreams(id, scope: kAudioObjectPropertyScopeInput),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(
                id: id, uid: uid, name: name,
                channelCount: channelCount(id, scope: kAudioObjectPropertyScopeInput)
            )
        }
    }

    public static func inputDevice(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    public static func listenForChanges(
        queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void
    ) -> ListenerToken {
        ListenerToken(queue: queue, onChange: onChange)
    }

    public final class ListenerToken: @unchecked Sendable {
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var addresses: [AudioObjectPropertyAddress]
        private var cancelled = false

        fileprivate init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
            self.queue = queue
            self.block = { _, _ in onChange() }
            self.addresses = [
                kAudioHardwarePropertyDevices,
                kAudioHardwarePropertyDefaultOutputDevice,
            ].map {
                AudioObjectPropertyAddress(
                    mSelector: $0,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            }
            for index in addresses.indices {
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addresses[index], queue, block
                )
            }
        }

        public func cancel() {
            guard !cancelled else { return }
            cancelled = true
            for index in addresses.indices {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addresses[index], queue, block
                )
            }
        }

        deinit { cancel() }
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        channelCount(id, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func channelCount(
        _ id: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        hasStreams(id, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func hasStreams(
        _ id: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr
            && size > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        return value.takeRetainedValue() as String
    }
}

public enum MonitorTakeover {

    public static func silencedOutputs(
        outputs: [(id: String, deviceUID: String?)],
        monitorDeviceUID: String?,
        systemDefaultUID: String?,
        silentUID: String
    ) -> Set<String> {
        let monitor = monitorDeviceUID ?? systemDefaultUID
        return Set(outputs.compactMap { output in
            let device = output.deviceUID ?? systemDefaultUID
            return device != nil && device == monitor && output.deviceUID != silentUID ? output.id : nil
        })
    }
}
