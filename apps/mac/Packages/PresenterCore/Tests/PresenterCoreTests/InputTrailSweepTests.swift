import Foundation
import Testing

@Suite struct InputTrailSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theRecorderRunsFromLaunch() throws {
        #expect(try source("MxUSlidesApp.swift").contains("InputTrailRecorder.shared.activate()"))
    }

    @Test func everyRunOrderSurfaceChangeSaysWhatInputCameBeforeIt() throws {
        let planner = try source("ServicePlannerView.swift")
        let note = try #require(planner.range(of: "\"runOrder.surface\","))
        let line = planner[note.upperBound...].prefix(300)
        #expect(line.contains("InputTrailRecorder.shared.cause()"))
        #expect(planner.contains("InputTrailRecorder.shared.record(\"marquee in run order\")"),
                "the marquee swallows its press before the monitor sees it")
        #expect(planner.contains(".inputRegion(\"run order\")"))
    }

    @Test func thePresentSurfaceIsNamedAndWatched() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains(".inputRegion(\"present\")"))
        #expect(surface.contains("PresentScrollWatch()"))
        let focus = try #require(surface.range(of: "\"present.focus\", detail: \"scroll"))
        #expect(surface[focus.upperBound...].prefix(200).contains("InputTrailRecorder.shared.noteFocusScroll()"),
                "a run-order jump is not an unprompted move")
        #expect(surface[focus.upperBound...].prefix(400).contains("PresentCardFrames.shared.reportLanding("),
                "every jump says which card it landed on")
    }

    @Test func aClickOnTheRowAlreadyShowingJumpsBackToIt() throws {
        let planner = try source("ServicePlannerView.swift")
        #expect(planner.contains("pressedRow: { rowPressed($0, $1, visible: visible) }"))
        let press = try #require(planner.range(of: "private func rowPressed("))
        let body = planner[press.upperBound...].prefix(900)
        #expect(body.contains("RunOrderSelection.isReselect("))
        #expect(body.contains("\"runOrder.click\""))
        #expect(body.contains("onReselect()"))

        let marquee = try source("ListMarquee.swift")
        #expect(marquee.contains("runIfClick(click, pressedAt: NSEvent.mouseLocation)"))
        #expect(marquee.contains("RunLoop.main.perform(inModes: [.default])"), "after the table's own press loop")
        #expect(!marquee.contains("coordinator.remove() }"), "row clicks count in run-only too")

        #expect(try source("AppShell.swift").contains(
            "onReselect: { if mode == .present { presentFocusScroll.reselect() } }"))
        let surface = try source("ServiceContinuousView.swift")
        let watch = try #require(surface.range(of: ".onChange(of: focusScroll.reselects)"))
        #expect(surface[watch.upperBound...].prefix(200).contains("reason: \"reselect\""))
    }

    @Test func aResizeOrSlidesAcrossChangeKeepsThePlace() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("let _ = PresentCardFrames.shared.show(rows)"))
        let width = try #require(surface.range(of: ".onChange(of: viewport.size.width)"))
        #expect(surface[width.upperBound...].prefix(120).contains("keepPlace(because: \"width\")"))
        let across = try #require(surface.range(of: ".onChange(of: slidesAcross)"))
        #expect(surface[across.upperBound...].prefix(120).contains("keepPlace(because: \"slides across\")"))
        let recorder = try source("InputTrailRecorder.swift")
        #expect(recorder.contains("PresentCardFrames.shared.scrollView = scrollView"))
        let moved = try #require(recorder.range(of: "    private func moved() {"))
        #expect(recorder[moved.upperBound...].prefix(80).contains("PresentCardFrames.shared.moved()"), "the place settles on every scroll")
        #expect(recorder.contains("PresentLanding.correction(for: anchor, in: self.cards, grids: self.currentGrids)"))
        #expect(recorder.contains("PresentLanding.anchor(self.cards, grids: self.currentGrids)"), "the slide at the top, not just the card")
    }

    @Test func regionMarkersCoverNothing() throws {
        let recorder = try source("InputTrailRecorder.swift")
        let modifier = try #require(recorder.range(of: "func inputRegion(_ name: String) -> some View {"))
        let body = recorder[modifier.upperBound...].prefix(400)
        #expect(body.contains(".frame(width: 0, height: 0)"))
        #expect(body.contains("InputRegionMarker(name: name, area: proxy.size)"))
        #expect(recorder.contains("CGRect(origin: .zero, size: area).contains(convert(windowPoint, from: nil))"))
    }

    @Test func cardsAboveTheTopChangingHeightDoNotMoveTheView() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains(".coordinateSpace(name: Self.contentSpace)"))
        let row = try #require(surface.range(of: "ForEach(rows, id: \\.presentRowIdentity) { item in"))
        let rowBody = surface[row.upperBound...].prefix(900)
        #expect(rowBody.contains("PresentCardFrames.shared.noteDoc("), "every row, not only sticky cards, reports where it sits")
        #expect(rowBody.contains("PresentCardFrames.shared.note("))
        let recorderSource = try source("InputTrailRecorder.swift")
        let apply = try #require(recorderSource.range(of: "private func applyHold() {"))
        #expect(recorderSource[apply.upperBound...].prefix(1600).contains("holdPinnedUntil = ProcessInfo.processInfo.systemUptime + 0.4"),
                "a correction pins the hold")
        let recorder = try source("InputTrailRecorder.swift")
        let moved = try #require(recorder.range(of: "    private func moved() {"))
        #expect(recorder[moved.upperBound...].prefix(120).contains("PresentCardFrames.shared.captureHold()"))
        #expect(recorder.contains("PresentHold.correction(heldTop: hold.top, nowTop: now.minY)"))
        #expect(recorder.contains("\"present.hold\""), "a hold says which card changed")
        let focus = try #require(surface.range(of: "\"present.focus\", detail: \"scroll"))
        #expect(surface[focus.upperBound...].prefix(400).contains("PresentCardFrames.shared.holdCard(target)"),
                "a run-order jump holds the card it jumped to")
    }

    @Test func theStickyHeaderTakesItsOwnHeight() throws {
        let surface = try source("ServiceContinuousView.swift")
        let sticky = try #require(surface.range(of: "let stick = max(0, min(-frame.minY, geo.size.height - headerHeight))"))
        let body = surface[sticky.upperBound...].prefix(700)
        let fixed = try #require(body.range(of: ".fixedSize(horizontal: false, vertical: true)"))
        let reader = try #require(body.range(of: ".background(headerHeightReader(item))"))
        #expect(fixed.lowerBound < reader.lowerBound, "measured after it is held to its own height")
    }
}
