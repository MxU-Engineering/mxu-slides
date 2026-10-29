import PresenterCore
import Testing

@Suite struct VolunteerModeLogicTests {
    @Test func offeredOnlyWhenTurnedOn() {
        #expect(VolunteerModeLogic.choices(enabled: false) == [.present, .edit, .scheduler, .bible])
        #expect(VolunteerModeLogic.choices(enabled: true) == [.present, .edit, .scheduler, .bible, .volunteer])
    }

    @Test func noPasscodeToEnterOrLeave() {
        #expect(VolunteerModeLogic.picking(.volunteer, volunteerOn: false) == .enterVolunteer)
        #expect(VolunteerModeLogic.picking(.present, volunteerOn: true) == .leaveVolunteer(then: "present"))
        #expect(VolunteerModeLogic.picking(.edit, volunteerOn: true) == .leaveVolunteer(then: "edit"))
        #expect(VolunteerModeLogic.picking(.volunteer, volunteerOn: true) == .nothing)
        #expect(VolunteerModeLogic.picking(.edit, volunteerOn: false) == .switchMode("edit"))
        #expect(VolunteerModeLogic.picking(.bible, volunteerOn: false) == .switchMode("bible"))
        #expect(VolunteerModeLogic.picking(.bible, volunteerOn: true) == .leaveVolunteer(then: "bible"))
    }

    @Test func theSwitcherSaysVolunteerWhileItsOn() {
        #expect(VolunteerModeLogic.selected(mode: "present", volunteerOn: true) == .volunteer)
        #expect(VolunteerModeLogic.selected(mode: "edit", volunteerOn: false) == .edit)
        #expect(VolunteerModeLogic.selected(mode: "bible", volunteerOn: false) == .bible)
        #expect(VolunteerModeLogic.Choice.bible.title == "Bible")
        #expect(VolunteerModeLogic.Choice.volunteer.title == "Volunteer")
    }
}
