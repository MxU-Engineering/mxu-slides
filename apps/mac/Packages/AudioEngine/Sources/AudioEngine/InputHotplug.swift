import Foundation

public enum InputHotplug {
    public enum Action: Equatable, Sendable {
        case start
        case suspend
        case none
    }

    public static func decide(devicePresent: Bool, captureLive: Bool) -> Action {
        switch (devicePresent, captureLive) {
        case (true, false): .start
        case (false, true): .suspend
        default: .none
        }
    }
}
