import CoreVideo
import Foundation
import IOSurface
import Observation
import OutputEngine
import RenderEngine

@MainActor
@Observable
final class DeckLinkOutputController {
    enum Status: Equatable {
        case idle
        case starting
        case sending(deviceName: String)
        case failed(String)

        case interrupted(deviceName: String)
    }

    private(set) var status: Status = .idle
    private(set) var targetID = ""
    private(set) var targetName = ""

    private var sourceRect: CGRect?

    private var placement: CGRect?

    private var composite: [OutputMirror.CompositeLayer] = []

    private(set) var wireDetail = ""

    private let render: RenderContext
    private var mirror: OutputMirror?
    private var connection: NSXPCConnection?

    private var connectionGeneration = 0

    private struct OpenParameters {
        var devicePersistentID: Int64
        var deviceName: String
        var keying: DeckLinkAlphaKey
        var width: Int
        var height: Int
        var frameRate: Int
        var modeID: Int64
    }

    private var openParameters: OpenParameters?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    private var openAttempt: UUID?
    private var openTimeoutTask: Task<Void, Never>?

    private var inReconnectEpisode = false
    private var lastReconnectError: String?

    private var phantomCycles = 0

    private var awaitingDeliveryConfirm = Locked(false)

    private let lastDeliveredAt = Locked<TimeInterval>(0)

    init(render: RenderContext) {
        self.render = render
    }

    var isActive: Bool {
        switch status {
        case .starting, .sending, .interrupted: true
        case .idle, .failed: false
        }
    }

    func start(
        targetID: String, targetName: String,
        devicePersistentID: Int64, deviceName: String, keying: DeckLinkAlphaKey,
        width: Int, height: Int, frameRate: Int, modeID: Int64 = 0,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        composite: [OutputMirror.CompositeLayer] = []
    ) {
        stop()
        self.targetID = targetID
        self.targetName = targetName
        self.sourceRect = sourceRect
        self.placement = placement
        self.composite = composite

        status = inReconnectEpisode
            ? .interrupted(deviceName: deviceName) : .starting
        awaitingDeliveryConfirm = Locked(false)
        openParameters = OpenParameters(
            devicePersistentID: devicePersistentID, deviceName: deviceName,
            keying: keying, width: width, height: height,
            frameRate: frameRate, modeID: modeID)

        connectionGeneration += 1
        let generation = connectionGeneration
        let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)

        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation
                else { return }
                guard case .sending(let name) = self.status else { return }

                self.status = .interrupted(deviceName: name)
                self.restartOutput(
                    devicePersistentID: devicePersistentID, deviceName: deviceName,
                    keying: keying, width: width, height: height,
                    frameRate: frameRate, modeID: modeID)
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation
                else { return }

