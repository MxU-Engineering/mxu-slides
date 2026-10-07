import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func lyricSlide(_ id: String, _ text: String) -> Slide {
    Slide(
        id: id, name: id,
        objects: [SlideObject(id: "\(id)-text", objectKind: .text, name: "Lyrics", text: text)]
    )
}

private func items(in scene: RenderScene, layer: LayerKind) -> [RenderItem] {
    scene.layers.first { $0.kind == layer }?.items ?? []
}

@Test func alertFiresAndReplacesTheLiveOne() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "Mic is muted", behavior: .flash))
    show.fire(alert: CueAlert(message: "Slow down", behavior: .persist))
    #expect(show.liveAlert?.message == "Slow down", "one alert at a time — firing replaces")
}

@Test func clearFunctionAlertsSweepsTheAlert() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "x", behavior: .persist))
    show.clear(function: .alerts)
    #expect(show.liveAlert == nil)
}

@Test func clearLayerAlertsSweepsTheAlert() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "x", behavior: .persist))
    show.clear(layer: .alerts)
    #expect(show.liveAlert == nil)
}

@Test func clearAllIncludesAlerts() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "x", behavior: .flash))
    show.clearAll()
    #expect(show.liveAlert == nil)
}

@Test func alertPersistsAcrossSlideAdvances() {

    var show = ShowState()
    show.fire(alert: CueAlert(message: "x", behavior: .persist))
    show.fire(slide: lyricSlide("a", "verse"), presentation: nil)
    #expect(show.liveAlert != nil)
}

@Test func confidenceAlertNeverReachesTheProgramScene() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "Stage only", behavior: .persist, target: .confidence))
    #expect(items(in: show.scene(), layer: .alerts).isEmpty,
            "a confidence alert must never land on audience glass")
}

@Test func audienceAlertRendersOnTheProgramAlertsLayer() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "Child 42 to nursery", behavior: .persist, target: .audience))
    #expect(!items(in: show.scene(), layer: .alerts).isEmpty)
}

@Test func confidenceSceneShowsConfidenceAlertOnly() {
    let stage = ConfidenceInfo(
        alert: CueAlert(message: "Stage only", behavior: .persist, target: .confidence)
    )
    let audience = ConfidenceInfo(
        alert: CueAlert(message: "Kid call", behavior: .persist, target: .audience)
    )
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(!items(in: ConfidenceSceneBuilder.scene(info: stage, at: date), layer: .alerts).isEmpty)
    #expect(items(in: ConfidenceSceneBuilder.scene(info: audience, at: date), layer: .alerts).isEmpty,
            "audience alerts belong to the program scene, not the stage layout")
}

@Test func flashPhaseHidesTheAlertOnItsOffBeat() {
    var show = ShowState()
    show.fire(alert: CueAlert(message: "x", behavior: .flash, target: .audience))
    #expect(!items(in: show.scene(alertVisible: true), layer: .alerts).isEmpty)
    #expect(items(in: show.scene(alertVisible: false), layer: .alerts).isEmpty)

    let info = ConfidenceInfo(
        alert: CueAlert(message: "x", behavior: .flash, target: .confidence),
        alertVisible: false
    )
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(items(in: ConfidenceSceneBuilder.scene(info: info, at: date), layer: .alerts).isEmpty)
}

private func alertsTheme(slideName: String) -> Theme {
    Theme(
        id: "t", name: "Theme", fontFamily: "Helvetica", fontSize: 60,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
        slides: [Slide(
            id: "t-alerts", name: slideName,
            objects: [
                SlideObject(
                    id: "t-decor", objectKind: .shape, name: "Band", text: "",
                    shapeKind: .rectangle
                ),
                SlideObject(id: "t-msg", objectKind: .text, name: "Message", text: "Sample"),
            ]
        )]
    )
}

@Test func themedAudienceAlertComposesThroughTheAlertsThemeSlide() {
    let alert = CueAlert(
        message: "Child 42", behavior: .persist, target: .audience,
        theme: alertsTheme(slideName: "Alerts")
    )
    let rendered = AlertSceneBuilder.audienceItems(
        for: alert, canvasSize: SlideSceneBuilder.canvasSize
    )

    #expect(rendered.count == 2)
    let texts = rendered.compactMap { item -> String? in
        if case .text(let styled) = item.content { return styled.string }
        return nil
    }
    #expect(texts == ["Child 42"], "the fired message fills the placeholder; sample text never renders")
}

