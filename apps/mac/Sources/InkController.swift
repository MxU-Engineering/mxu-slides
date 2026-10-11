import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import LocalAPI
import Observation
import QuartzCore
import RenderEngine
import UniformTypeIdentifiers

@MainActor
@Observable
final class InkController {
    static let enabledKey = "ink.enabled"
    static let portKey = "ink.port"
    static let pinKey = "ink.pin"
    static let defaultPort: UInt16 = 6981
    static let sourceID = "ink::program"
    private static let itemID = "ink-program"
    private static let maxRasterWidth = 1920
    private static let previewWidth = 960

    private(set) var running = false
    private(set) var lastError: String?
    private(set) var viewerCount = 0

    private(set) var isVisible = false

    @ObservationIgnored var onVisibilityChange: (() -> Void)?

    @ObservationIgnored private let render: RenderContext
    @ObservationIgnored private let rasterizer = InkRasterizer(width: 1920, height: 1080)
    @ObservationIgnored private var server: InkRelayServer?
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var canvas = CGSize(width: 1920, height: 1080)
    @ObservationIgnored private var lastScene: RenderScene?
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(render: RenderContext) {
        self.render = render
        let rasterizer = rasterizer
        render.media.registerLiveSource(
            id: Self.sourceID,
            latestFrame: { rasterizer.frame() },
            onStop: {})
        if enabled { start() }
    }

    var enabled: Bool {
        get {
            access(keyPath: \.running)
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024 ... 65535).contains(stored) ? UInt16(stored) : Self.defaultPort
    }

    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort >= 1024 else { return }
        UserDefaults.standard.set(Int(newPort), forKey: Self.portKey)
        if running { restart() }
    }

    var pin: String {
        access(keyPath: \.running)
        if let stored = UserDefaults.standard.string(forKey: Self.pinKey),
           stored.count >= 4, stored.allSatisfy(\.isNumber) {
            return stored
        }
        let fresh = Self.randomPIN()
        UserDefaults.standard.set(fresh, forKey: Self.pinKey)
        return fresh
    }

    func regeneratePIN() {
        let fresh = Self.randomPIN()
        UserDefaults.standard.set(fresh, forKey: Self.pinKey)
        server?.setPIN(fresh)
        viewerCount = 0
        withMutation(keyPath: \.running) {}
    }

    private static func randomPIN() -> String {
        String(format: "%04d", Int.random(in: 0 ... 9999))
    }

    var address: String? {
        NetworkInfo.lanIPv4().map { "http://\($0):\(port)" }
    }

    var qrImage: NSImage? {
        guard let address else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func start() {
        guard serverTask == nil else { return }
        lastError = nil
        generation += 1
        let server = InkRelayServer(port: port, pin: pin)
        let rasterizer = rasterizer
        server.onChange = { [weak self] board in
            rasterizer.update(board)
            Task { @MainActor in self?.boardChanged(board) }
        }
        server.onViewerCountChange = { [weak self] count in
            Task { @MainActor in self?.viewersChanged(count) }
        }
        self.server = server
        running = true
        syncCanvas()
        let started = generation
        serverTask = Task { [weak self] in
            do {
                try await server.run()
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == started else { return }
                    self.lastError = "\(error)"
                    self.running = false
                    self.serverTask = nil
                    self.server = nil
                }
            }
        }
        DiagnosticsStore.shared.note("ink.start", detail: "port \(port)")
    }

    func stop() {
        generation += 1
        previewTask?.cancel()
        previewTask = nil
        let server = server
        self.server = nil
        serverTask?.cancel()
        serverTask = nil
        running = false
        viewerCount = 0
        Task { await server?.stop() }
        rasterizer.update(InkBoard())
        setVisible(false)
        DiagnosticsStore.shared.note("ink.stop")
    }

    private func restart() {
        stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.start()
        }
    }

    func clear() { server?.clear() }
    func hide() { server?.setHidden(true) }
    func show() { server?.setHidden(false) }

    func overlay(on scene: inout RenderScene) {
        guard isVisible else { return }
        scene.addItem(
            RenderItem(
                id: Self.itemID,
                frame: CGRect(origin: .zero, size: scene.canvasSize),
                content: .media(id: Self.sourceID, scaleMode: .fill)
            ),
            to: .alerts
        )
    }

    func programDidChange(_ scene: RenderScene) {
        guard running else { return }
        if scene.canvasSize != canvas {
            canvas = scene.canvasSize
            syncCanvas()
        }
        lastScene = scene
        let key = scene.layers
            .flatMap { $0.items.map(\.id) }
            .joined(separator: "|")
        guard key != lastKey else { return }
        lastKey = key
        schedulePreview()
    }

    private func syncCanvas() {
        let width = min(Self.maxRasterWidth, max(16, Int(canvas.width)))
        let height = max(16, Int((Double(width) * canvas.height / max(canvas.width, 1)).rounded()))
        rasterizer.setSize(width: width, height: height)
        server?.setView(width: Double(canvas.width), height: Double(canvas.height))
        if let board = server?.snapshot { rasterizer.update(board) }
    }

    private func boardChanged(_ board: InkBoard) {
        guard server != nil else { return }
        setVisible(board.isVisible)
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        onVisibilityChange?()
    }

    private func viewersChanged(_ count: Int) {
        guard server != nil else { return }
        let grew = count > viewerCount
        viewerCount = count
        if grew { schedulePreview(after: .milliseconds(50)) }
    }

    private func schedulePreview(after delay: Duration = .milliseconds(350)) {
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pushPreview()
        }
    }

    private func pushPreview() {
        guard let server, server.viewerCount > 0, let scene = lastScene else { return }
        let compositor = render.compositor
        let width = Self.previewWidth
        let height = max(16, Int((Double(width) * scene.canvasSize.height / max(scene.canvasSize.width, 1)).rounded()))
        Task.detached(priority: .utility) {
            guard let frame = try? compositor.renderFrame(
                scene: scene, width: width, height: height, at: CACurrentMediaTime()),
                  let image = frame.cgImage,
                  let jpeg = Self.jpeg(image)
            else { return }
            server.sendFrame(jpeg: jpeg)
        }
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
