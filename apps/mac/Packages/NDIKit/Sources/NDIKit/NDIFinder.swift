import CNDI
import Foundation

public final class NDIFinder: @unchecked Sendable {
    private let library: NDILibrary
    private let finder: NDIlib_find_instance_t

    public init?(library: NDILibrary) {
        self.library = library
        var settings = NDIlib_find_create_t()
        settings.show_local_sources = true
        guard let finder = library.table.find_create_v2?(&settings) else { return nil }
        self.finder = finder
        NDILibrary.retainInstance()
    }

    deinit {
        library.table.find_destroy?(finder)
        NDILibrary.releaseInstance()
    }

    public func currentSourceNames(wait milliseconds: UInt32 = 1500) -> [String] {
        _ = library.table.find_wait_for_sources?(finder, milliseconds)
        var count: UInt32 = 0
        guard let sources = library.table.find_get_current_sources?(finder, &count) else {
            return []
        }
        return (0..<Int(count)).compactMap { index in
            sources[index].p_ndi_name.map { String(cString: $0) }
        }
    }
}
