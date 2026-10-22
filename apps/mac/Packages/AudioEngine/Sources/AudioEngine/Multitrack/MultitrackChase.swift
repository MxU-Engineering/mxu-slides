import Foundation

struct MultitrackChase {
    enum Decision: Equatable {
        case hold

        case land

        case slips(Int)
    }

    static let deadband = 0.002

    static let land = 0.15

    static let smoothing = 1.0

    static let correctOver = 4.0

    static let maxSlipsPerSecond = 40.0

    private var error: Double?
    private var lastTime: Double?
    private var carry = 0.0

    mutating func reset() {
        error = nil
        lastTime = nil
        carry = 0
    }

    mutating func step(error raw: Double, at time: Double, sampleRate: Double) -> Decision {
        if abs(raw) > Self.land {
            reset()
            return .land
        }
        let dt = lastTime.map { min(max(time - $0, 0), 1) } ?? 0
        lastTime = time
        let smoothed = error.map { $0 + (raw - $0) * dt / (Self.smoothing + dt) } ?? raw
        error = smoothed
        guard abs(smoothed) > Self.deadband else {
            carry = 0
            return .hold
        }

        let rate = min(max(-smoothed * sampleRate / Self.correctOver, -Self.maxSlipsPerSecond), Self.maxSlipsPerSecond)
        carry += rate * dt
        let count = Int(carry.rounded(.towardZero))
        carry -= Double(count)
        return count == 0 ? .hold : .slips(count)
    }
}
