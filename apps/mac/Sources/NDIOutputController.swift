import CoreVideo
import Foundation
import IOSurface
import Observation
import OutputEngine
import RenderEngine

@MainActor
@Observable
final class NDIOutputController {
    enum Status: Equatable {
        case idle
        case starting
        case sending(sourceName: String)
        case failed(String)

        case interrupted(sourceName: String)
    }

    private(set) var status: Status = .idle
    private(set) var targetID = ""
    private(set) var targetName = ""

    private var sourceRect: CGRect?

    private var placement: CGRect?

    private let render: RenderContext
    private var mirror: OutputMirror?
    private var connection: NSXPCConnection?

    private var connectionGeneration = 0

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
        targetID: String, targetName: String, sourceName: String,
        width: Int, height: Int, frameRate: Int,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil
    ) {
        stop()
        self.targetID = targetID
        self.targetName = targetName
        self.sourceRect = sourceRect
        self.placement = placement
        status = .starting

        connectionGeneration += 1
        let generation = connectionGeneration
        let connection = NSXPCConnection(serviceName: NDIHelperIdentity.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: NDIHelperProtocol.self)

        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation
                else { return }
                guard case .sending(let name) = self.status else { return }

                self.status = .interrupted(sourceName: name)
                self.restartSender(named: name, frameRate: frameRate)
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation
                else { return }

                DiagnosticsStore.shared.note(
                    "ndi.helper",
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
                    "ndi.helper", detail: "proxy error: \(error)")
                guard self.isActive else { return }
                self.status = .failed(error.localizedDescription)
                self.stopMirror()
            }
        }
        guard let proxy = remoteObject as? NDIHelperProtocol else {
            status = .failed("helper connection unavailable")
            return
        }
        proxy.startSender(
            name: sourceName,
            frameRateNumerator: Int32(frameRate * 1000),
            frameRateDenominator: 1000
        ) { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.status = .failed(error)
                    self.stopMirror()
                    return
                }
                self.status = .sending(sourceName: sourceName)
            }
        }

        let provider = render.outputs.previewProvider(for: targetID)

        nonisolated(unsafe) let remote = proxy
        let inFlight = Locked(0)
        mirror = OutputMirror(
            compositor: render.compositor,
            width: width, height: height, framesPerSecond: frameRate,
            provider: provider,
            delayFrames: render.outputs.videoDelayProvider(for: targetID),

            adjustments: render.outputs.adjustmentsProvider(for: targetID),
            sourceRect: sourceRect,
            placement: placement,
            mask: render.outputs.maskProvider(for: targetID),
            sink: { pixelBuffer, _ in
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
                remote.sendFrame(surface) {
                    inFlight.withLock { $0 -= 1 }
                }
            }
        )
        mirror?.start()
    }

    private func restartSender(named sourceName: String, frameRate: Int) {
        guard let proxy = connection?.remoteObjectProxy as? NDIHelperProtocol else { return }
        proxy.startSender(
            name: sourceName,
            frameRateNumerator: Int32(frameRate * 1000),
            frameRateDenominator: 1000
        ) { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.status = error.map { .failed($0) } ?? .sending(sourceName: sourceName)
            }
        }
    }

    func reloadNetworkPin() {
        guard isActive,
              let proxy = connection?.remoteObjectProxy as? NDIHelperProtocol
        else { return }
        proxy.reloadNetworkPin { @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, let error, self.isActive else { return }
                DiagnosticsStore.shared.note("ndi.helper", detail: "pin reload: \(error)")
                self.status = .failed(error)
                self.stopMirror()
            }
        }
    }

    func stop() {
        stopMirror()
        if let proxy = connection?.remoteObjectProxy as? NDIHelperProtocol {
            proxy.stopSender()
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
