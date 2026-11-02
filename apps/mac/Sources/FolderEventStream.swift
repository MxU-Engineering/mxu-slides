import CoreServices
import Foundation

@MainActor
final class FolderEventStream {
    let folder: URL
    private let onChange: @MainActor () -> Void
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    init?(folder: URL, onChange: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }

            MainActor.assumeIsolated {
                Unmanaged<FolderEventStream>.fromOpaque(info).takeUnretainedValue().onChange()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
