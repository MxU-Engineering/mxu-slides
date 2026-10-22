import Foundation
import PresenterCore

public enum TransitionEdit {

    public static let durationRange: ClosedRange<Double> = 0 ... 3
    public static let typedRange: ClosedRange<Double> = 0 ... 30
    public static let durationStep = 0.1

    public static let durationPresets: [Double] = [0.5, 1, 1.5, 2, 3]

    public static let defaultDuration = 0.5

    public static func seconds(_ transition: Transition?) -> Double {
        transition?.durationSeconds ?? defaultDuration
    }

    public static func durationChoices(current: Transition?) -> [Double] {
        let now = (seconds(current) * 100).rounded() / 100
        return durationPresets.contains(now) ? durationPresets : (durationPresets + [now]).sorted()
    }

    public static func label(seconds: Double) -> String {
        let rounded = (seconds * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? "\(Int(rounded)) s"
            : String(format: "%g s", rounded)
    }

    public static func withKind(_ kind: TransitionKind?, from current: Transition?) -> Transition? {
        kind.map {
            Transition(transitionKind: $0, durationSeconds: current?.durationSeconds, colorHex: current?.colorHex)
        }
    }

    public static func withDuration(_ seconds: Double, from current: Transition?) -> Transition? {
        current.map {
            var out = $0
            out.durationSeconds = min(max(seconds, typedRange.lowerBound), typedRange.upperBound)
            return out
        }
    }
}
