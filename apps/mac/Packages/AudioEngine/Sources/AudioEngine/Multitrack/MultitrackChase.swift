import Foundation

struct MultitrackChase {
    enum Decision: Equatable {

        case land

        case speed(Double)
    }

    static let land = 0.15

    static let smoothing = 0.5

    static let proportional = 0.5
    static let integral = 0.0625

    static let maxDeviation = 0.002

    private var error: Double?
    private var lastTime: Double?

    private var drift = 0.0

    mutating func reset() {
        error = nil
        lastTime = nil
    }

    mutating func step(error raw: Double, at time: Double) -> Decision {
        if abs(raw) > Self.land {
            reset()
            return .land
        }
        let dt = lastTime.map { min(max(time - $0, 0), 1) } ?? 0
        lastTime = time
        let smoothed = error.map { $0 + (raw - $0) * dt / (Self.smoothing + dt) } ?? raw
        error = smoothed
        let wanted = -(Self.proportional * smoothed + drift)
        let limited = min(max(wanted, -Self.maxDeviation), Self.maxDeviation)

        if wanted == limited { drift += Self.integral * smoothed * dt }
        return .speed(1 + limited)
    }
}
