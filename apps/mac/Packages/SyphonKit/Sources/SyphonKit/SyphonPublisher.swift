import CoreVideo
import Foundation
import Metal
import Syphon

public final class SyphonPublisher: @unchecked Sendable {
    public let name: String

    private let lock = NSLock()
    private var server: SyphonMetalServer?
    private var published = 0
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache

    public init?(name: String, device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard let queue = device.makeCommandQueue(),
              CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess,
              let cache,
              let server = SyphonMetalServer(name: name, device: device, options: nil) as SyphonMetalServer?
        else { return nil }
        queue.label = "syphon.publish"
        self.name = name
        self.queue = queue
        self.textureCache = cache
        self.server = server
    }

    deinit { stop() }

    public var hasClients: Bool {
        lock.withLock { server?.hasClients ?? false }
    }

    public var serverDescription: [String: Any] {
        lock.withLock { server?.serverDescription ?? [:] }
    }

    public var framesPublished: Int {
        lock.withLock { published }
    }

    @discardableResult
    public func publish(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return lock.withLock { () -> Bool in
            guard let server, server.hasClients else { return false }
            var cvTexture: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                    .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
                  let cvTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture),
                  let commandBuffer = queue.makeCommandBuffer()
            else { return false }
            commandBuffer.label = "syphon.publish \(name)"

            server.publishFrameTexture(
                texture, on: commandBuffer,
                imageRegion: NSRect(x: 0, y: 0, width: width, height: height),
                flipped: true)
            nonisolated(unsafe) let held = (cvTexture, pixelBuffer)
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(held) {} }
            commandBuffer.commit()
            published += 1
            return true
        }
    }

    public func stop() {
        let retired = lock.withLock { () -> SyphonMetalServer? in
            defer { server = nil }
            return server
        }
        retired?.stop()
    }
}
