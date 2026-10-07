import CoreMedia
import Foundation
import os

struct VendoredTSLogger {
    private let log = Logger(subsystem: "com.example.mxuslides", category: "hls-ts")
    func error(_ message: String) {
        log.error("\(message, privacy: .public)")
    }
}

let logger = VendoredTSLogger()

extension CMSampleBuffer {
    @inlinable @inline(__always) var isNotSync: Bool {
        guard !sampleAttachments.isEmpty else { return false }
        return sampleAttachments[0][.notSync] != nil
    }
}
