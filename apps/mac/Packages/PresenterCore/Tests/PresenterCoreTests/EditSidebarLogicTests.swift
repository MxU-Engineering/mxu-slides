import PresenterCore
import Testing

@Suite struct EditSidebarLogicTests {
    private func go(_ old: String, _ new: String, visible: Bool, hide: Bool, remembered: Bool? = nil) -> EditSidebarLogic.Result {
        EditSidebarLogic.switching(from: old, to: new, visible: visible, hideOnEdit: hide, remembered: remembered)
    }

    @Test func offByDefaultOneSidebarServesEveryMode() {
        #expect(go("present", "edit", visible: true, hide: false) == .init(visible: true, remembered: nil))
        #expect(go("edit", "present", visible: false, hide: false) == .init(visible: false, remembered: nil))
    }

    @Test func onEnteringEditHidesItAndRemembersPresents() {
        #expect(go("present", "edit", visible: true, hide: true) == .init(visible: false, remembered: true))
        #expect(go("scheduler", "edit", visible: false, hide: true) == .init(visible: false, remembered: false))
    }

    @Test func leavingEditGivesBackWhatItWas() {

        #expect(go("edit", "present", visible: true, hide: true, remembered: false) == .init(visible: false, remembered: nil))
        #expect(go("edit", "present", visible: false, hide: true, remembered: true) == .init(visible: true, remembered: nil))

        #expect(go("edit", "scheduler", visible: false, hide: false, remembered: true) == .init(visible: true, remembered: nil))
    }

    @Test func otherSwitchesLeaveItAlone() {
        #expect(go("present", "scheduler", visible: true, hide: true) == .init(visible: true, remembered: nil))
        #expect(go("edit", "edit", visible: false, hide: true, remembered: true) == .init(visible: false, remembered: true))
    }
}
