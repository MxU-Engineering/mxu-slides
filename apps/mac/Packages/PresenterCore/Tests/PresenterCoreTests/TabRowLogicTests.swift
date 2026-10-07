import Foundation
import Testing
@testable import PresenterCore

@Test func tabRowMergedOrderKeepsStoredAndAppendsNew() {

    let merged = TabRowLogic.mergedOrder(
        stored: ["b", "ghost", "a"], all: ["a", "b", "c", "d"])
    #expect(merged == ["b", "a", "c", "d"])
    #expect(TabRowLogic.mergedOrder(stored: [], all: ["a", "b"]) == ["a", "b"])
}

@Test func tabRowEnabledFiltersHiddenAndNeverEmpties() {
    #expect(TabRowLogic.enabled(order: ["a", "b", "c"], hidden: ["b"]) == ["a", "c"])

    #expect(TabRowLogic.enabled(order: ["a", "b"], hidden: ["a", "b"]) == ["a", "b"])
}

@Test func tabRowSplitShowsAllWhenTheyFit() {

    let count = TabRowLogic.visibleCount(
        widths: [50, 50, 50], spacing: 4, containerWidth: 160, chevronWidth: 24)
    #expect(count == 3)
}

@Test func tabRowSplitReservesChevronOnOverflow() {

    let count = TabRowLogic.visibleCount(
        widths: [50, 50, 50, 50], spacing: 4, containerWidth: 160, chevronWidth: 24)
    #expect(count == 2)
}

@Test func tabRowSplitIsHonestWhenTight() {

    let count = TabRowLogic.visibleCount(
        widths: [50, 50, 50, 50], spacing: 4, containerWidth: 100, chevronWidth: 24)
    #expect(count == 1)

    #expect(
        TabRowLogic.visibleCount(
            widths: [80, 80], spacing: 4, containerWidth: 60, chevronWidth: 24) == 0)
    #expect(
        TabRowLogic.visibleCount(
            widths: [], spacing: 4, containerWidth: 60, chevronWidth: 24) == 0)
}

@Test func tabRowSpacingJustifiesLeftoverWidth() {

    let spacing = TabRowLogic.distributedSpacing(
        widths: [50, 50], chevronWidth: 26, containerWidth: 200, minimumSpacing: 3)
    #expect(spacing == 37)

    #expect(
        TabRowLogic.distributedSpacing(
            widths: [90, 90], chevronWidth: 26, containerWidth: 200,
            minimumSpacing: 3) == 3)

    #expect(
        TabRowLogic.distributedSpacing(
            widths: [50], chevronWidth: nil, containerWidth: 200,
            minimumSpacing: 3) == 3)
}

@Test func folderTreeNestsAndSynthesizesIntermediates() {

    let tree = FolderTreeLogic.tree(
        paths: ["Lower Thirds/Sermon", "announcements", "Test", ""])
    #expect(tree.map(\.name) == ["announcements", "Lower Thirds", "Test"])
    #expect(tree[1].path == "Lower Thirds")
    #expect(tree[1].children == [
        FolderNode(name: "Sermon", path: "Lower Thirds/Sermon"),
    ])
    #expect(FolderTreeLogic.tree(paths: []).isEmpty)
}

@Test func rackGroupingRootFirstThenFoldersByName() {
    let items = [
        (id: "1", path: "Lower Thirds"),
        (id: "2", path: ""),
        (id: "3", path: "announcements"),
        (id: "4", path: "Lower Thirds"),
        (id: "5", path: "Lower Thirds/Sermon"),
    ]
    let groups = ControlRackLogic.groupedByFolder(items) { $0.path }
    #expect(groups.map(\.folder) == ["", "announcements", "Lower Thirds", "Lower Thirds/Sermon"])
    #expect(groups[0].items.map(\.id) == ["2"])
    #expect(groups[2].items.map(\.id) == ["1", "4"])
}
