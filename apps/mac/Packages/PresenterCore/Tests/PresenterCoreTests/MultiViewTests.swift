import Foundation
import Testing
@testable import PresenterCore

private typealias Choice = PreviewTargetLogic.Choice

private let screens = [Choice(id: "screen-1", name: "Projector"), Choice(id: "screen-2", name: "Stream")]
private let layouts = [Choice(id: PreviewTargetLogic.layoutTarget("doc-1"), name: "Booth")]

@Test func layoutTargetsRoundTripAndScreensAreNotLayouts() {
    #expect(PreviewTargetLogic.layoutID(for: PreviewTargetLogic.layoutTarget("doc-1")) == "doc-1")
    #expect(PreviewTargetLogic.layoutID(for: "screen-1") == nil)
    #expect(PreviewTargetLogic.layoutID(for: PreviewTargetLogic.layoutPrefix) == nil)
}

@Test func aStoredLayoutPickResolvesAndADeletedOneFallsBackToTheFirstScreen() {
    let stored = PreviewTargetLogic.layoutTarget("doc-1")
    #expect(PreviewTargetLogic.resolve(stored: stored, screens: screens, layouts: layouts)?.name == "Booth")
    #expect(PreviewTargetLogic.resolve(stored: stored, screens: screens, layouts: [])?.id == "screen-1")
    #expect(PreviewTargetLogic.resolve(stored: "", screens: [], layouts: layouts)?.name == "Booth")
    #expect(PreviewTargetLogic.resolve(stored: "", screens: [], layouts: []) == nil)
}

@Test func aLayoutPreviewsAtItsOwnCanvasAspect() {
    #expect(PreviewTargetLogic.aspect(canvasWidth: 1080, canvasHeight: 1920) == 1080.0 / 1920.0)
    #expect(PreviewTargetLogic.aspect(canvasWidth: nil, canvasHeight: nil) == 16.0 / 9.0)
    #expect(PreviewTargetLogic.aspect(canvasWidth: 1080, canvasHeight: 0) == 16.0 / 9.0)
}

private let sources = [
    MultiViewTemplate.Source(screenId: "screen-1", name: "Projector"),
    MultiViewTemplate.Source(screenId: "screen-2", name: "Stream"),
]

@Test func tilesTakeThisMachinesScreensInOrderAndTheRestStartEmpty() {
    let layout = MultiViewTemplate.wideGrid.make(name: "Booth", sources: sources)
    let monitors = layout.objects.filter { $0.fill?.fillKind == .media }

    #expect(monitors.map(\.fill?.screenSourceId) == ["screen-1", "screen-2"])
    #expect(monitors.allSatisfy { $0.fill?.mediaScaleMode == .fit })
    #expect(layout.objects.filter { $0.name == "Label" }.map(\.text)
        == ["Projector", "Stream", "No Source", "No Source"])

    let screens = layout.multiView?.nodes.filter { $0.sourceKind == .screen } ?? []
    #expect(screens.map(\.screenSourceName) == ["Projector", "Stream"])
}

@Test func theTallTemplateCarriesAVerticalCanvasAndWideOnesStoreAbsent() {
    let tall = MultiViewTemplate.tallStack.make(name: "Rail")
    #expect(tall.canvasWidth == 1080)
    #expect(tall.canvasHeight == 1920)
    #expect(MultiViewTemplate.wideFeature.make(name: "Booth").canvasWidth == nil)
}

@Test func everyTemplatesObjectsAreItsTreesAndStayOnItsCanvas() throws {
    for template in MultiViewTemplate.allCases {
        let layout = template.make(name: template.title, sources: sources)
        let tree = try #require(layout.multiView)
        let context = MultiViewTiles.Context(screens: sources.map { .init(id: $0.screenId, name: $0.name) })
        #expect(layout.objects == MultiViewTiles.objects(
            for: tree, canvasWidth: template.canvasWidth, canvasHeight: template.canvasHeight, context: context))
        for object in layout.objects {
            #expect((object.x ?? 0) >= 0 && (object.y ?? 0) >= 0)
            #expect((object.x ?? 0) + (object.width ?? 0) <= Double(template.canvasWidth) + 0.001)
            #expect((object.y ?? 0) + (object.height ?? 0) <= Double(template.canvasHeight) + 0.001)
        }
    }
    let linked = MultiViewTemplate.tallStack.make(name: "Rail").objects.compactMap(\.textLink?.source)
    #expect(linked == [.clock, .timer])
}

@Test func aMonitoredInputPlaysButIsNeverALiveInput() {
    let onAir: [String: Bool?] = ["input::item::cam1": nil, "clip": true]
    let monitoring: [String: Bool?] = ["input::item::cam2": nil, "clip": false, "screen::a": nil]

    let wanted = MonitoringMedia.wanted(onAir: onAir, monitoring: monitoring)

    #expect(Set(wanted.keys) == ["input::item::cam1", "input::item::cam2", "clip", "screen::a"])
    #expect(wanted["clip"] == .some(true))
    #expect(MonitoringMedia.liveInputs(onAir: onAir, prefix: "input::item::") == ["cam1"])
}
