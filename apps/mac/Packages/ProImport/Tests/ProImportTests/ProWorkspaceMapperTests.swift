import Foundation
import Testing
import PresenterCore
@testable import ProImport

struct ProWorkspaceMapperTests {

    private func uuid(_ string: String) -> RVData_UUID {
        var id = RVData_UUID()
        id.string = string
        return id
    }

    private func textElement(name: String, text: String, fontName: String = "Helvetica", dataLink: RVData_Slide.Element.DataLink.OneOf_PropertyType? = nil) -> RVData_Slide.Element {
        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid(UUID().uuidString)
        graphics.name = name
        graphics.bounds.origin.x = 100
        graphics.bounds.origin.y = 100
        graphics.bounds.size.width = 800
        graphics.bounds.size.height = 200
        graphics.opacity = 1
        var textBox = RVData_Graphics.Text()
        if !text.isEmpty {
            textBox.rtfData = Data("{\\rtf1\\ansi{\\fonttbl\\f0\\fnil \(fontName);}\\f0 \(text)}".utf8)
        }
        textBox.attributes.font.name = fontName
        textBox.attributes.font.size = 48
        graphics.text = textBox
        var element = RVData_Slide.Element()
        element.element = graphics
        if let dataLink {
            var link = RVData_Slide.Element.DataLink()
            link.propertyType = dataLink
            element.dataLinks = [link]
        }
        return element
    }

    @Test func themeMapsSlidesWithEmptyPlaceholders() {
        var doc = RVData_Template.Document()
        var slide = RVData_Template.Slide()
        slide.name = "Lyrics"
        var base = RVData_Slide()
        base.uuid = uuid("SLIDE-1")
        base.elements = [textElement(name: "Lyrics", text: "", fontName: "DrukWide-Medium")]
        slide.baseSlide = base

        var picture = RVData_Media()
        picture.uuid = uuid("MEDIA-BG")
        picture.url.storage = .absoluteString("file:///Users/presenter/Documents/ProPresenter/Themes/Lyrics%20Centered/Assets/bg.jpg")
        var local = RVData_URL.LocalRelativePath()
        local.path = "Assets/bg.jpg"
        picture.url.relativeFilePath = .local(local)
        picture.typeProperties = .image(RVData_Media.ImageTypeProperties())
        var mediaType = RVData_Action.MediaType()
        mediaType.element = picture
        var action = RVData_Action()
        action.actionTypeData = .media(mediaType)
        var audio = RVData_Media()
        audio.typeProperties = .audio(RVData_Media.AudioTypeProperties())
        var audioType = RVData_Action.MediaType()
        audioType.element = audio
        var audioAction = RVData_Action()
        audioAction.actionTypeData = .media(audioType)
        slide.actions = [action, audioAction]
        doc.slides = [slide]

        let mapped = ProWorkspaceMapper.mapTheme(doc, name: "Lyrics Centered")
        #expect(mapped.theme.id == "pro7-theme-lyrics-centered")
        #expect(mapped.theme.name == "Lyrics Centered")

        let slides = try! #require(mapped.theme.slides)
        #expect(slides.count == 1)
        #expect(slides[0].name == "Lyrics")

        #expect(slides[0].objects.count == 2)
        #expect(slides[0].objects[0].objectKind == .shape && slides[0].objects[0].fill?.fillKind == .media)
        #expect(slides[0].objects[0].fill?.mediaId?.hasPrefix("pro-media://") == true)
        #expect(slides[0].objects[0].width == 1920 && slides[0].objects[0].height == 1080)
        #expect(mapped.mediaWants.count == 1 && mapped.mediaWants[0].relativePath == "Assets/bg.jpg" && mapped.mediaWants[0].classification == .background)
        #expect(slides[0].objects[1].objectKind == .text)
        #expect(slides[0].objects[1].textStyle?.fontName == "DrukWide-Medium")

        #expect(mapped.theme.fontFamily == "DrukWide-Medium")
    }

    @MainActor
    @Test func aProThemeImportsOnItsOwn() async throws {
        var doc = RVData_Template.Document()
        var slide = RVData_Template.Slide()
        slide.name = "Scripture"
        var base = RVData_Slide()
        base.uuid = uuid("SLIDE-S")
        base.elements = [textElement(name: "Verse", text: "", fontName: "Helvetica"), textElement(name: "Reference", text: "", fontName: "Helvetica")]
        slide.baseSlide = base
        doc.slides = [slide]

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let themeDir = staging.appendingPathComponent("Message Series Theme", isDirectory: true)
        try FileManager.default.createDirectory(at: themeDir.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try (try doc.serializedData()).write(to: themeDir.appendingPathComponent("Theme"))
        let protheme = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).protheme")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", themeDir.path, protheme.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try await Library(rootURL: root)
        let importer = try ProPresenterImporter(client: await started(library))
        let summary = await importer.importTheme(at: protheme)
        #expect(summary.themeID == "pro7-theme-message-series-theme" && summary.name == "Message Series Theme" && summary.skipped == nil)
        let theme = try await library.store.load(Theme.self, id: "pro7-theme-message-series-theme").value
        #expect(theme.name == "Message Series Theme")
        #expect(theme.slides?.first?.name == "Scripture" && theme.slides?.first?.objects.filter { $0.objectKind == .text }.count == 2)

        let again = await importer.importTheme(at: protheme)
        #expect(again.themeID == summary.themeID)
        #expect((try? await library.index.entries(of: .theme))?.count == 1)
        #expect(ProPresenterImporter.themeFile(under: staging)?.lastPathComponent == "Theme")
        #expect((await importer.importTheme(at: staging.appendingPathComponent("nothing.protheme"))).themeID == nil)
    }

    @Test func propBecomesOverlay() {
        var doc = RVData_PropDocument()
        var cue = RVData_Cue()
        cue.uuid = uuid("PROP-1")
        cue.name = "Lower Third"
        var propSlide = RVData_PropSlide()
        var base = RVData_Slide()
        base.elements = [textElement(name: "Title", text: "Welcome")]
        propSlide.baseSlide = base
        var slideType = RVData_Action.SlideType()
        slideType.slide = .prop(propSlide)
        var action = RVData_Action()
        action.actionTypeData = .slide(slideType)
        cue.actions = [action]
        doc.cues = [cue]

        let mapped = ProWorkspaceMapper.mapProps(doc)
        #expect(mapped.count == 1)
        #expect(mapped[0].overlay.id == "prop-1")
        #expect(mapped[0].overlay.name == "Lower Third")
        #expect(mapped[0].overlay.objects.first?.text == "Welcome")
        #expect(mapped[0].overlay.layer == nil)  
    }

    @Test func messageBecomesAlertWithTemplateReference() {
        var doc = RVData_MessageDocument()
        var message = RVData_Message()
        message.uuid = uuid("MSG-1")
        message.title = "Ticker"
        message.messageText = "Service starts soon"
        message.template.name = "Ticker"
        message.template.slideName = "Ticker"
        doc.messages = [message]

        let mapped = ProWorkspaceMapper.mapMessages(doc)
        #expect(mapped.count == 1)
        #expect(mapped[0].preset.id == "msg-1")
        #expect(mapped[0].preset.message == "Service starts soon")
        #expect(mapped[0].preset.behavior == .persist)
        #expect(mapped[0].preset.target == .both)  
        #expect(mapped[0].templateThemeName == "Ticker")
    }

