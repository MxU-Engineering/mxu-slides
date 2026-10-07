import Foundation
import RenderEngine

struct ArrivalWindow: Sendable {
    static let capacity = 120

    static let minimumCount = 30

    static let gap = 0.5

    private var times: [CFTimeInterval] = []

    mutating func record(_ now: CFTimeInterval) {
        if let last = times.last, now - last > Self.gap { times.removeAll() }
        times.append(now)
        if times.count > Self.capacity { times.removeFirst(times.count - Self.capacity) }
    }

    var cadence: LiveCadence? {
        if let first = times.first, let last = times.last, times.count >= Self.minimumCount {
            LiveCadence(lastArrival: last, period: (last - first) / Double(times.count - 1))
        } else {
            nil
        }
    }
}
