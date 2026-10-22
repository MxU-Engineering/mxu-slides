import Foundation
import RenderEngine

enum MirrorCadence {

    static let maxSteer = 0.002

    static let gain = 0.2

    static let rateTolerance = 0.01

    static let staleAfterPeriods = 3.0

    static let cardTarget = 0.15

    struct Step: Equatable {

        var interval: Double

        var edgeDistance: Double

        var period: Double
    }

    static func next(
        nominal: Double, now: CFTimeInterval, reference: LiveCadence?, target: Double = 0.5
    ) -> Step? {
        reference.flatMap { reference -> Step? in
            let age = now - reference.lastArrival
            let multiple = reference.period > 0 ? (nominal / reference.period).rounded() : 0
            let followed = multiple * reference.period
            let followable = multiple >= 1
                && abs(followed - nominal) / nominal <= rateTolerance
                && age >= 0 && age < reference.period * staleAfterPeriods
            if followable {

                let phase = age.truncatingRemainder(dividingBy: reference.period)
                var error = phase - reference.period * target
                if error >= reference.period / 2 { error -= reference.period }
                if error < -reference.period / 2 { error += reference.period }
                let steered = followed - gain * error
                return Step(
                    interval: min(max(steered, nominal - maxSteer), nominal + maxSteer),
                    edgeDistance: min(phase, reference.period - phase),
                    period: reference.period)
            } else {
                return nil
            }
        }
    }
}