@Test func themedAlertResolvesTimerLinkedText() {

    var theme = alertsTheme(slideName: "Alerts")
    var timerBox = SlideObject(id: "t-timer", objectKind: .text, name: "Timer", text: "")
    timerBox.textLink = TextLink(source: .timer, timerId: "grace")
    theme.slides?[0].objects.append(timerBox)

    let start = Date(timeIntervalSince1970: 1_000)
    var info = ConfidenceInfo()
    info.timers = [TimerSnapshot(
        id: "grace", name: "Grace Timer", mode: .countdown,
        isRunning: true, runningSince: start, durationSeconds: 450
    )]
    let alert = CueAlert(
        message: "Service starts soon", behavior: .persist, target: .audience,
        theme: theme
    )
    let rendered = AlertSceneBuilder.audienceItems(
        for: alert, canvasSize: SlideSceneBuilder.canvasSize,
        info: info, at: start.addingTimeInterval(30)
    )
    let texts = rendered.compactMap { item -> String? in
        if case .text(let styled) = item.content { return styled.string }
        return nil
    }
    #expect(texts.contains { $0.contains("7:00") }, "450s minus 30 elapsed reads 7:00, live")

    let unresolved = AlertSceneBuilder.audienceItems(
        for: alert, canvasSize: SlideSceneBuilder.canvasSize
    )
    #expect(unresolved.count == rendered.count)
}

@Test func alertMessageTimerTokensResolveLiveOthersPassThrough() {
    let start = Date(timeIntervalSince1970: 1_000)
    var info = ConfidenceInfo()
    info.timers = [TimerSnapshot(
        id: "grace", name: "Grace Timer", mode: .countdown,
        isRunning: true, runningSince: start, durationSeconds: 450
    )]
    let resolved = LinkedText.resolvedAlertMessage(
        "{Grace Timer} until we start, {Child}",
        info: info, at: start.addingTimeInterval(30)
    )
    #expect(resolved == "7:00 until we start, {Child}", "timer ticks, fill slot survives")
    #expect(LinkedText.alertMessageHasTimerToken("{Grace Timer}", timers: info.timers))
    #expect(!LinkedText.alertMessageHasTimerToken("{Child}", timers: info.timers))

    let alert = CueAlert(
        message: "{Grace Timer}", behavior: .persist, target: .audience, theme: nil
    )
    let banner = AlertSceneBuilder.bannerItems(
        for: alert, canvasSize: SlideSceneBuilder.canvasSize,
        info: info, at: start.addingTimeInterval(30)
    )
    let texts = banner.compactMap { item -> String? in
        if case .text(let styled) = item.content { return styled.string }
        return nil
    }
    #expect(texts == ["7:00"])
}

@Test func themeWithoutAlertsSlideFallsBackToTheBanner() {

    let alert = CueAlert(
        message: "Child 42", behavior: .persist, target: .audience,
        theme: alertsTheme(slideName: "Lyrics")
    )
    let rendered = AlertSceneBuilder.audienceItems(
        for: alert, canvasSize: SlideSceneBuilder.canvasSize
    )
    let banner = AlertSceneBuilder.bannerItems(
        for: alert, canvasSize: SlideSceneBuilder.canvasSize
    )
    #expect(rendered.map(\.frame) == banner.map(\.frame))
}

@Test func themedAlertDecorMediaStaysWanted() {
    var theme = alertsTheme(slideName: "Alerts")
    theme.slides?[0].objects.append(SlideObject(
        id: "t-motion", objectKind: .media, name: "Loop", text: "", mediaId: "bg-loop"
    ))
    var show = ShowState()
    show.fire(alert: CueAlert(
        message: "x", behavior: .persist, target: .audience, theme: theme
    ))
    #expect(show.wantedMedia().keys.contains("bg-loop"))
}

