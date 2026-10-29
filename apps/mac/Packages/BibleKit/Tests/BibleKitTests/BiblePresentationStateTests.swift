import Testing
@testable import BibleKit

@Suite struct BiblePresentationStateTests {
    @Test func preparationSelectsWithoutRequestingOutputUntilExplicitlyArmed() {
        var state = BiblePresentationState()
        #expect(state.select(1, slideCount: 3) == nil)
        #expect(state.selectedIndex == 1)
        #expect(!state.isPresenting)
        #expect(state.togglePresentationMode(slideCount: 3) == 1)
        #expect(state.isPresenting)
        #expect(state.select(2, slideCount: 3) == 2)
    }

    @Test func disarmingAndLeavingWorkspaceNeverRequestAnotherLiveSlide() {
        var state = BiblePresentationState()
        _ = state.togglePresentationMode(slideCount: 3)
        #expect(state.togglePresentationMode(slideCount: 3) == nil)
        #expect(!state.isPresenting)
        #expect(state.select(2, slideCount: 3) == nil)
        #expect(state.togglePresentationMode(slideCount: 3) == 2)
        state.leaveWorkspace()
        #expect(!state.isPresenting)
        #expect(state.selectedIndex == 2)
        #expect(state.select(1, slideCount: 3) == nil)
    }

    @Test func invalidOrEmptySelectionsCannotGoLive() {
        var state = BiblePresentationState()
        #expect(state.togglePresentationMode(slideCount: 0) == nil)
        #expect(state.select(-1, slideCount: 3) == nil)
        #expect(state.select(3, slideCount: 3) == nil)
        #expect(state.selectedIndex == 0)
        #expect(!state.isPresenting)
        _ = state.select(2, slideCount: 3)
        #expect(state.togglePresentationMode(slideCount: 1) == nil)
        #expect(!state.isPresenting)
        state.resetSelection()
        #expect(state.selectedIndex == 0)
        #expect(state.togglePresentationMode(slideCount: 1) == 0)
    }
}
