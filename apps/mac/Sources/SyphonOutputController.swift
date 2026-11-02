import Foundation
import Observation
import OutputEngine
import SyphonKit

@MainActor
@Observable
final class SyphonOutputController {
    enum Status: Equatable {
        case idle
        case publishing(serverName: String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    private let render: RenderContext
    private var mirror: OutputMirror?
    private var publisher: SyphonPublisher?

    init(render: RenderContext) {
        self.render = render
    }

    var isActive: Bool {
        if case .publishing = status { true } else { false }
    }

    func start(targetID: String, feed: NetworkCarryFeed) {
        stop()
        guard let publisher = SyphonPublisher(name: feed.name, device: render.compositor.device)
        else {
            status = .failed("Syphon server didn't start")
            return
        }

        guard let mirror = OutputMirror(
            compositor: render.compositor,
            width: feed.width, height: feed.height, framesPerSecond: feed.framesPerSecond,
            color: .srgb,
            provider: render.outputs.previewProvider(for: targetID),
            delayFrames: render.outputs.videoDelayProvider(for: targetID),
            adjustments: render.outputs.adjustmentsProvider(for: targetID),
            sourceRect: feed.sourceRect,
            placement: feed.placement,
            mask: render.outputs.maskProvider(for: targetID),
            sink: { pixelBuffer, _ in publisher.publish(pixelBuffer) }
        ) else {
            publisher.stop()
            status = .failed("couldn't make a \(feed.width)×\(feed.height) feed")
            return
        }
        self.publisher = publisher
        self.mirror = mirror
        mirror.start()
        status = .publishing(serverName: feed.name)
    }

    func stop() {
        mirror?.stop()
        mirror = nil
        publisher?.stop()
        publisher = nil
        status = .idle
    }
}