@Test func confidenceSceneCarriesCurrentAndNextText() {
    let info = ConfidenceInfo(
        current: ConfidenceInfo.SlideText(body: "Amazing grace"),
        next: ConfidenceInfo.SlideText(body: "How sweet the sound")
    )
    let scene = ConfidenceSceneBuilder.scene(
        info: info, at: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let texts = items(in: scene, layer: .slide).compactMap { item -> String? in
        if case .text(let styled) = item.content { return styled.string }
        return nil
    }
    #expect(texts.contains("Amazing grace"))
    #expect(texts.contains("How sweet the sound"))
    #expect(texts.contains("NEXT SLIDE"))
}

@Test func confidenceSceneAlwaysShowsTheClock() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let scene = ConfidenceSceneBuilder.scene(info: ConfidenceInfo(), at: date)

    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    let expected = formatter.string(from: date)
    let texts = items(in: scene, layer: .slide).compactMap { item -> String? in
        if case .text(let styled) = item.content { return styled.string }
        return nil
    }
    #expect(texts.contains(expected))
}

@Test func clockStringReadsTwelveHour() {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 7; parts.day = 5
    parts.hour = 14; parts.minute = 5
    let date = Calendar.current.date(from: parts)!
    #expect(ConfidenceSceneBuilder.clockString(date) == "2:05")
    parts.hour = 0; parts.minute = 30
    #expect(ConfidenceSceneBuilder.clockString(Calendar.current.date(from: parts)!) == "12:30")
}

@Test func lyricTextStripsEverythingButText() {
    let slide = Slide(id: "s", name: "s", objects: [
        SlideObject(id: "bg", objectKind: .media, name: "BG", text: "", mediaId: "m"),
        SlideObject(id: "l1", objectKind: .text, name: "Line 1", text: "Amazing grace"),
        SlideObject(id: "sh", objectKind: .shape, name: "Box", text: ""),
        SlideObject(id: "l2", objectKind: .text, name: "Line 2", text: "how sweet"),
    ])
    #expect(ConfidenceSceneBuilder.lyricText(for: slide) == "Amazing grace\nhow sweet")
}

@Test func nextSkipsBlankSlidesToTheFirstWithText() {

    let blank = Slide(id: "blank", name: "blank", objects: [])
    let shapeOnly = Slide(id: "shape", name: "shape", objects: [
        SlideObject(id: "s", objectKind: .shape, name: "Box", text: ""),
    ])
    let verse = lyricSlide("v2", "Through many dangers")
    #expect(
        ConfidenceSceneBuilder.nextSlide(in: [blank, shapeOnly, verse], skippingBlanks: true)?.id == "v2"
    )
    #expect(
        ConfidenceSceneBuilder.nextSlide(in: [blank, verse], skippingBlanks: false)?.id == "blank",
        "off = the literal next, blank or not"
    )
    #expect(ConfidenceSceneBuilder.nextSlide(in: [blank, shapeOnly], skippingBlanks: true) == nil,
            "nothing upcoming carries text — NEXT stays dark")
    #expect(ConfidenceSceneBuilder.nextSlide(in: [], skippingBlanks: true) == nil)
}

@Test func primaryTimerPrefersTheRunningOne() {
    let idle = TimerSnapshot(name: "Idle", mode: .countdown, durationSeconds: 300)
    let running = TimerSnapshot(
        name: "Sermon", mode: .countUp, isRunning: true, runningSince: Date()
    )
    #expect(ConfidenceSceneBuilder.primaryTimer([idle, running])?.name == "Sermon")
    #expect(ConfidenceSceneBuilder.primaryTimer([idle])?.name == "Idle")
    #expect(ConfidenceSceneBuilder.primaryTimer([]) == nil)
}

@Test func countdownCountsDownAndGoesNegativeInOvertime() {
    let start = Date(timeIntervalSince1970: 1_000)
    let timer = TimerSnapshot(
        name: "t", mode: .countdown, isRunning: true,
        runningSince: start, durationSeconds: 90
    )
    #expect(timer.value(at: start.addingTimeInterval(30)) == 60)
    #expect(timer.value(at: start.addingTimeInterval(100)) == -10, "overtime keeps counting")
}

@Test func pauseBanksElapsedAndResumeContinues() {
    let start = Date(timeIntervalSince1970: 1_000)
    var timer = TimerSnapshot(
        name: "t", mode: .countUp, isRunning: true, runningSince: start
    )

    timer.banked = timer.elapsed(at: start.addingTimeInterval(40))
    timer.isRunning = false
    timer.runningSince = nil
    #expect(timer.value(at: start.addingTimeInterval(500)) == 40, "paused timers hold still")

    timer.isRunning = true
    timer.runningSince = start.addingTimeInterval(500)
    #expect(timer.value(at: start.addingTimeInterval(510)) == 50)
}

