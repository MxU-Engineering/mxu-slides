import Foundation
import IOKit.pwr_mgt

@MainActor
public protocol PowerAsserting {

    func beginAssertions(reason: String)

    func endAssertions()
}

@MainActor
public final class SleepProofing {
    public private(set) var isActive = false
    private let assertions: any PowerAsserting

    public init(assertions: any PowerAsserting = SystemPowerAssertions()) {
        self.assertions = assertions
    }

    public func setLiveOutputCount(_ count: Int) {
        let shouldBeActive = count > 0
        guard shouldBeActive != isActive else { return }
        isActive = shouldBeActive
        if shouldBeActive {
            assertions.beginAssertions(reason: "MxU Slides output is live")
        } else {
            assertions.endAssertions()
        }
    }
}

@MainActor
public final class SystemPowerAssertions: PowerAsserting {
    private var activityToken: NSObjectProtocol?
    private var iopmAssertionID = IOPMAssertionID(0)

    public init() {}

    public func beginAssertions(reason: String) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: reason
        )
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            iopmAssertionID = assertionID
        }
    }

    public func endAssertions() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        if iopmAssertionID != 0 {
            IOPMAssertionRelease(iopmAssertionID)
            iopmAssertionID = 0
        }
    }
}
