import CoreVideo
import DeckLinkKit
import Foundation
import IOSurface

final class DeckLinkOutputStore: @unchecked Sendable {
    static let shared = DeckLinkOutputStore()
    private let lock = NSLock()
    private var outputs: [Int64: (output: DeckLinkOutput, generation: UUID)] = [:]

    func evict(device: Int64) {
        lock.lock()
        let dropped = outputs.removeValue(forKey: device)
        lock.unlock()
        releaseDetached(dropped?.output)
    }

    func install(device: Int64, output: DeckLinkOutput) -> UUID {
        let generation = UUID()
        lock.lock()
        defer { lock.unlock() }
        outputs[device] = (output, generation)
        return generation
    }

    func close(device: Int64, generation: UUID) {
        lock.lock()
        guard outputs[device]?.generation == generation else {
            lock.unlock()
            return
        }
        let dropped = outputs.removeValue(forKey: device)
        lock.unlock()
        releaseDetached(dropped?.output)
    }

    private func releaseDetached(_ output: DeckLinkOutput?) {
        guard let output else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = output  
        }
    }

    func output(device: Int64, generation: UUID) -> DeckLinkOutput? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = outputs[device], entry.generation == generation
        else { return nil }
        return entry.output
    }
}

final class DeckLinkHelperService: NSObject, DeckLinkHelperProtocol {

    private var device: Int64?
    private var generation: UUID?

    weak var connection: NSXPCConnection?

    private var input: DeckLinkInputRelay?

    func listDevices(reply: @escaping (Data) -> Void) {
        let devices = DeckLinkRuntime.devices().map { device in
            DeckLinkHelperDevice(
                name: device.name,
                persistentID: device.persistentID,
                supportsPlayback: device.supportsPlayback,
                supportsInternalKeying: device.supportsInternalKeying,
                supportsExternalKeying: device.supportsExternalKeying,
                supportsCapture: device.supportsCapture,
                captureAudioChannels: DeckLinkInput.audioChannels(forMaximum: device.maxAudioChannels))
        }
        reply((try? JSONEncoder().encode(devices)) ?? Data())
    }

    func runtimeVersion(reply: @escaping (String, Bool) -> Void) {
        reply(
            DeckLinkRuntime.apiVersionString ?? "",
            DeckLinkRuntime.runtimeIsTooOld)
    }

    func listDisplayModes(devicePersistentID: Int64, reply: @escaping (Data) -> Void) {
        let modes = DeckLinkRuntime.displayModes(persistentID: devicePersistentID)
            .map { mode in
                DeckLinkHelperDisplayMode(
                    name: mode.name,
                    modeID: Int64(mode.modeID),
                    width: mode.width,
                    height: mode.height,
                    frameDuration: mode.frameDuration,
                    timeScale: mode.timeScale,
                    progressive: mode.progressive,
                    supportsKeying: mode.supportsKeying)
            }
        reply((try? JSONEncoder().encode(modes)) ?? Data())
    }

