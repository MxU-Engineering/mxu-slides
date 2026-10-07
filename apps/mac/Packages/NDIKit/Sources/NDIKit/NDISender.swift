import CNDI
import CoreVideo
import Foundation

public final class NDISender: @unchecked Sendable {
    private let library: NDILibrary
    private let instance: NDIlib_send_instance_t
    private let lock = NSLock()
    private var framesSent = 0

    public var sent: Int {
        lock.withLock { framesSent }
    }

    public init?(library: NDILibrary, name: String) {
        self.library = library
        let cName = strdup(name)
        defer { free(cName) }
        var settings = NDIlib_send_create_t()
        settings.p_ndi_name = UnsafePointer(cName)

        settings.clock_video = false
        settings.clock_audio = false
        guard let instance = library.table.send_create?(&settings) else { return nil }
        self.instance = instance
        NDILibrary.retainInstance()
    }

    deinit {
        library.table.send_destroy?(instance)
        NDILibrary.releaseInstance()
    }

    public func send(
        pixelBuffer: CVPixelBuffer,
        frameRateNumerator: Int32 = 30_000,
        frameRateDenominator: Int32 = 1_000
    ) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(CVPixelBufferGetWidth(pixelBuffer))
        frame.yres = Int32(CVPixelBufferGetHeight(pixelBuffer))
        frame.FourCC = NDIlib_FourCC_video_type_BGRA
        frame.frame_rate_N = frameRateNumerator
        frame.frame_rate_D = frameRateDenominator
        frame.frame_format_type = NDIlib_frame_format_type_progressive
        frame.timecode = Int64.max  
        frame.p_data = base.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))

        lock.withLock {
            library.table.send_send_video_v2?(instance, &frame)
            framesSent += 1
        }
    }
}