    @Test func messageTokensBecomeFillSlots() {
        var doc = RVData_MessageDocument()
        var message = RVData_Message()
        message.uuid = uuid("MSG-2")
        message.title = "Car"
        message.messageText = "Please move your car:"
        var token = RVData_Message.Token()
        var text = RVData_Message.Token.TokenTypeText()
        text.name = "plate"
        token.tokenType = .text(text)
        message.tokens = [token]
        doc.messages = [message]

        let mapped = ProWorkspaceMapper.mapMessages(doc)
        #expect(mapped[0].preset.message.contains("{plate}"))
        #expect(mapped[0].preset.target == nil)  
    }

    @Test func inlineTokenUUIDsRewriteToNamedSlots() {
        var doc = RVData_MessageDocument()
        var message = RVData_Message()
        message.uuid = uuid("MSG-3")
        message.title = "Grace Countdown"
        message.messageText = "${F1A218F8-8926-4EB4-949E-581CD071151B} starts the service"
        var token = RVData_Message.Token()
        token.uuid = uuid("F1A218F8-8926-4EB4-949E-581CD071151B")
        var timer = RVData_Message.Token.TokenTypeTimer()
        timer.name = "Grace Timer"
        token.tokenType = .timer(timer)
        message.tokens = [token]
        doc.messages = [message]

        let mapped = ProWorkspaceMapper.mapMessages(doc)
        #expect(mapped[0].preset.message == "{Grace Timer} starts the service")
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func stageLayoutMapsDataLinksToTextLinks() {
        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-1")
        layout.name = "Current + Next"

        var slideText = RVData_Slide.Element.DataLink.SlideText()
        slideText.sourceSlide = .nextSlide
        var timerText = RVData_Slide.Element.DataLink.TimerText()
        timerText.timerUuid = uuid("TIMER-1")
        timerText.timerName = "Sermon"
        var clockText = RVData_Slide.Element.DataLink.ClockText()
        clockText.format.militaryTimeEnabled = true

        var base = RVData_Slide()
        base.size.width = 1080
        base.size.height = 1200
        base.elements = [
            textElement(name: "Next", text: "sample", dataLink: .slideText(slideText)),
            textElement(name: "Timer", text: "", dataLink: .timerText(timerText)),
            textElement(name: "Clock", text: "", dataLink: .clockText(clockText)),
            textElement(name: "Message", text: "", dataLink: .stageMessage(.init())),
            textElement(name: "Group", text: "", dataLink: .groupName(.init())),
        ]
        layout.slide = base
        doc.layouts = [layout]

        let mapped = ProWorkspaceMapper.mapStageLayouts(doc, timerIDsByProUUID: ["timer-1": "mxu-timer-9"])
        #expect(mapped.count == 1)
        let layout1 = mapped[0].layout
        #expect(layout1.id == "layout-1")
        #expect(layout1.canvasWidth == 1080)
        #expect(layout1.canvasHeight == 1200)
        #expect(layout1.objects.count == 5)

        #expect(layout1.objects[4].textLink?.source == .nextSlide)
        #expect(layout1.objects[3].textLink?.source == .timer)
        #expect(layout1.objects[3].textLink?.timerId == "mxu-timer-9")
        #expect(layout1.objects[2].textLink?.source == .clock)
        #expect(layout1.objects[2].textLink?.clockFormat == "H:mm")
        #expect(layout1.objects[1].textLink?.source == .stageMessage)
        #expect(layout1.objects[0].textLink?.source == .currentGroup)
        #expect(mapped[0].warnings.isEmpty)

        #expect(layout1.objects[3].objectKind == .text)
    }

    @Test func stageVideoCountdownKeepsTheNamePrefixedRead() {

        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-VC")
        var base = RVData_Slide()
        base.elements = [textElement(name: "Countdown", text: "", dataLink: .videoCountdown(.init()))]
        layout.slide = base
        doc.layouts = [layout]

        let mapped = ProWorkspaceMapper.mapStageLayouts(doc)
        #expect(mapped[0].layout.objects[0].textLink?.source == .videoCountdown)
        #expect(mapped[0].layout.objects[0].textLink?.showsVideoName == nil)
    }

    @Test func unknownTimerFallsBackToPrimaryWithWarning() {
        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-2")
        var timerText = RVData_Slide.Element.DataLink.TimerText()
        timerText.timerUuid = uuid("GONE")
        timerText.timerName = "Missing Timer"
        var base = RVData_Slide()
        base.elements = [textElement(name: "Timer", text: "", dataLink: .timerText(timerText))]
        layout.slide = base
        doc.layouts = [layout]

        let mapped = ProWorkspaceMapper.mapStageLayouts(doc)
        #expect(mapped[0].layout.objects[0].textLink?.source == .timer)
        #expect(mapped[0].layout.objects[0].textLink?.timerId == nil)
        #expect(mapped[0].warnings.contains { $0.contains("Missing Timer") })
    }

    @Test func macroActionsMapOntoTheComboVocabulary() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-1")
        macro.name = "Preservice"
        var color = RVData_Color()
        color.red = 1; color.alpha = 1
        macro.color = color

        var clear = RVData_Action.ClearType()
        clear.targetLayer = .all
        var clearAction = RVData_Action()
        clearAction.actionTypeData = .clear(clear)

        var timer = RVData_Action.TimerType()
        timer.actionType = .actionResetAndStart
        timer.timerIdentification.parameterUuid = uuid("TIMER-1")
        var timerAction = RVData_Action()
        timerAction.actionTypeData = .timer(timer)

        timerAction.delayTime = 3

        var message = RVData_Action.MessageType()
        message.messageIdentificaton.parameterUuid = uuid("MSG-1")
        var messageAction = RVData_Action()
        messageAction.actionTypeData = .message(message)

        var stage = RVData_Action.StageLayoutType()
        var assignment = RVData_Stage.ScreenAssignment()
        assignment.layout.parameterUuid = uuid("LAYOUT-1")
        stage.stageScreenAssignments = [assignment]
        var stageAction = RVData_Action()
        stageAction.actionTypeData = .stage(stage)

        var prop = RVData_Action()
        prop.actionTypeData = .prop(RVData_Action.PropType())

        macro.actions = [clearAction, timerAction, messageAction, stageAction, prop]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(doc, timerIDsByProUUID: ["timer-1": "mxu-timer-9"])
        #expect(mapped.count == 1)
        let combo = mapped[0].combo
        #expect(combo.id == "macro-1")
        #expect(combo.name == "Preservice")
        #expect(combo.colorHex == "#FF0000FF")

        let kinds = combo.actions.map(\.kind)

        #expect(kinds == [.clearAll, .timerReset, .timerStart, .fireAlert, .setConfidenceLayout, .fireOverlay])
        #expect(combo.actions[1].timerId == "mxu-timer-9")
        #expect(combo.actions.map(\.delaySeconds) == [nil, 3, 3, nil, nil, nil])
        #expect(combo.actions[3].alertId == "msg-1")
        #expect(combo.actions[4].confidenceLayoutId == "layout-1")
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func playlistItemStepMapsToFireAudioPlaylist() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-4")
        macro.name = "Super Timer"
        var playlist = RVData_Action.PlaylistItemType()
        playlist.playlistUuid = uuid("PL-AUDIO-1")
        playlist.playlistName = "Greg's Hits"
        var playlistAction = RVData_Action()
        playlistAction.actionTypeData = .playlistItem(playlist)
        macro.actions = [playlistAction]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(doc)
        #expect(mapped[0].combo.actions.map(\.kind) == [.fireAudioPlaylist])
        #expect(mapped[0].combo.actions[0].playlistId == "pl-audio-1")
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func playlistItemStepCarriesItsStartingEntry() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-5")
        macro.name = "Walk-in from track 3"
        var playlist = RVData_Action.PlaylistItemType()
        playlist.playlistUuid = uuid("PL-AUDIO-1")
        playlist.itemUuid = uuid("ITEM-3")
        var playlistAction = RVData_Action()
        playlistAction.actionTypeData = .playlistItem(playlist)
        macro.actions = [playlistAction]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(doc)
        #expect(mapped[0].combo.actions[0].playlistId == "pl-audio-1")
        #expect(mapped[0].combo.actions[0].audioEntryId == "item-3")
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func clearAudioStepMapsToClearMusic() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-2")
        macro.name = "Showstopper"
        var clear = RVData_Action.ClearType()
        clear.targetLayer = .audio
        var clearAction = RVData_Action()
        clearAction.actionTypeData = .clear(clear)
        macro.actions = [clearAction]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(doc)
        #expect(mapped[0].combo.actions.map(\.kind) == [.clearAudio])
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func timerStepWithInlineConfigurationEmitsConfigure() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-5")
        macro.name = "Super Timer 7:30"
        var timer = RVData_Action.TimerType()
        timer.actionType = .actionResetAndStart
        timer.timerIdentification.parameterUuid = uuid("TIMER-1")
        var countdown = RVData_Timer.Configuration.TimerTypeCountdown()
        countdown.duration = 450
        var configuration = RVData_Timer.Configuration()
        configuration.timerType = .countdown(countdown)
        timer.timerConfiguration = configuration
        var timerAction = RVData_Action()
        timerAction.actionTypeData = .timer(timer)
        macro.actions = [timerAction]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(doc, timerIDsByProUUID: ["timer-1": "mxu-timer-1"])
        let actions = mapped[0].combo.actions
        #expect(actions.map(\.kind) == [.timerConfigure, .timerReset, .timerStart])
        #expect(actions[0].timerId == "mxu-timer-1")
        #expect(actions[0].timerMode == .countdown)
        #expect(actions[0].timerDurationSeconds == 450)
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func timerStepFallsBackToTheTimerName() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-3")
        macro.name = "PreRoll"
        var timer = RVData_Action.TimerType()
        timer.actionType = .actionStart
        timer.timerIdentification.parameterUuid = uuid("STALE-UUID")
        timer.timerIdentification.parameterName = "Grace Timer"
        var timerAction = RVData_Action()
        timerAction.actionTypeData = .timer(timer)
        macro.actions = [timerAction]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(
            doc, timerIDsByName: ["grace timer": "mxu-timer-1"])
        #expect(mapped[0].combo.actions.map(\.kind) == [.timerStart])
        #expect(mapped[0].combo.actions[0].timerId == "mxu-timer-1")
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func calendarEventsBecomeSchedulerTriggers() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        var weekly = RVData_Calendar.Event()
        weekly.uuid = uuid("EVENT-1")
        weekly.name = "Start Service 9:00"

        weekly.date.seconds = Int64(utc.date(
            from: DateComponents(year: 2026, month: 3, day: 22, hour: 8, minute: 52, second: 30)
        )!.timeIntervalSince1970)
        weekly.recurrenceDays = [.sunday]

        var excluded1 = RVData_Timestamp()
        excluded1.seconds = Int64(utc.date(
            from: DateComponents(year: 2026, month: 12, day: 27, hour: 8, minute: 52)
        )!.timeIntervalSince1970)
        var excluded2 = RVData_Timestamp()
        excluded2.seconds = Int64(utc.date(
            from: DateComponents(year: 2027, month: 1, day: 3, hour: 8, minute: 52)
        )!.timeIntervalSince1970)
        weekly.recurrenceExcludedDates = [excluded1, excluded2]

        weekly.recurrenceLimitDate.seconds = Int64(utc.date(
            from: DateComponents(year: 2027, month: 1, day: 31, hour: 8, minute: 52)
        )!.timeIntervalSince1970)
        var macroStep = RVData_Action.MacroType()
        macroStep.identification.parameterUuid = uuid("MACRO-1")
        var action = RVData_Action()
        action.actionTypeData = .macro(macroStep)
        weekly.actions = [action]

        var oneOff = RVData_Calendar.Event()
        oneOff.uuid = uuid("EVENT-2")
        oneOff.name = "Easter Service"
        oneOff.date.seconds = Int64(utc.date(
            from: DateComponents(year: 2026, month: 4, day: 5, hour: 9, minute: 0)
        )!.timeIntervalSince1970)

        var eventMacro = RVData_Calendar.Event.Action.Macro()
        eventMacro.identification.parameterUuid = uuid("MACRO-2")
        oneOff.action.actionType = .macro(eventMacro)

        var doc = RVData_Calendar()
        doc.events = [weekly, oneOff]
        doc.active = true

        let mapped = ProWorkspaceMapper.mapCalendar(doc, calendar: utc)
        #expect(mapped.count == 2)

        let sunday = mapped[0].trigger
        #expect(sunday.id == "event-1")
        #expect(sunday.conditions.count == 1)
        #expect(sunday.conditions[0].kind == .weekly)
        #expect(sunday.conditions[0].days == [1])

        #expect(sunday.conditions[0].timeOfDay == "08:52:30")

        #expect(sunday.conditions[0].excludedDates == ["2026-12-27", "2027-01-03"])
        #expect(sunday.actions.map(\.kind) == [.fireCombo])
        #expect(sunday.actions[0].comboId == "macro-1")

        #expect(sunday.enabledUntil == "2027-01-31T23:59:59")
        #expect(mapped[0].warnings.isEmpty)

        let easter = mapped[1].trigger
        #expect(easter.conditions[0].kind == .oneTime)
        #expect(easter.conditions[0].date == "2026-04-05T09:00")
        #expect(easter.actions.map(\.kind) == [.fireCombo])
        #expect(easter.actions[0].comboId == "macro-2")
        #expect(mapped[1].warnings.isEmpty)
    }