@Test func countdownToTimeRunsAgainstTheWallRegardlessOfTransport() {
    let target = Date(timeIntervalSince1970: 10_000)
    let timer = TimerSnapshot(
        name: "t", mode: .countdownToTime, isRunning: false, targetTime: target
    )
    #expect(timer.value(at: target.addingTimeInterval(-120)) == 120)
    #expect(timer.value(at: target.addingTimeInterval(45)) == -45)
}

@Test func progressFillsTowardTheEnd() {
    let start = Date(timeIntervalSince1970: 1_000)
    var countdown = TimerSnapshot(
        name: "t", mode: .countdown, isRunning: true,
        runningSince: start, durationSeconds: 100
    )
    #expect(countdown.progress(at: start.addingTimeInterval(25)) == 0.25)
    #expect(countdown.progress(at: start.addingTimeInterval(500)) == 1, "overtime clamps full")
    countdown.durationSeconds = 0
    #expect(countdown.progress(at: start) == nil, "zero-length countdown has no bar")

    let armed = Date(timeIntervalSince1970: 0)
    let toTime = TimerSnapshot(
        name: "t", mode: .countdownToTime,
        targetTime: armed.addingTimeInterval(200), armedAt: armed
    )
    #expect(toTime.progress(at: armed.addingTimeInterval(50)) == 0.25)
    var unarmed = toTime
    unarmed.armedAt = nil
    #expect(unarmed.progress(at: armed) == nil, "no baseline, no bar")

    let unlimited = TimerSnapshot(name: "t", mode: .countUp)
    #expect(unlimited.progress(at: start) == nil, "an unlimited Count Up is unbounded")

    let limited = TimerSnapshot(
        name: "t", mode: .countUp, isRunning: true,
        runningSince: start, durationSeconds: 100
    )
    #expect(limited.progress(at: start.addingTimeInterval(25)) == 0.25)
}

@Test func countUpLimitDrivesWarningAndOverrun() {
    let start = Date(timeIntervalSince1970: 1_000)
    let limited = TimerSnapshot(
        name: "t", mode: .countUp, isRunning: true,
        runningSince: start, durationSeconds: 100
    )
    #expect(limited.urgency(at: start.addingTimeInterval(10)) == .normal)
    #expect(limited.urgency(at: start.addingTimeInterval(80)) == .warning, "inside the final 30s")
    #expect(limited.urgency(at: start.addingTimeInterval(130)) == .overrun, "past the limit")

    #expect(limited.value(at: start.addingTimeInterval(130)) == 130)

    let unlimited = TimerSnapshot(
        name: "t", mode: .countUp, isRunning: true, runningSince: start
    )
    #expect(unlimited.urgency(at: start.addingTimeInterval(9_999)) == .normal,
            "no limit, no urgency — runs until paused")
}

@Test func timerTextFormatsAbbreviationsAndWords() {
    let seconds: TimeInterval = 3 * 86400 + 11 * 3600 + 18 * 60 + 23
    #expect(TimerSnapshot.text(seconds, format: .digits) == "83:18:23")
    #expect(TimerSnapshot.text(seconds, format: .abbreviated) == "3d 11h 18m 23s")
    #expect(TimerSnapshot.text(seconds, format: .words) == "3 days 11 hours 18 minutes 23 seconds")
    #expect(TimerSnapshot.text(61, format: .words) == "1 minute 1 second")
    #expect(TimerSnapshot.text(45, format: .abbreviated) == "45s")
    #expect(TimerSnapshot.text(0, format: .abbreviated) == "0s")
    #expect(TimerSnapshot.text(-75, format: .abbreviated) == "-1m 15s")
}

@Test func timecodeFormatsBoothStyle() {
    #expect(TimerSnapshot.timecode(0) == "0:00")
    #expect(TimerSnapshot.timecode(59) == "0:59")
    #expect(TimerSnapshot.timecode(600) == "10:00")
    #expect(TimerSnapshot.timecode(3_723) == "1:02:03")
    #expect(TimerSnapshot.timecode(-83) == "-1:23")
}
