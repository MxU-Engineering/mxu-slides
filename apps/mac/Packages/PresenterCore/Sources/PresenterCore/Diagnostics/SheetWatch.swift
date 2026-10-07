import Foundation

public struct SheetWatch: Equatable, Sendable {

    public static let hiddenGrace: TimeInterval = 2

    public struct Look: Equatable, Sendable {
        public var isVisible: Bool
        public var alpha: Double

        public var onScreen: Bool

        public var hasArea: Bool

        public var covered: Bool

        public init(isVisible: Bool, alpha: Double, onScreen: Bool, hasArea: Bool, covered: Bool = false) {
            self.isVisible = isVisible
            self.alpha = alpha
            self.onScreen = onScreen
            self.hasArea = hasArea
            self.covered = covered
        }

        public var isHidden: Bool {
            !isVisible || alpha < 0.05 || !onScreen || !hasArea || covered
        }

        public var summary: String {
            if isHidden {
                let reasons = [
                    isVisible ? nil : "ordered out",
                    alpha < 0.05 ? String(format: "alpha %.2f", alpha) : nil,
                    onScreen ? nil : "off screen",
                    hasArea ? nil : "no area",
                    covered ? "covered" : nil,
                ].compactMap { $0 }
                return "hidden (" + reasons.joined(separator: ", ") + ")"
            } else {
                return "visible"
            }
        }
    }

    public struct Blocker: Equatable, Sendable {
        public var id: String
        public var name: String
        public var look: Look

        public init(id: String, name: String, look: Look) {
            self.id = id
            self.name = name
            self.look = look
        }
    }

    public struct Changes: Equatable, Sendable {
        public var began: [Blocker] = []
        public var ended: [String] = []

        public var hid: [Blocker] = []

        public var shown: [Blocker] = []
    }

    public private(set) var current: [String: Blocker] = [:]

    public private(set) var hiddenSince: [String: TimeInterval] = [:]
    private var names: [String: String] = [:]

    public init() {}

    public mutating func observe(_ blockers: [Blocker], at time: TimeInterval) -> Changes {
        var changes = Changes()
        let seen = Set(blockers.map(\.id))
        for id in current.keys.sorted() where !seen.contains(id) {
            changes.ended.append(names[id] ?? id)
            hiddenSince[id] = nil
            names[id] = nil
        }
        var next: [String: Blocker] = [:]
        for blocker in blockers {
            if current[blocker.id] == nil {
                changes.began.append(blocker)
            }
            if blocker.look.isHidden {
                if hiddenSince[blocker.id] == nil {
                    hiddenSince[blocker.id] = time
                    if current[blocker.id] != nil {
                        changes.hid.append(blocker)
                    }
                }
            } else {
                if hiddenSince[blocker.id] != nil {
                    changes.shown.append(blocker)
                }
                hiddenSince[blocker.id] = nil
            }
            next[blocker.id] = blocker
            names[blocker.id] = blocker.name
        }
        current = next
        return changes
    }

    public func shouldUnstick(_ id: String, at time: TimeInterval) -> Bool {
        if let since = hiddenSince[id] {
            time - since >= Self.hiddenGrace
        } else {
            false
        }
    }

    public static func shortName(typeDescriptions: [String], module: String = "MxUSlides", fallback: String) -> String {
        let prefix = module + "."
        let named = typeDescriptions.lazy.compactMap { description -> String? in
            if let range = description.range(of: prefix) {
                String(description[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            } else {
                nil
            }
        }.first { !$0.isEmpty }
        return named ?? fallback
    }

    public static func blockedClickSummary(
        target: String, blocker: Blocker, hiddenFor: TimeInterval?
    ) -> String {
        let hidden = hiddenFor.map { String(format: " for %.1f s", $0) } ?? ""
        return "click on \(target) blocked by \(blocker.name): \(blocker.look.summary)\(hidden)"
    }
}