    @Test func screensMapWithRolesAndAssignments() {
        var workspace = RVData_ProPresenterWorkspace()
        var audience = RVData_ProPresenterScreen()
        audience.uuid = uuid("SCREEN-A")
        audience.name = "Main"
        audience.screenType = .audience
        var single = RVData_ProPresenterScreen.SingleArrangement()
        var display = RVData_Screen()
        display.bounds.size.width = 1920
        display.bounds.size.height = 1080
        single.screens = [display]
        audience.arrangement = .arrangementSingle(single)

        var stage = RVData_ProPresenterScreen()
        stage.uuid = uuid("SCREEN-S")
        stage.name = "Stage 1"
        stage.screenType = .stage
        var stageSingle = RVData_ProPresenterScreen.SingleArrangement()
        var stageDisplay = RVData_Screen()
        stageDisplay.bounds.size.width = 1080
        stageDisplay.bounds.size.height = 1200
        stageSingle.screens = [stageDisplay]
        stage.arrangement = .arrangementSingle(stageSingle)

        workspace.proScreens = [audience, stage]
        var mapping = RVData_Stage.ScreenAssignment()
        mapping.screen.parameterUuid = uuid("SCREEN-S")
        mapping.layout.parameterUuid = uuid("LAYOUT-1")
        workspace.stageLayoutMappings = [mapping]

        let plan = ProWorkspaceMapper.mapScreens(workspace).plan
        #expect(plan.screens.count == 2)
        #expect(plan.screens[0].correction == nil)  
        #expect(plan.screens[0].isConfidence == false)
        #expect(plan.screens[1].isConfidence == true)
        #expect(plan.screens[1].width == 1080)
        #expect(plan.screens[1].height == 1200)
        #expect(plan.stageAssignments == [
            ProScreenPlan.StageAssignment(screenProUUID: "screen-s", layoutID: "layout-1")
        ])
    }

    @Test func screenOutputCorrectionsImport() {
        var workspace = RVData_ProPresenterWorkspace()
        var screen = RVData_ProPresenterScreen()
        screen.uuid = uuid("SCREEN-P")
        screen.name = "Side LED"
        screen.screenType = .audience
        var single = RVData_ProPresenterScreen.SingleArrangement()
        var output = RVData_Screen()
        output.bounds.size.width = 1920
        output.bounds.size.height = 1080

        output.cornerPinningEnabled = true
        var corners = RVData_CornerValues()
        corners.topLeft.x = 24
        corners.topLeft.y = -12
        output.cornerValues = corners
        output.colorEnabled = true
        var color = RVData_Screen.ColorAdjustment()
        color.brightness = -0.2
        color.redLevel = 0.1
        output.colorAdjustment = color
        output.gamma = 0.05  
        output.rotation = 90  
        single.screens = [output]
        screen.arrangement = .arrangementSingle(single)
        workspace.proScreens = [screen]

        let mapped = ProWorkspaceMapper.mapScreens(workspace)
        let correction = try! #require(mapped.plan.screens[0].correction)
        #expect(correction.topLeft == .init(x: 24, y: -12))
        #expect(correction.topRight == nil)
        #expect(correction.brightness == -0.2)
        #expect(correction.redLevel == 0.1)
        #expect(correction.gamma == 0.05)
        #expect(correction.rotationDegrees == 90)
        #expect(!mapped.warnings.contains { $0.contains("rotation") })

        output.cornerPinningEnabled = false
        output.rotation = 0
        output.colorEnabled = false
        output.gamma = 0
        single.screens = [output]
        screen.arrangement = .arrangementSingle(single)
        workspace.proScreens = [screen]
        #expect(ProWorkspaceMapper.mapScreens(workspace).plan.screens[0].correction == nil)
    }

    @Test func emptyArrangementImportsWithoutSlicesOrWarnings() {

        var workspace = RVData_ProPresenterWorkspace()
        var screen = RVData_ProPresenterScreen()
        screen.uuid = uuid("SCREEN-W")
        screen.name = "Wide"
        var blend = RVData_ProPresenterScreen.EdgeBlendArrangement()
        blend.screenCount = 2
        screen.arrangement = .arrangementEdgeBlend(blend)
        workspace.proScreens = [screen]
        let mapped = ProWorkspaceMapper.mapScreens(workspace)
        #expect(mapped.plan.screens.count == 1)
        #expect(mapped.plan.screens[0].slices.isEmpty)
        #expect(!mapped.warnings.contains { $0.contains("multi-projector") })
    }

    @Test func spanArrangementsImportAtTheirCanvasSize() {

        func output(x: Double, width: Double, height: Double) -> RVData_Screen {
            var out = RVData_Screen()
            out.bounds.origin.x = x
            out.bounds.size.width = width
            out.bounds.size.height = height
            return out
        }
        var workspace = RVData_ProPresenterWorkspace()
        var blended = RVData_ProPresenterScreen()
        blended.uuid = uuid("SCREEN-EB")
        blended.name = "Triple Wide"
        var blend = RVData_ProPresenterScreen.EdgeBlendArrangement()
        blend.screenCount = 2
        blend.screens = [
            output(x: 0, width: 1920, height: 1080),
            output(x: 1920, width: 1920, height: 1080),
        ]
        blended.arrangement = .arrangementEdgeBlend(blend)
        var combined = RVData_ProPresenterScreen()
        combined.uuid = uuid("SCREEN-CB")
        combined.name = "Grid"
        var grid = RVData_ProPresenterScreen.CombinedArrangement()
        grid.screens = [
            output(x: 0, width: 1280, height: 720),
            output(x: 1280, width: 1280, height: 720),
        ]
        combined.arrangement = .arrangementCombined(grid)
        workspace.proScreens = [blended, combined]
        let mapped = ProWorkspaceMapper.mapScreens(workspace)
        #expect(mapped.plan.screens[0].width == 3840)
        #expect(mapped.plan.screens[0].height == 1080)
        #expect(mapped.plan.screens[1].width == 2560)
        #expect(mapped.plan.screens[1].height == 720)
        #expect(mapped.warnings.isEmpty)

        let blendSlices = mapped.plan.screens[0].slices
        #expect(blendSlices.count == 2)
        #expect(abs(blendSlices[0].x - 0) < 0.001 && abs(blendSlices[0].width - 0.5) < 0.001)
        #expect(abs(blendSlices[1].x - 0.5) < 0.001 && abs(blendSlices[1].width - 0.5) < 0.001)
        #expect(mapped.plan.screens[1].slices.count == 2)
    }

    @Test func edgeBlendArrangementImportsRampsAndRegions() {

        func output(_ id: String, x: Double) -> RVData_Screen {
            var out = RVData_Screen()
            out.uuid = uuid(id)
            out.bounds.origin.x = x
            out.bounds.size.width = 1920
            out.bounds.size.height = 1080
            out.subscreenUnitRect.origin.x = x / 3840
            out.subscreenUnitRect.size.width = 0.5
            out.subscreenUnitRect.size.height = 1
            return out
        }
        func edge(
            _ id: String, _ edge: RVData_EdgeBlend.Screen.Edge,
            radius: Double, gamma: Double, mode: RVData_EdgeBlend.Mode,
            intensity: Double = 0, blackLevel: Double = 0
        ) -> RVData_EdgeBlend.Screen {
            var entry = RVData_EdgeBlend.Screen()
            entry.uuid = uuid(id)
            entry.edge = edge
            entry.radius = radius
            entry.gamma = gamma
            entry.mode = mode
            entry.intensity = intensity
            entry.blackLevel = blackLevel
            return entry
        }
        var workspace = RVData_ProPresenterWorkspace()
        var screen = RVData_ProPresenterScreen()
        screen.uuid = uuid("SCREEN-EB2")
        screen.name = "Blend Wall"
        var blend = RVData_ProPresenterScreen.EdgeBlendArrangement()
        blend.screenCount = 2
        var rightOutput = output("OUT-R", x: 1920)
        rightOutput.blendCompensation.blackLevel = 0.05
        blend.screens = [output("OUT-L", x: 0), rightOutput]
        var pair = RVData_EdgeBlend()
        pair.firstScreen = edge(
            "OUT-L", .right, radius: 96, gamma: 2.4, mode: .linear,
            intensity: 0.7, blackLevel: 0.08)
        pair.secondScreen = edge("OUT-R", .left, radius: 96, gamma: 0, mode: .cubic)
        blend.edgeBlends = [pair]
        screen.arrangement = .arrangementEdgeBlend(blend)
        workspace.proScreens = [screen]

        let mapped = ProWorkspaceMapper.mapScreens(workspace)
        let slices = mapped.plan.screens[0].slices
        #expect(slices.count == 2)
        #expect(abs(slices[0].x - 0) < 0.001 && abs(slices[1].x - 0.5) < 0.001)

        #expect(abs((slices[0].blendRight?.width ?? 0) - 0.05) < 0.001)
        #expect(abs((slices[0].blendRight?.curve ?? 0) - 2.4) < 0.001)
        #expect(slices[0].blendLeft == nil)

        #expect(abs((slices[1].blendLeft?.width ?? 0) - 0.05) < 0.001)
        #expect(abs((slices[1].blendLeft?.curve ?? 0) - 3) < 0.001)

        #expect(abs((slices[0].blendRight?.intensity ?? 0) - 0.7) < 0.001)
        #expect(abs((slices[0].blendRight?.blackLift ?? 0) - 0.08) < 0.001)
        #expect(slices[1].blendLeft?.intensity == nil, "unset intensity stays full depth")
        #expect(abs((slices[1].blendLeft?.blackLift ?? 0) - 0.05) < 0.001,
                "blend compensation folds into the blended edge's lift")
        #expect(!mapped.warnings.contains { $0.contains("intensity") })
    }

    @Test func workspaceMasksImportAndLooksReferenceThem() {

        var shape = RVData_Graphics.Element()
        shape.uuid = uuid("EL-MASK")
        shape.bounds.origin.x = 480
        shape.bounds.origin.y = 270
        shape.bounds.size.width = 960
        shape.bounds.size.height = 540
        shape.opacity = 1
        var fill = RVData_Graphics.Fill()
        fill.fillType = .color({ var c = RVData_Color(); c.alpha = 1; return c }())
        fill.enable = true
        shape.fill = fill
        var slideElement = RVData_Slide.Element()
        slideElement.element = shape

        var mask = RVData_ProMask()
        mask.name = "Center Column"
        var slide = RVData_Slide()
        slide.uuid = uuid("MASK-1")
        slide.size.width = 1920
        slide.size.height = 1080
        slide.elements = [slideElement]
        mask.baseSlide = slide

        var workspace = RVData_ProPresenterWorkspace()
        workspace.masks = [mask]
        var look = RVData_ProAudienceLook()
        look.uuid = uuid("LOOK-1")
        look.name = "Sermon"
        var screenLook = RVData_ProAudienceLook.ProScreenLook()
        screenLook.proScreenUuid = uuid("SCREEN-1")
        screenLook.maskUuid = uuid("MASK-1")
        look.screenLooks = [screenLook]
        workspace.audienceLooks = [look]

        let screens = ProWorkspaceMapper.mapScreens(workspace)
        #expect(screens.plan.masks.count == 1)
        let plan = screens.plan.masks[0]
        #expect(plan.name == "Center Column")
        #expect(plan.proUUID == uuid("MASK-1").string.lowercased())
        #expect(plan.shapes.count == 1)
        #expect(abs(plan.shapes[0].x - 0.25) < 0.001)
        #expect(abs(plan.shapes[0].y - 0.25) < 0.001)
        #expect(abs(plan.shapes[0].width - 0.5) < 0.001)
        #expect(abs(plan.shapes[0].height - 0.5) < 0.001)

        let looks = ProWorkspaceMapper.mapLooks(workspace)
        #expect(looks.looks[0].screenLooks[0].maskProUUID
            == uuid("MASK-1").string.lowercased())
        #expect(!looks.warnings.contains { $0.contains("mask") })
    }

    @Test func timersMapAllThreeModes() {
        var doc = RVData_TimersDocument()
        var countdown = RVData_Timer()
        countdown.uuid = uuid("T-1")
        countdown.name = "Sermon"
        var countdownConfig = RVData_Timer.Configuration.TimerTypeCountdown()
        countdownConfig.duration = 1800
        countdown.configuration.timerType = .countdown(countdownConfig)

        var toTime = RVData_Timer()
        toTime.uuid = uuid("T-2")
        toTime.name = "Until Service"
        var toTimeConfig = RVData_Timer.Configuration.TimerTypeCountdownToTime()
        toTimeConfig.timeOfDay = 9 * 3600 + 30 * 60
        toTimeConfig.period = .pm
        toTime.configuration.timerType = .countdownToTime(toTimeConfig)

        var elapsed = RVData_Timer()
        elapsed.uuid = uuid("T-3")
        elapsed.name = "Stopwatch"
        elapsed.configuration.timerType = .elapsedTime(.init())

        doc.timers = [countdown, toTime, elapsed]
        let plans = ProWorkspaceMapper.mapTimers(doc)
        #expect(plans.count == 3)
        #expect(plans[0].mode == .countdown(seconds: 1800))
        #expect(plans[1].mode == .countdownToTime(hour: 21, minute: 30))
        #expect(plans[2].mode == .countUp(limitSeconds: 0))

        #expect(plans[0].newID != plans[0].proUUID)

        let again = ProWorkspaceMapper.mapTimers(doc, existing: [
            ProTimerSeed(id: "room-sermon", name: "sermon"),
            ProTimerSeed(id: "room-sermon-2", name: "Sermon"),
        ])
        #expect(again[0].newID == "room-sermon")
        #expect(again[1].newID != "room-sermon")
    }

    @Test func communicationDevicesBecomeMIDIDeviceItems() throws {

        func parser(_ xml: String) -> String {
            xml.data(using: .utf16)!.base64EncodedString()
        }
        let json = """
        [
          {"name":"Lyrics MIDI","id":"AC599D7D-D2C6-4CCD-8091-F1245556F8B3","reconnect":true,
           "parser":"\(parser(#"<RVProtocolParserMIDI behavior="2"><RVMIDIHardwareCommunicator sources="Lyrics Strip, Bus 2" destinations="Bus 1"></RVMIDIHardwareCommunicator></RVProtocolParserMIDI>"#))"},
          {"name":"Sender","id":"B","reconnect":false,
           "parser":"\(parser(#"<RVProtocolParserMIDI behavior="2"><RVMIDIHardwareCommunicator sources="" destinations="Desk"></RVMIDIHardwareCommunicator></RVProtocolParserMIDI>"#))"},
          {"name":"DMX","id":"F34372D6","reconnect":true,
           "parser":"\(parser(#"<RVProtocolParserDMX behavior="2"><RVDMXArtnetHardwareCommunicator interface="en0" universe="0"></RVDMXArtnetHardwareCommunicator></RVProtocolParserDMX>"#))"}
        ]
        """
        let mapped = ProWorkspaceMapper.mapCommunicationDevices(Data(json.utf8))
        #expect(mapped.devices.count == 2)

        let lyrics = mapped.devices[0]
        #expect(lyrics.id == "ac599d7d-d2c6-4ccd-8091-f1245556f8b3")
        #expect(lyrics.name == "Lyrics MIDI")
        #expect(lyrics.sourceNames == ["Lyrics Strip", "Bus 2"])
        #expect(lyrics.destinationNames == ["Bus 1"])
        #expect(lyrics.direction == nil)  
        #expect(lyrics.autoReconnect == true)

        let sender = mapped.devices[1]
        #expect(sender.direction == .output)  
        #expect(sender.sourceNames == nil)
        #expect(sender.autoReconnect == nil)

        #expect(mapped.warnings.contains { $0.contains("DMX") })
    }

    @MainActor
    @Test func macroCollectionsBecomeComboBoardFolders() async throws {
        var doc = RVData_MacrosDocument()
        var walkIn = RVData_MacrosDocument.Macro()
        walkIn.uuid = uuid("MACRO-A")
        walkIn.name = "Walk In"
        var clear = RVData_Action.ClearType()
        clear.targetLayer = .all
        var clearAction = RVData_Action()
        clearAction.actionTypeData = .clear(clear)
        walkIn.actions = [clearAction]

        var walkOut = walkIn
        walkOut.uuid = uuid("MACRO-B")
        walkOut.name = "Walk Out"

        var placeholder = RVData_MacrosDocument.Macro()
        placeholder.uuid = uuid("MACRO-C")
        placeholder.name = "Empty"

        doc.macros = [walkIn, walkOut, placeholder]
        var collection = RVData_MacrosDocument.MacroCollection()
        collection.uuid = uuid("COLL-1")
        collection.name = "Service Flow"
        collection.items = [walkIn, walkOut, placeholder].map { macro in
            var item = RVData_MacrosDocument.MacroCollection.Item()
            item.itemType = .macroID(macro.uuid)
            return item
        }
        doc.macroCollections = [collection]

        let show = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let config = show.appendingPathComponent("Configuration", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try (try doc.serializedData()).write(to: config.appendingPathComponent("Macros"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try await Library(rootURL: root)
        let importer = try await ProWorkspaceImporter(client: await started(library))
        _ = await importer.importWorkspace(showDirectory: show)

        let board = try await library.store.load(ControlBoard.self, id: ControlBoard.comboBoardID).value
        let folder = try #require(board.folders.first { $0.name == "Service Flow" })
        #expect(Set(folder.itemIds) == ["macro-a", "macro-b"])

        _ = await importer.importWorkspace(showDirectory: show)
        let again = try await library.store.load(ControlBoard.self, id: ControlBoard.comboBoardID).value
        #expect(again.folders.count == 1)
        #expect(Set(again.folders[0].itemIds) == ["macro-a", "macro-b"])
    }

    @MainActor
    @Test func realWorkspaceSweep() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PRO_IMPORT_WORKSPACE_DIR"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try await Library(rootURL: root)
        let importer = try await ProWorkspaceImporter(client: await started(library))
        let result = await importer.importWorkspace(showDirectory: URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath))

        print("WORKSPACE sweep:")
        print("  presentations: \(result.presentations.filter { $0.presentationID != nil }.count)/\(result.presentations.count)")
        print("  themes: \(result.themesImported)  overlays: \(result.overlaysImported)")
        print("  alerts: \(result.alertsImported)  layouts: \(result.layoutsImported)")
        print("  combos: \(result.combosImported)  timers: \(result.timerPlans.map(\.name))")
        print("  video inputs: \(result.inputPlans.map { "\($0.name) [\($0.kind.rawValue)] \($0.sourceId ?? "unassigned")" })")
        print("  screens: \(result.screenPlan.screens.map { "\($0.name) \($0.width)x\($0.height) \($0.isConfidence ? "confidence" : "audience")" })")
        print("  stage assignments: \(result.screenPlan.stageAssignments)")
        print("  schedules: \(result.schedulesImported)")
        print("  services: \(result.servicesImported)")
        print("  media imported: \(result.mediaImported)")
        for warning in result.warnings { print("  ⚠ \(warning)") }
        #expect(!result.presentations.isEmpty)
    }

    @Test func stageLayoutVisibilityLinksMapToConditions() {
        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-V")
        layout.name = "Stacked Timers"

        var timerCondition = RVData_Slide.Element.DataLink.VisibilityLink.Condition()
        var timerVisibility = RVData_Slide.Element.DataLink.VisibilityLink.Condition.TimerVisibility()
        timerVisibility.timerUuid = uuid("TIMER-1")
        timerVisibility.timerName = "Worship"
        timerVisibility.visibilityCriterion = .isRunning
        timerCondition.conditionType = .timerVisibility(timerVisibility)

        var videoCondition = RVData_Slide.Element.DataLink.VisibilityLink.Condition()
        var videoVisibility = RVData_Slide.Element.DataLink.VisibilityLink.Condition.VideoCountdownVisibility()
        videoVisibility.visibilityCriterion = .hasTimeRemaining
        videoCondition.conditionType = .videoCountdownVisibility(videoVisibility)

        var link = RVData_Slide.Element.DataLink.VisibilityLink()
        link.visibilityCriterion = .any
        link.conditions = [timerCondition, videoCondition]

        var base = RVData_Slide()
        base.elements = [
            textElement(name: "Worship Timer", text: "0:00", dataLink: .visibilityLink(link)),
        ]

        var hidden = textElement(name: "Parked", text: "later")
        hidden.element.hidden = true
        base.elements.append(hidden)
        layout.slide = base
        doc.layouts = [layout]

        let mapped = ProWorkspaceMapper.mapStageLayouts(doc, timerIDsByProUUID: ["timer-1": "mxu-timer-9"])
        let objects = mapped[0].layout.objects
        #expect(objects.count == 2)

        #expect(objects[0].hidden == true)
        let conditioned = objects[1]
        #expect(conditioned.visibilityMatch == .any)
        let conditions = try! #require(conditioned.visibilityConditions)
        #expect(conditions.count == 2)
        #expect(conditions[0].conditionKind == .timer)
        #expect(conditions[0].state == .isRunning)
        #expect(conditions[0].timerId == "mxu-timer-9")
        #expect(conditions[1].conditionKind == .videoCountdown)
        #expect(conditions[1].state == .hasTimeRemaining)
    }

    @Test func danglingTimerVisibilityWarnsAndFollowsPrimary() {
        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-D")
        layout.name = "Stage"

        var condition = RVData_Slide.Element.DataLink.VisibilityLink.Condition()
        var timerVisibility = RVData_Slide.Element.DataLink.VisibilityLink.Condition.TimerVisibility()
        timerVisibility.timerUuid = uuid("TIMER-GONE")
        timerVisibility.timerName = "Deleted Timer"
        condition.conditionType = .timerVisibility(timerVisibility)
        var link = RVData_Slide.Element.DataLink.VisibilityLink()
        link.conditions = [condition]

        var base = RVData_Slide()
        base.elements = [textElement(name: "Box", text: "x", dataLink: .visibilityLink(link))]
        layout.slide = base
        doc.layouts = [layout]

        let mapped = ProWorkspaceMapper.mapStageLayouts(doc)
        let object = mapped[0].layout.objects[0]
        #expect(object.visibilityMatch == nil)  
        #expect(object.visibilityConditions?.first?.timerId == nil)
        #expect(mapped[0].warnings.contains { $0.contains("Deleted Timer") })
    }

    private func liveVideoElement(
        name: String,
        type: RVData_Media.VideoDevice.TypeEnum = .av,
        uniqueID: String,
        deviceName: String = ""
    ) -> RVData_Slide.Element {
        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid(UUID().uuidString)
        graphics.name = name
        graphics.bounds.size.width = 800
        graphics.bounds.size.height = 450
        graphics.opacity = 1
        var media = RVData_Media()
        var live = RVData_Media.LiveVideoTypeProperties()
        live.liveVideo.videoDevice.type = type
        live.liveVideo.videoDevice.uniqueID = uniqueID
        live.liveVideo.videoDevice.name = deviceName
        media.typeProperties = .liveVideo(live)
        var fill = RVData_Graphics.Fill()
        fill.fillType = .media(media)
        graphics.fill = fill
        var element = RVData_Slide.Element()
        element.element = graphics
        return element
    }

    @Test func stageLayoutLiveVideoBoxBindsANamedInput() {
        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-CAM")
        layout.name = "Blank"
        var base = RVData_Slide()
        base.elements = [
            liveVideoElement(name: "Cam", uniqueID: "0x1111", deviceName: "Center Camera")
        ]
        layout.slide = base
        doc.layouts = [layout]

        var book = ProInputPlanBook()
        book.registerWorkspaceInput(
            uuid: "INPUT-1", name: "Center Camera",
            device: {
                var device = RVData_Media.VideoDevice()
                device.type = .av
                device.uniqueID = "0x1111"
                device.name = "Center Camera"
                return device
            }()
        )
        let mapped = ProWorkspaceMapper.mapStageLayouts(doc, inputs: &book)
        let object = mapped[0].layout.objects[0]
        #expect(object.fill?.fillKind == .media)
        #expect(object.fill?.liveInputId == "input-1")
        #expect(object.fill?.mediaId == nil)
        #expect(mapped[0].mediaWants.isEmpty)
        #expect(mapped[0].warnings.isEmpty)

        #expect(book.plans == [ProInputPlan(
            newID: "input-1", name: "Center Camera", kind: .camera, sourceId: "0x1111"
        )])
    }

    @Test func unconfiguredLiveVideoDeviceMintsOnePlanAcrossPhases() {
        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-N")
        var base = RVData_Slide()
        base.elements = [
            liveVideoElement(name: "NDI", type: .ndi, uniqueID: "", deviceName: "BIRDDOG (CAM)")
        ]
        layout.slide = base
        doc.layouts = [layout]

        var book = ProInputPlanBook()
        book.seed([])  
        let mapped = ProWorkspaceMapper.mapStageLayouts(doc, inputs: &book)
        #expect(book.plans.count == 1)
        #expect(book.plans[0].kind == .ndi)
        #expect(book.plans[0].name == "BIRDDOG (CAM)")
        #expect(book.plans[0].sourceId == "BIRDDOG (CAM)")
        #expect(mapped[0].layout.objects[0].fill?.liveInputId == book.plans[0].newID)

        var macros = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-N")
        macro.name = "Cam"
        var media = RVData_Media()
        var live = RVData_Media.LiveVideoTypeProperties()
        live.liveVideo.videoDevice.type = .ndi
        live.liveVideo.videoDevice.name = "BIRDDOG (CAM)"
        media.typeProperties = .liveVideo(live)
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        var fire = RVData_Action()
        fire.actionTypeData = .media(mediaType)
        macro.actions = [fire]
        macros.macros = [macro]

        let combos = ProWorkspaceMapper.mapMacros(macros, inputs: &book)
        #expect(book.plans.count == 1)
        #expect(combos[0].combo.actions[0].liveInputId == book.plans[0].newID)
        #expect(combos[0].warnings.isEmpty)
    }

    @Test func seededInventoryEntryIsReusedInsteadOfPlanned() {
        var book = ProInputPlanBook()
        book.seed([ProInputSeed(id: "existing-1", name: "Center Camera", sourceId: "0x1111")])
        book.registerWorkspaceInput(
            uuid: "INPUT-1", name: "Center Camera",
            device: {
                var device = RVData_Media.VideoDevice()
                device.uniqueID = "0x1111"
                return device
            }()
        )
        #expect(book.plans.isEmpty)
        #expect(book.workspaceInputID(at: 0) == "existing-1")
    }

    @Test func deviceLessVideoInputStepImportsUnassignedWithWarning() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-E")
        macro.name = "test"
        var mediaType = RVData_Action.MediaType()
        var media = RVData_Media()
        media.typeProperties = .liveVideo(RVData_Media.LiveVideoTypeProperties())
        mediaType.element = media
        var fire = RVData_Action()
        fire.actionTypeData = .media(mediaType)
        macro.actions = [fire]
        doc.macros = [macro]

        var book = ProInputPlanBook()
        book.seed([])
        let mapped = ProWorkspaceMapper.mapMacros(doc, inputs: &book)
        #expect(mapped[0].combo.actions[0].liveInputId == book.plans[0].newID)
        #expect(book.plans[0].name == "Video Input")
        #expect(book.plans[0].sourceId == nil)
        #expect(mapped[0].warnings.contains { $0.contains("named no device") })
    }

    @Test func videoInputVisibilityBindsByWorkspaceIndex() {
        var input = RVData_Slide.Element.DataLink.VisibilityLink.Condition.VideoInputVisibility()
        input.videoInputIndex = 0
        input.visibilityCriterion = .active
        var condition = RVData_Slide.Element.DataLink.VisibilityLink.Condition()
        condition.conditionType = .videoInputVisibility(input)
        var link = RVData_Slide.Element.DataLink.VisibilityLink()
        link.conditions = [condition]

        var element = textElement(name: "Cam Tag", text: "LIVE")
        var dataLink = RVData_Slide.Element.DataLink()
        dataLink.propertyType = .visibilityLink(link)
        element.dataLinks = [dataLink]

        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-V")
        var base = RVData_Slide()
        base.elements = [element]
        layout.slide = base
        doc.layouts = [layout]

        var book = ProInputPlanBook()
        book.registerWorkspaceInput(
            uuid: "INPUT-1", name: "Center Camera",
            device: RVData_Media.VideoDevice()
        )
        let mapped = ProWorkspaceMapper.mapStageLayouts(doc, inputs: &book)
        let conditions = try! #require(mapped[0].layout.objects[0].visibilityConditions)
        #expect(conditions[0].conditionKind == .liveInput)
        #expect(conditions[0].liveInputId == "input-1")
        #expect(mapped[0].warnings.isEmpty)
    }

    @Test func playlistItemAndPresentationLinksMapToServiceSources() {
        var current = RVData_Slide.Element.DataLink.PlaylistItem()
        current.playlistItemSource = .current
        var next = RVData_Slide.Element.DataLink.PlaylistItem()
        next.playlistItemSource = .next
        var header = RVData_Slide.Element.DataLink.PlaylistItem()
        header.playlistItemSource = .currentHeader

        var doc = RVData_Stage.Document()
        var layout = RVData_Stage.Layout()
        layout.uuid = uuid("LAYOUT-P")
        var base = RVData_Slide()
        base.elements = [

            textElement(name: "Header", text: "PRAISE SET", dataLink: .playlistItem(header)),
            textElement(name: "Next Item", text: "", dataLink: .playlistItem(next)),
            textElement(name: "Item", text: "", dataLink: .playlistItem(current)),
            textElement(
                name: "Song", text: "",
                dataLink: .presentation(RVData_Slide.Element.DataLink.Presentation())
            ),
        ]
        layout.slide = base
        doc.layouts = [layout]

        let mapped = ProWorkspaceMapper.mapStageLayouts(doc)

        let objects = mapped[0].layout.objects
        #expect(objects[0].textLink?.source == .currentPresentation)
        #expect(objects[1].textLink?.source == .currentServiceItem)
        #expect(objects[2].textLink?.source == .nextServiceItem)

        #expect(objects[3].textLink == nil)
        #expect(mapped[0].warnings.contains { $0.contains("currentHeader") })
    }
}

