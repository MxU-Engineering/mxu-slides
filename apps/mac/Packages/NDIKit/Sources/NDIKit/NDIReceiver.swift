import CNDI
import Foundation

public struct NDIVideoFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public let data: Data
}

public final class NDIReceiver: @unchecked Sendable {
    private let library: NDILibrary
    private let finder: NDIlib_find_instance_t
    private var receiver: NDIlib_recv_instance_t?

    public init?(library: NDILibrary) {
        self.library = library
        var settings = NDIlib_find_create_t()
        settings.show_local_sources = true
        guard let finder = library.table.find_create_v2?(&settings) else { return nil }
        self.finder = finder
        NDILibrary.retainInstance()
    }

    deinit {
        if let receiver {
            library.table.recv_destroy?(receiver)
        }
        library.table.find_destroy?(finder)
        NDILibrary.releaseInstance()
    }

    public func connect(toSourceContaining fragment: String, timeout: TimeInterval) -> String? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            _ = library.table.find_wait_for_sources?(finder, 500)
            var count: UInt32 = 0
            guard let sources = library.table.find_get_current_sources?(finder, &count) else {
                continue
            }
            for index in 0..<Int(count) {
                let source = sources[index]
                let name = source.p_ndi_name.map { String(cString: $0) } ?? ""
                guard name.contains(fragment) else { continue }
                var settings = NDIlib_recv_create_v3_t()
                settings.source_to_connect_to = source
                settings.color_format = NDIlib_recv_color_format_BGRX_BGRA
                settings.bandwidth = NDIlib_recv_bandwidth_highest
                guard let receiver = library.table.recv_create_v3?(&settings) else {
                    return nil
                }
                self.receiver = receiver
                return name
            }
        }
        return nil
    }

    public func captureVideoFrame(timeout: TimeInterval) -> NDIVideoFrame? {
        guard let receiver else { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            var video = NDIlib_video_frame_v2_t()
            let kind = library.table.recv_capture_v3?(receiver, &video, nil, nil, 1000)
            guard kind == NDIlib_frame_type_video else { continue }
            defer { library.table.recv_free_video_v2?(receiver, &video) }
            guard let pointer = video.p_data else { continue }
            let bytesPerRow = Int(video.line_stride_in_bytes)
            let height = Int(video.yres)
            return NDIVideoFrame(
                width: Int(video.xres),
                height: height,
                bytesPerRow: bytesPerRow,
                data: Data(bytes: pointer, count: bytesPerRow * height))
        }
        return nil
    }
}
