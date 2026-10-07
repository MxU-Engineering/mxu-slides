import Foundation
import Testing
@testable import PresenterCore

@Test func onboardingWalksContentThenScreens() {
    var flow = OnboardingFlow(firstRun: true)
    #expect(flow.step == .content && !flow.canGoBack && flow.includeGettingStarted)
    flow.back()
    #expect(flow.step == .content, "back stops at the first step")
    flow.advance()
    #expect(flow.step == .screens && flow.isLastStep && flow.canGoBack)
    flow.advance()
    #expect(flow.step == .screens, "advance stops at the last step")
}

@Test func onboardingContentChoicesDecideTheSeed() {

    var importing = OnboardingFlow(firstRun: true)
    importing.includeGettingStarted = false
    importing.choose(.importWorkspace)
    #expect(importing.step == .content && importing.choice == .importWorkspace && !importing.includeGettingStarted)

    var scratch = OnboardingFlow(firstRun: false)
    #expect(!scratch.includeGettingStarted)
    scratch.choose(.startFromScratch)
    #expect(scratch.step == .screens && scratch.includeGettingStarted)
}

@Test func quittingClosesTheWelcomeSheetInsteadOfBeingBlockedByIt() throws {
    let view = try String(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/OnboardingView.swift"), encoding: .utf8)
    #expect(view.contains(".interactiveDismissDisabled()\n        .background(QuitDismissesSheet())"))
    #expect(view.contains("window?.preventsApplicationTerminationWhenModal = false"))
}
