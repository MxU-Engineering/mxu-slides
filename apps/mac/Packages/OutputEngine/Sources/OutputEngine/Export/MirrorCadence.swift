import Foundation
import RenderEngine

enum MirrorCadence {

    static let maxSteer = 0.002

    static let gain = 0.2

    static let rateTolerance = 0.01

    static let staleAfterPeriods = 3.0

    struct Step: Equatable {

        var interval: Double

        var edgeDistance: Double

        var period: Double
    }

    static func next(nominal: Double, now: CFTimeInterval, reference: LiveCadence?) -> Step? {
        reference.flatMap { reference -> Step? in
            let age = now - reference.lastArrival
            let multiple = reference.period > 0 ? (nominal / reference.period).rounded() : 0
            let followed = multiple * reference.period
            let followable = multiple >= 1
                && abs(followed - nominal) / nominal <= rateTolerance
                && age >= 0 && age < reference.period * staleAfterPeriods
            if followable {

                let phase = age.truncatingRemainder(dividingBy: reference.period)
                let error = phase - reference.period / 2
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
