import CoreGraphics
import Foundation
import MediaEngine
import Observation
import RenderEngine

@MainActor
@Observable
final class MediaSoak {
    enum Phase: Equatable {
        case idle
        case generating(String)
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var alphaStats = PlaybackStats()
    private(set) var opaqueStats = PlaybackStats()

    static let alphaLoopID = "soak.prores4444alpha.4k"
    static let opaqueLoopID = "soak.hevc.1080p60"

    var isRunning: Bool { phase == .running }

    private var samplingTask: Task<Void, Never>?

    func start(render: RenderContext) async {
        guard phase != .running, !isGenerating else { return }
        do {
            let alphaURL = try await generateContentIfNeeded(
                name: "soak-prores4444alpha-4k.mov",
                label: "4K ProRes 4444 alpha loop (~0.8 GB, one-time)"
            ) { url in
                try await MediaAuthoring.writeMovie(
                    to: url, codec: .proRes4444Alpha,
                    size: CGSize(width: 3840, height: 2160),
                    frameCount: 240, framesPerSecond: 30,
                    draw: Self.drawAlphaLoopFrame
                )
            }
            let opaqueURL = try await generateContentIfNeeded(
                name: "soak-hevc-1080p60.mov",
                label: "1080p60 HEVC loop"
            ) { url in
                try await MediaAuthoring.writeMovie(
                    to: url, codec: .hevc,
                    size: CGSize(width: 1920, height: 1080),
                    frameCount: 360, framesPerSecond: 60,
                    draw: Self.drawOpaqueLoopFrame
                )
            }

            phase = .generating("Preparing playback…")
            let alpha = try await render.media.prepare(url: alphaURL)
            let opaque = try await render.media.prepare(url: opaqueURL)

            render.media.play(opaque, id: Self.opaqueLoopID, loop: true)
            await render.media.preroll(alpha, id: Self.alphaLoopID, loop: true)
            render.media.start(id: Self.alphaLoopID)

            render.scene = Self.soakScene()
            startedAt = .now
            phase = .running
            startSampling(render: render)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func stop(render: RenderContext) {
        samplingTask?.cancel()
        samplingTask = nil
        render.media.stopAll()
        render.scene = .sampleLyricScene()
        startedAt = nil
        phase = .idle
    }

    private var isGenerating: Bool {
        if case .generating = phase { true } else { false }
    }

    private func startSampling(render: RenderContext) {
        samplingTask?.cancel()
        samplingTask = Task { [weak self, weak render] in
            while !Task.isCancelled {
                guard let self, let render else { return }
                alphaStats = render.media.stats(for: Self.alphaLoopID) ?? PlaybackStats()
                opaqueStats = render.media.stats(for: Self.opaqueLoopID) ?? PlaybackStats()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func generateContentIfNeeded(
        name: String,
        label: String,
        write: (URL) async throws -> Void
    ) async throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("MxU Slides/Demo Media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            phase = .generating(label)
            try await write(url)
        }
        return url
    }

    private static func soakScene() -> RenderScene {
        var scene = RenderScene.sampleLyricScene()

        scene.layers = scene.layers.map { layer in
            var layer = layer
            if layer.kind == .stillGraphics { layer.items.removeAll() }
            return layer
        }
        scene.addItem(
            RenderItem(
                id: Self.opaqueLoopID,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                content: .media(id: Self.opaqueLoopID)
            ),
            to: .loopingVideos
        )
        scene.addItem(
            RenderItem(
                id: Self.alphaLoopID,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                content: .media(id: Self.alphaLoopID)
            ),
            to: .videos
        )
        return scene
    }

    @Sendable nonisolated private static func drawAlphaLoopFrame(_ context: CGContext, frame: Int) {
        let size = CGSize(width: 3840, height: 2160)
        let t = Double(frame) / 240.0 * 2 * .pi

        for disc in 0..<5 {
            let phase = t + Double(disc) * 2 * .pi / 5
            let radius = 420.0 + 120.0 * sin(phase * 3)
            let x = size.width / 2 + CGFloat(cos(phase)) * 1200
            let y = size.height / 2 + CGFloat(sin(phase * 2)) * 700
            let hue = Double(disc) / 5
            context.setFillColor(CGColor(
                srgbRed: 0.5 + 0.5 * cos(hue * 2 * .pi),
                green: 0.5 + 0.5 * cos((hue + 0.33) * 2 * .pi),
                blue: 0.5 + 0.5 * cos((hue + 0.67) * 2 * .pi),
                alpha: 0.45
            ))
            context.fillEllipse(in: CGRect(
                x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
            ))
        }

        let barX = CGFloat(Double(frame) / 240.0) * size.width
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
        for wrap in [CGFloat(0), -size.width] {
            context.fill(CGRect(x: barX - 120 + wrap, y: 0, width: 240, height: size.height))
        }
    }

    @Sendable nonisolated private static func drawOpaqueLoopFrame(_ context: CGContext, frame: Int) {
        let size = CGSize(width: 1920, height: 1080)
        let strips = 36
        let stripHeight = size.height / CGFloat(strips)
        for strip in 0..<strips {
            let phase = 2 * Double.pi * (Double(strip) / Double(strips) * 3 - Double(frame) / 360.0)
            let v = 0.5 + 0.5 * sin(phase)
            context.setFillColor(CGColor(
                srgbRed: 0.05 + 0.25 * v, green: 0.10 + 0.35 * v, blue: 0.25 + 0.55 * v, alpha: 1
            ))
            context.fill(CGRect(
                x: 0, y: CGFloat(strip) * stripHeight, width: size.width, height: stripHeight + 1
            ))
        }
    }
}