    func startOutput(
        devicePersistentID: Int64,
        width: Int32,
        height: Int32,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        keying: Int32,
        modeID: Int64,
        reply: @escaping (String?, String) -> Void
    ) {
        stopOutput()
        guard DeckLinkRuntime.isAvailable else {
            reply("Desktop Video is not installed (blackmagicdesign.com/support)", "")
            return
        }
        if DeckLinkRuntime.runtimeIsTooOld {
            reply(
                "Desktop Video \(DeckLinkRuntime.apiVersionString ?? "?") is too old — "
                    + "install \(DeckLinkRuntime.requiredAPIMajor).0 or later", "")
            return
        }

        guard DeckLinkRuntime.devices()
            .contains(where: { $0.persistentID == devicePersistentID })
        else {
            reply(
                "DeckLink device not found (unplugged, or Desktop Video "
                    + "not installed)", "")
            return
        }
        let allModes = DeckLinkRuntime.displayModes(persistentID: devicePersistentID)
        let chosenModeID: UInt32
        var chosenViaAuto = false
        if modeID != 0 {
            chosenModeID = UInt32(truncatingIfNeeded: modeID)
        } else {
            guard !allModes.isEmpty else {

                reply(
                    "no playback modes — this connector may be mapped as an "
                        + "input in Desktop Video Setup", "")
                return
            }
            let modes = allModes.filter { keying == 0 || $0.supportsKeying }

            if let configured = DeckLinkRuntime.configuredOutputMode(
                    persistentID: devicePersistentID),
                let cardMode = modes.first(where: {
                    $0.modeID == configured
                        && $0.width == Int(width) && $0.height == Int(height)
                }) {
                chosenModeID = cardMode.modeID
            } else if frameRateDenominator != 0,
                let match = DeckLinkDisplayMode.bestMatch(
                    width: Int(width), height: Int(height),
                    framesPerSecond: Int(frameRateNumerator / frameRateDenominator),
                    in: modes) {
                chosenModeID = match.modeID
            } else {
                reply(
                    "no SDI mode matches \(width)×\(height) at "
                        + "\(frameRateNumerator)/\(frameRateDenominator) fps — "
                        + "choose a Format to send this screen scaled", "")
                return
            }
            chosenViaAuto = true
        }

        var detailParts: [String] = []
        if let name = allModes.first(where: { $0.modeID == chosenModeID })?.name {
            detailParts.append(chosenViaAuto ? "\(name) (Auto)" : name)
        }
        if keying == 2,
            !DeckLinkRuntime.referenceLocked(persistentID: devicePersistentID) {
            detailParts.append("no reference")
        }
        let wireDetail = detailParts.joined(separator: " · ")
        do {

            DeckLinkOutputStore.shared.evict(device: devicePersistentID)
            let output = try DeckLinkOutput(
                persistentID: devicePersistentID,
                modeID: chosenModeID,
                keying: DeckLinkKeying(rawValue: keying) ?? .off)
            device = devicePersistentID
            generation = DeckLinkOutputStore.shared.install(
                device: devicePersistentID, output: output)
            reply(nil, wireDetail)
        } catch DeckLinkError.openFailed(let message) {
            reply(message, "")
        } catch {
            reply("DeckLink output failed: \(error)", "")
        }
    }

    func sendFrame(_ surface: IOSurface, reply: @escaping (Bool, Data) -> Void) {
        guard let device, let generation,
            let output = DeckLinkOutputStore.shared.output(
                device: device, generation: generation)
        else {
            reply(false, Data())
            return
        }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let surfaceRef = unsafeBitCast(surface, to: IOSurfaceRef.self)
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surfaceRef, nil, &unmanaged) == kCVReturnSuccess,
            let pixelBuffer = unmanaged?.takeRetainedValue()
        else {
            reply(false, Self.encoded(output.timing))
            return
        }
        let delivered = output.display(pixelBuffer: pixelBuffer)
        reply(delivered, Self.encoded(output.timing))
    }

    private static func encoded(_ timing: DeckLinkOutputTiming) -> Data {
        let wire = DeckLinkCardTiming(
            completions: timing.completions,
            lastCompletionHostTime: timing.lastCompletionHostTime,
            repeats: timing.repeats, skips: timing.skips,
            late: timing.late, dropped: timing.dropped, jumps: timing.jumps)
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    func stopOutput() {
        if let device, let generation {
            DeckLinkOutputStore.shared.close(device: device, generation: generation)
        }
        device = nil
        generation = nil
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func startInput(devicePersistentID: Int64, reply: @escaping (String?) -> Void) {
        stopInput()
        if !DeckLinkRuntime.isAvailable {
            reply("Desktop Video is not installed (blackmagicdesign.com/support)")
        } else if DeckLinkRuntime.runtimeIsTooOld {
            reply(
                "Desktop Video \(DeckLinkRuntime.apiVersionString ?? "?") is too old — "
                    + "install \(DeckLinkRuntime.requiredAPIMajor).0 or later")
        } else if let sink = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? DeckLinkInputSinkProtocol {
            let maximum = DeckLinkRuntime.devices()
                .first { $0.persistentID == devicePersistentID }?.maxAudioChannels ?? 2
            do {
                input = try DeckLinkInputRelay(
                    persistentID: devicePersistentID,
                    audioChannels: DeckLinkInput.audioChannels(forMaximum: maximum), sink: sink)
                reply(nil)
            } catch DeckLinkError.openFailed(let message) {
                reply(message)
            } catch {
                reply("DeckLink input failed: \(error)")
            }
        } else {
            reply("helper connection unavailable")
        }
    }

    func stopInput() {

        let dropped = input
        input = nil
        if let dropped {
            DispatchQueue.global(qos: .utility).async { _ = dropped }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkInputSinkProtocol.self)
        let service = DeckLinkHelperService()
        service.connection = connection
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