struct ProLookAndParityTests {

    private func uuid(_ string: String) -> RVData_UUID {
        var id = RVData_UUID()
        id.string = string
        return id
    }

    @Test func looksMapPerScreenLayerEnables() {
        var workspace = RVData_ProPresenterWorkspace()
        var look = RVData_ProAudienceLook()
        look.uuid = uuid("LOOK-1")
        look.name = "No Lyrics"
        var screenLook = RVData_ProAudienceLook.ProScreenLook()
        screenLook.proScreenUuid = uuid("SCREEN-A")
        screenLook.liveVideoEnabled = true
        screenLook.presentationBackgroundEnabled = true
        screenLook.presentationForegroundEnabled = false   
        screenLook.propsLayerEnabled = true
        screenLook.messagesLayerEnabled = true
        screenLook.announcementsEnabled = false
        look.screenLooks = [screenLook]
        workspace.audienceLooks = [look]
        var live = RVData_ProAudienceLook()
        live.originalLookUuid = uuid("LOOK-1")
        workspace.liveAudienceLook = live

        let mapped = ProWorkspaceMapper.mapLooks(workspace)
        #expect(mapped.looks.count == 1)
        #expect(mapped.looks[0].proUUID == "look-1")
        #expect(mapped.liveLookUUID == "look-1")
        let layers = mapped.looks[0].screenLooks[0].enabledLayers

        #expect(layers.contains("videoInput"))
        #expect(layers.contains("loopingVideos"))
        #expect(!layers.contains("stillGraphics"))
        #expect(!layers.contains("slide"))
        #expect(!layers.contains("videos"))
        #expect(layers.contains("overlays"))
        #expect(layers.contains("alerts"))
        #expect(!layers.contains("digitalSignage"))
    }

