import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.2, *)
public final class ProgramAudioTap: @unchecked Sendable {

    public typealias Sink = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    public enum TapError: Error, Equatable {
        case processObjectUnavailable(OSStatus)
        case tapCreationFailed(OSStatus)
        case formatUnavailable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "program-audio-tap", qos: .userInitiated)
    private let sink: Sink

    public init(sink: @escaping Sink) throws {
        self.sink = sink

        var processObject = AudioObjectID(kAudioObjectUnknown)
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPointer,
                &size, &processObject)
        }
        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw TapError.processObjectUnavailable(status)
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "MxU Program Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(status)
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(
            tapID, &formatAddress, 0, nil, &asbdSize, &asbd)
        guard status == noErr,
            let format = AVAudioFormat(streamDescription: &asbd)
        else {
            teardown()
            throw TapError.formatUnavailable(status)
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MxU Program Audio Tap",
            kAudioAggregateDeviceUIDKey:
                "com.example.mxuslides.program-tap",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        if let outputUID = Self.systemOutputDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: true,
                ]
            ]
        }
        status = AudioHardwareCreateAggregateDevice(
            aggregate as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            teardown()
            throw TapError.aggregateCreationFailed(status)
        }

        let sink = self.sink
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            _, inputData, inputTime, _, _ in

            RealtimeAudioCallback.scope {

                guard inputTime.pointee.mFlags.contains(.hostTimeValid),
                    let buffer = Self.copyBuffer(from: inputData, format: format)
                else { return }
                let hostTime = inputTime.pointee.mHostTime
                let when = AVAudioTime(hostTime: hostTime)
                sink(buffer, when, AVAudioTime.seconds(forHostTime: hostTime))
            }
        }
        guard status == noErr, let ioProcID else {
            teardown()
            throw TapError.ioProcFailed(status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw TapError.ioProcFailed(status)
        }
    }

    deinit {
        teardown()
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func systemOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &deviceID) == noErr, deviceID != kAudioObjectUnknown
        else { return nil }
        var uid: CFString = "" as CFString
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr
        else { return nil }
        return uid as String
    }

    private static func copyBuffer(
        from list: UnsafePointer<AudioBufferList>, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let firstBuffer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list)).first
        guard let firstBuffer, firstBuffer.mDataByteSize > 0 else { return nil }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frames = firstBuffer.mDataByteSize / bytesPerFrame
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list))
        let destination = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList)
        for index in 0 ..< min(source.count, destination.count) {
            guard let fromData = source[index].mData,
                let intoData = destination[index].mData
            else { continue }
            let bytes = min(
                source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(intoData, fromData, Int(bytes))
            destination[index].mDataByteSize = bytes
        }
        return copy
    }
}