                DiagnosticsStore.shared.note(
                    "decklink.helper",
                    detail: "connection invalidated — service unreachable")
                guard self.isActive else { return }
                self.status = .failed("helper unreachable (connection invalidated)")
                self.stopMirror()
            }
        }
        connection.resume()
        self.connection = connection

        let remoteObject = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation
                else { return }
                DiagnosticsStore.shared.note(
                    "decklink.helper", detail: "proxy error: \(error)")
                guard self.isActive else { return }
                self.status = .failed(error.localizedDescription)
                self.stopMirror()
            }
        }
        guard let proxy = remoteObject as? DeckLinkHelperProtocol else {
            status = .failed("helper connection unavailable")
            return
        }
        proxy.startOutput(
            devicePersistentID: devicePersistentID,
            width: Int32(width), height: Int32(height),
            frameRateNumerator: Int32(frameRate * 1000),
            frameRateDenominator: 1000,
            keying: keying.rawValue,
            modeID: modeID
        ) { @Sendable [weak self] error, wireDetail in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.openAttempt = nil
                self.openTimeoutTask?.cancel()
                self.openTimeoutTask = nil
                self.wireDetail = wireDetail

                let line = error.map { "\(deviceName): \($0)" }
                    ?? "\(deviceName): sending \(wireDetail)"
                if !self.inReconnectEpisode || error != self.lastReconnectError {
                    DiagnosticsStore.shared.note("decklink.start", detail: line)
                }
                if let error {
                    self.lastReconnectError = error

                    if self.inReconnectEpisode || Self.isTransientOpenFailure(error) {
                        self.beginReconnect()
                    } else {
                        self.status = .failed(error)
                        self.stopMirror()
                    }
                    return
                }
                if self.inReconnectEpisode {

                    self.awaitingDeliveryConfirm.withLock { $0 = true }
                } else {
                    self.status = .sending(deviceName: deviceName)
                }
            }
        }

        let provider = render.outputs.previewProvider(for: targetID)

        nonisolated(unsafe) let remote = proxy
        let inFlight = Locked(0)
        let refusals = Locked(0)

        let firstOutcomeLogged = Locked(inReconnectEpisode)
        let alphaProbed = Locked(false)

        let rampSampleFrame = Locked(0)
        let refusalThreshold = frameRate
        let notifyDeviceStopped: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.deviceStoppedTakingFrames() }
        }
        let deliveredStamp = lastDeliveredAt
        let confirmBox = awaitingDeliveryConfirm
        let markDelivered: @Sendable () -> Void = { [weak self] in
            deliveredStamp.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            let confirms = confirmBox.withLock { pending -> Bool in
                defer { pending = false }
                return pending
            }
            guard confirms else { return }
            Task { @MainActor in self?.reconnectConfirmed() }
        }
        mirror = OutputMirror(
            compositor: render.compositor,
            width: width, height: height, framesPerSecond: frameRate,

            transparentBackground: keying != .off,
            provider: provider,
            delayFrames: render.outputs.videoDelayProvider(for: targetID),

            adjustments: render.outputs.adjustmentsProvider(for: targetID),
            sourceRect: sourceRect,
            placement: placement,
            mask: render.outputs.maskProvider(for: targetID),
            composite: composite,
            sink: { pixelBuffer, _ in

                let probeNow = alphaProbed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                let sampleIndex = rampSampleFrame.withLock { frame -> Int? in
                    frame += 1
                    switch frame {
                    case 1: return 0
                    case 150: return 1
                    case 300: return 2
                    default: return nil
                    }
                }
                if probeNow || sampleIndex != nil {
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                        let midX = CVPixelBufferGetWidth(pixelBuffer) / 2
                        let midY = CVPixelBufferGetHeight(pixelBuffer) / 2
                        let pixels = base.assumingMemoryBound(to: UInt8.self)
                        let corner = pixels[3]
                        let center = midY * bytesPerRow + midX * 4
                        DiagnosticsStore.shared.note(
                            "decklink.alpha",
                            detail: "\(deviceName) t\(sampleIndex.map { $0 * 5 } ?? 0)s "
                                + "corner α=\(corner) center "
                                + "B=\(pixels[center]) G=\(pixels[center + 1]) "
                                + "R=\(pixels[center + 2]) α=\(pixels[center + 3])")
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                }
                guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?
                    .takeUnretainedValue()
                else { return }
                let claimed = inFlight.withLock { count -> Bool in
                    guard count < 2 else { return false }
                    count += 1
                    return true
                }
                guard claimed else { return }
                let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
                remote.sendFrame(surface) { @Sendable delivered in
                    inFlight.withLock { $0 -= 1 }

                    let firstOutcome = firstOutcomeLogged.withLock { logged -> Bool in
                        defer { logged = true }
                        return !logged
                    }
                    if firstOutcome {
                        DiagnosticsStore.shared.note(
                            "decklink.frames",
                            detail: "first frame \(delivered ? "delivered" : "REFUSED")")
                    }
                    let streakHit = refusals.withLock { streak -> Bool in
                        guard !delivered else {
                            streak = 0
                            return false
                        }
                        streak += 1
                        return streak == refusalThreshold
                    }
                    if delivered { markDelivered() }
                    guard streakHit else { return }
                    notifyDeviceStopped()
                }
            }
        )
        if mirror == nil {

            DiagnosticsStore.shared.note(
                "decklink.frames", detail: "\(deviceName): mirror init FAILED")
        }
        mirror?.start()
        startWatchdog()
        let attempt = UUID()
        openAttempt = attempt
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.openAttempt == attempt,
                self.isActive
            else { return }
            DiagnosticsStore.shared.note(
                "decklink.reconnect",
                detail: "\(deviceName): open never answered — helper wedged; "
                    + "killing it and retrying")
            self.openAttempt = nil
            self.killWedgedHelper()
            self.beginReconnect()
        }
    }

    private func reconnectConfirmed() {
        guard inReconnectEpisode, let parameters = openParameters else { return }
        inReconnectEpisode = false
        lastReconnectError = nil
        phantomCycles = 0
        status = .sending(deviceName: parameters.deviceName)
        DiagnosticsStore.shared.note(
            "decklink.start", detail: "\(parameters.deviceName): sending (reconnected)")
    }

    private func killWedgedHelper() {
        guard let pid = connection?.processIdentifier, pid > 0 else { return }
        DiagnosticsStore.shared.note(
            "decklink.reconnect",
            detail: "helper \(pid) wedged (opens succeed, frames never land) — killing it")
        kill(pid, SIGKILL)
        phantomCycles = 0
    }

    private static func isTransientOpenFailure(_ error: String) -> Bool {
        error.hasPrefix("DeckLink device not found")
            || error.contains("claimed by another app")
    }

    private func deviceStoppedTakingFrames() {
        guard case .sending = status else { return }
        DiagnosticsStore.shared.note(
            "decklink.reconnect",
            detail: "\(openParameters?.deviceName ?? "?"): frames refused — reconnecting")
        beginReconnect()
    }

    private func beginReconnect() {
        guard let parameters = openParameters else { return }
        inReconnectEpisode = true
        status = .interrupted(deviceName: parameters.deviceName)
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let controller = self, !Task.isCancelled, controller.isActive
            else { return }
            controller.restartFromScratch()
        }
    }

    private func restartFromScratch() {
        guard let parameters = openParameters else { return }
        let target = (id: targetID, name: targetName)
        start(
            targetID: target.id, targetName: target.name,
            devicePersistentID: parameters.devicePersistentID,
            deviceName: parameters.deviceName,
            keying: parameters.keying,
            width: parameters.width, height: parameters.height,
            frameRate: parameters.frameRate,
            modeID: parameters.modeID)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        lastDeliveredAt.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let controller = self, !Task.isCancelled else { return }

                let confirming = controller.awaitingDeliveryConfirm.withLock { $0 }
                let sending: Bool = {
                    if case .sending = controller.status { return true }
                    return false
                }()
                guard sending || confirming else { continue }
                let last = controller.lastDeliveredAt.withLock { $0 }
                guard ProcessInfo.processInfo.systemUptime - last > 3 else { continue }
                if !controller.inReconnectEpisode {
                    DiagnosticsStore.shared.note(
                        "decklink.reconnect",
                        detail: "\(controller.openParameters?.deviceName ?? "?"): "
                            + "no delivered frames for 3s — restarting connection")
                }

                controller.inReconnectEpisode = true
                controller.phantomCycles += 1
                if controller.phantomCycles >= 2 {
                    controller.killWedgedHelper()
                }
                controller.restartFromScratch()
                return
            }
        }
    }

    private func restartOutput(
        devicePersistentID: Int64, deviceName: String, keying: DeckLinkAlphaKey,
        width: Int, height: Int, frameRate: Int, modeID: Int64
    ) {
        guard let proxy = connection?.remoteObjectProxy as? DeckLinkHelperProtocol
        else { return }
        proxy.startOutput(
            devicePersistentID: devicePersistentID,
            width: Int32(width), height: Int32(height),
            frameRateNumerator: Int32(frameRate * 1000),
            frameRateDenominator: 1000,
            keying: keying.rawValue,
            modeID: modeID
        ) { @Sendable [weak self] error, wireDetail in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                guard let error else {
                    self.wireDetail = wireDetail
                    self.status = .sending(deviceName: deviceName)
                    return
                }

                if Self.isTransientOpenFailure(error) {
                    self.beginReconnect()
                } else {
                    self.status = .failed(error)
                }
            }
        }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openAttempt = nil
        openParameters = nil
        stopMirror()
        if let proxy = connection?.remoteObjectProxy as? DeckLinkHelperProtocol {
            proxy.stopOutput()
        }
        connection?.invalidate()
        connection = nil
        status = .idle
    }

    private func stopMirror() {
        mirror?.stop()
        mirror = nil
    }
}