    @Test func lookAlternateTemplateMapsToItsThemeName() {

        var workspace = RVData_ProPresenterWorkspace()
        var look = RVData_ProAudienceLook()
        look.uuid = uuid("LOOK-T")
        look.name = "Stream"
        var withTemplate = RVData_ProAudienceLook.ProScreenLook()
        withTemplate.proScreenUuid = uuid("SCREEN-A")
        withTemplate.presentationForegroundEnabled = true
        withTemplate.templateDocumentFilePath.absoluteString =
            "file:///Users/anna/Documents/ProPresenter/Themes/Stream%20Lower%20Third/Theme"
        var wysiwyg = RVData_ProAudienceLook.ProScreenLook()
        wysiwyg.proScreenUuid = uuid("SCREEN-B")
        wysiwyg.presentationForegroundEnabled = true
        look.screenLooks = [withTemplate, wysiwyg]
        workspace.audienceLooks = [look]

        let mapped = ProWorkspaceMapper.mapLooks(workspace)

        #expect(mapped.looks[0].screenLooks[0].slideThemeName == "Stream Lower Third")
        #expect(mapped.looks[0].screenLooks[1].slideThemeName == nil)

        var relative = RVData_URL()
        relative.local.path = "Themes/No Bold/Theme"
        #expect(ProWorkspaceMapper.templateThemeName(relative) == "No Bold")
    }

