import CoreVideo
import Foundation
import MediaEngine
import OutputEngine
import RenderEngine

@MainActor
final class ScreenMirrorService {
    static let shared = ScreenMirrorService()
    static let prefix = "screen::"

    private var mirrors: [String: OutputMirror] = [:]

    func start(id: String, render: RenderContext) {
        guard mirrors[id] == nil else { return }
        let target = String(id.dropFirst(Self.prefix.count))
        guard let (width, height, fps) = Self.dimensions(for: target, outputs: render.outputs)
        else {
            DiagnosticsStore.shared.note("screenMirror.unknown", detail: target)
            return
        }
        let latest = Locked<CVPixelBuffer?>(nil)
        guard let mirror = OutputMirror(
            compositor: render.compositor,
            width: width, height: height, framesPerSecond: fps,
            provider: render.outputs.previewProvider(for: target),
            sink: { buffer, _ in latest.value = buffer }
        ) else {
            DiagnosticsStore.shared.note("screenMirror.failed", detail: target)
            return
        }
        mirrors[id] = mirror
        render.media.registerLiveSource(
            id: id,
            latestFrame: { latest.value },
            onStop: { [weak self] in
                Task { @MainActor in self?.stopped(id: id) }
            }
        )
        mirror.start()
        DiagnosticsStore.shared.note(
            "screenMirror.start", detail: "\(target) \(width)x\(height)")
    }

    private func stopped(id: String) {
        guard let mirror = mirrors.removeValue(forKey: id) else { return }
        mirror.stop()
        DiagnosticsStore.shared.note("screenMirror.stop", detail: id)
    }

    private static func dimensions(
        for target: String, outputs: OutputManager
    ) -> (width: Int, height: Int, fps: Int)? {
        if let uuid = UUID(uuidString: target),
           let placeholder = outputs.placeholderScreens.first(where: { $0.id == uuid }) {
            return (placeholder.width, placeholder.height, min(placeholder.framesPerSecond, 30))
        }
        if let display = outputs.displays.first(where: { $0.uuid == target }) {
            return (
                Int(display.frame.width), Int(display.frame.height),
                min(display.maximumFramesPerSecond, 30)
            )
        }
        return nil
    }
}
