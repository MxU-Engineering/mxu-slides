import Foundation

public struct OnboardingFlow: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case content, screens

        public var title: String {
            switch self {
            case .content: "Content"
            case .screens: "Screens"
            }
        }
    }

    public enum ContentChoice: Sendable {
        case importWorkspace, startFromScratch
    }

    public private(set) var step: Step = .content
    public private(set) var choice: ContentChoice?
    public var includeGettingStarted: Bool

    public init(firstRun: Bool) {
        includeGettingStarted = firstRun
    }

    public var canGoBack: Bool { step != .content }
    public var isLastStep: Bool { step == .screens }

    public mutating func advance() {
        step = Step(rawValue: step.rawValue + 1) ?? step
    }

    public mutating func back() {
        step = Step(rawValue: step.rawValue - 1) ?? step
    }

    public mutating func choose(_ choice: ContentChoice) {
        self.choice = choice
        if choice == .startFromScratch {
            includeGettingStarted = true
            advance()
        }
    }
}