    @Test func lookAnnouncementsLayerDropsWithAWarning() {

        var workspace = RVData_ProPresenterWorkspace()
        var look = RVData_ProAudienceLook()
        look.uuid = uuid("LOOK-A")
        look.name = "Announcements"
        var screenLook = RVData_ProAudienceLook.ProScreenLook()
        screenLook.proScreenUuid = uuid("SCREEN-A")
        screenLook.announcementsEnabled = true
        look.screenLooks = [screenLook]
        workspace.audienceLooks = [look]

        let mapped = ProWorkspaceMapper.mapLooks(workspace)
        #expect(!mapped.looks[0].screenLooks[0].enabledLayers.contains("digitalSignage"))
        #expect(mapped.warnings.contains { $0.contains("announcements") })
    }

    @Test func propAndLookAndInputMacroStepsMapOntoNewActions() {
        var doc = RVData_MacrosDocument()
        var macro = RVData_MacrosDocument.Macro()
        macro.uuid = uuid("MACRO-P")
        macro.name = "Parity"

        var propFire = RVData_Action.PropType()
        propFire.identification.parameterUuid = uuid("PROP-1")
        propFire.triggerType = .trigger(.init())
        var propFireAction = RVData_Action()
        propFireAction.actionTypeData = .prop(propFire)

        var propClear = RVData_Action.PropType()
        propClear.triggerType = .clear(.init())
        var propClearAction = RVData_Action()
        propClearAction.actionTypeData = .prop(propClear)

        var look = RVData_Action.AudienceLookType()
        look.identification.parameterUuid = uuid("LOOK-1")
        var lookAction = RVData_Action()
        lookAction.actionTypeData = .audienceLook(look)

        var media = RVData_Media()
        var live = RVData_Media.LiveVideoTypeProperties()
        live.liveVideo.videoDevice.type = .ndi
        live.liveVideo.videoDevice.uniqueID = "BIRDDOG-04A82 (CAM)"
        media.typeProperties = .liveVideo(live)
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        var inputAction = RVData_Action()
        inputAction.actionTypeData = .media(mediaType)

        var clear = RVData_Action.ClearType()
        clear.targetLayer = .liveVideo
        var clearAction = RVData_Action()
        clearAction.actionTypeData = .clear(clear)

        macro.actions = [propFireAction, propClearAction, lookAction, inputAction, clearAction]
        doc.macros = [macro]

        let mapped = ProWorkspaceMapper.mapMacros(doc)
        let combo = mapped[0].combo
        #expect(combo.actions.map(\.kind) == [.fireOverlay, .dismissOverlay, .switchOutputPreset, .fireLiveInput, .clearLayer])
        #expect(combo.actions[0].overlayId == "prop-1")
        #expect(combo.actions[1].overlayId == nil)   
        #expect(combo.actions[2].presetId == "look-1")
        #expect(combo.actions[3].inputSourceKind == .ndi)
        #expect(combo.actions[3].inputSourceId == "BIRDDOG-04A82 (CAM)")
        #expect(combo.actions[4].layer == "videoInput")
        #expect(mapped[0].warnings.isEmpty)
    }

}
