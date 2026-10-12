import Foundation

public enum FocusWatch {

    public struct Click: Equatable, Sendable {
        public var appActive: Bool
        public var hasKeyWindow: Bool

        public var targetIsMain: Bool
        public var targetCanBecomeKey: Bool

        public var targetBlocked: Bool

        public var command: Bool

        public init(
            appActive: Bool, hasKeyWindow: Bool, targetIsMain: Bool,
            targetCanBecomeKey: Bool, targetBlocked: Bool, command: Bool = false
        ) {
            self.appActive = appActive
            self.hasKeyWindow = hasKeyWindow
            self.targetIsMain = targetIsMain
            self.targetCanBecomeKey = targetCanBecomeKey
            self.targetBlocked = targetBlocked
            self.command = command
        }

        private var keyable: Bool {
            targetIsMain && targetCanBecomeKey && !targetBlocked && !command
        }

        public var rescuesBeforeClick: Bool {
            appActive && !hasKeyWindow && keyable
        }

        public func isStuck(hasKeyWindowAfter: Bool) -> Bool {
            !hasKeyWindowAfter && keyable
        }

        public var summary: String {
            [
                appActive ? "app active" : "app inactive",
                hasKeyWindow ? "a key window" : "no key window",
                targetCanBecomeKey ? nil : "window can't become key",
                targetBlocked ? "window blocked" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
        }
    }
}
