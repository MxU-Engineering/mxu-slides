import PresenterCore
import Testing

@Suite struct VolunteerModeLogicTests {
    @Test func offeredOnlyWhenTurnedOn() {
        #expect(VolunteerModeLogic.choices(enabled: false) == [.present, .edit, .scheduler])
        #expect(VolunteerModeLogic.choices(enabled: true) == [.present, .edit, .scheduler, .volunteer])
    }

    @Test func noPasscodeToEnterOrLeave() {
        #expect(VolunteerModeLogic.picking(.volunteer, volunteerOn: false) == .enterVolunteer)
        #expect(VolunteerModeLogic.picking(.present, volunteerOn: true) == .leaveVolunteer(then: "present"))
        #expect(VolunteerModeLogic.picking(.edit, volunteerOn: true) == .leaveVolunteer(then: "edit"))
        #expect(VolunteerModeLogic.picking(.volunteer, volunteerOn: true) == .nothing)
        #expect(VolunteerModeLogic.picking(.edit, volunteerOn: false) == .switchMode("edit"))
    }

    @Test func theSwitcherSaysVolunteerWhileItsOn() {
        #expect(VolunteerModeLogic.selected(mode: "present", volunteerOn: true) == .volunteer)
        #expect(VolunteerModeLogic.selected(mode: "edit", volunteerOn: false) == .edit)
        #expect(VolunteerModeLogic.Choice.volunteer.title == "Volunteer")
    }
}
