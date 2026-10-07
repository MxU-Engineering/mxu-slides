import Foundation
import Testing
import PresenterCore
@testable import ProImport

struct ProDocumentMapperTests {

    private func uuid(_ string: String) -> RVData_UUID {
        var id = RVData_UUID()
        id.string = string
        return id
    }

    private func color(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> RVData_Color {
        var c = RVData_Color()
        c.red = r; c.green = g; c.blue = b; c.alpha = a
        return c
    }

    private func textElement(id: String, rtfText: String, fontName: String = "DrukWide-Medium", size: Double = 70) -> RVData_Slide.Element {
        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid(id)
        graphics.name = "Lyric Line"
        graphics.bounds.origin.x = 88
        graphics.bounds.origin.y = 944
        graphics.bounds.size.width = 1744
        graphics.bounds.size.height = 135
        graphics.rotation = 360
        graphics.opacity = 1

        var text = RVData_Graphics.Text()
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;}\\f0\\fs140 \(rtfText)}"
        text.rtfData = Data(rtf.utf8)
        text.verticalAlignment = .middle
        text.attributes.font.name = fontName
        text.attributes.font.size = size
        text.attributes.fill = .textSolidFill(color(1, 1, 1))
        text.attributes.kerning = 2
        text.attributes.paragraphStyle.alignment = .center
        graphics.text = text

        var element = RVData_Slide.Element()
        element.element = graphics
        return element
    }

    private func slideCue(id: String, name: String = "", elements: [RVData_Slide.Element]) -> RVData_Cue {
        var slide = RVData_Slide()
        slide.elements = elements
        slide.size.width = 1920
        slide.size.height = 1080

        var presentationSlide = RVData_PresentationSlide()
        presentationSlide.baseSlide = slide

        var slideType = RVData_Action.SlideType()
        slideType.presentation = presentationSlide

        var action = RVData_Action()
        action.uuid = uuid(UUID().uuidString)
        action.actionTypeData = .slide(slideType)

        var cue = RVData_Cue()
        cue.uuid = uuid(id)
        cue.name = name
        cue.actions = [action]
        return cue
    }

    private func group(_ id: String, _ name: String, cueIDs: [String], color groupColor: RVData_Color?) -> RVData_Presentation.CueGroup {
        var cueGroup = RVData_Presentation.CueGroup()
        cueGroup.group.uuid = uuid(id)
        cueGroup.group.name = name
        if let groupColor { cueGroup.group.color = groupColor }
        cueGroup.cueIdentifiers = cueIDs.map(uuid)
        return cueGroup
    }

    private func songDocument() -> RVData_Presentation {
        var doc = RVData_Presentation()
        doc.uuid = uuid("DOC-1")
        doc.name = "Test Song"
        doc.cues = [
            slideCue(id: "CUE-V1", elements: [textElement(id: "EL-1", rtfText: "Line one")]),
            slideCue(id: "CUE-V2", elements: [textElement(id: "EL-2", rtfText: "Line two")]),
            slideCue(id: "CUE-C1", elements: [textElement(id: "EL-3", rtfText: "Chorus line")]),
        ]
        doc.cueGroups = [
            group("GRP-V", "Verse 1", cueIDs: ["CUE-V1", "CUE-V2"], color: color(0, 0.47, 0.8)),
            group("GRP-C", "Chorus", cueIDs: ["CUE-C1"], color: color(0.8, 0, 0.31)),
        ]
        var arrangement = RVData_Presentation.Arrangement()
        arrangement.uuid = uuid("ARR-1")
        arrangement.name = "Sunday"
        arrangement.groupIdentifiers = [uuid("GRP-V"), uuid("GRP-C"), uuid("GRP-V")]
        doc.arrangements = [arrangement]
        doc.selectedArrangement = uuid("ARR-1")

        doc.ccli.songNumber = 7106807
        doc.ccli.author = "Test Author"
        doc.ccli.publisher = "Test Publisher"
        doc.ccli.copyrightYear = 2018
        return doc
    }

    @Test func groupHotKeysImportAsNormalizedLetters() {
        var doc = songDocument()
        doc.cueGroups[0].group.hotKey.code = .ansiA 
        doc.cueGroups[1].group.hotKey.code = .f1 
        let mapped = ProDocumentMapper.map(doc, fallbackName: "Song")
        #expect(mapped.groupHotKeys == ["verse1": "a"])

        #expect(ProDocumentMapper.map(songDocument(), fallbackName: "Song").groupHotKeys.isEmpty)
    }

    @Test func unnamedGroupsImportNoSectionUnlessArranged() {
        var doc = songDocument()
        doc.cueGroups = [group("GRP-NONE", "", cueIDs: ["CUE-V1", "CUE-V2", "CUE-C1"], color: nil)]
        doc.arrangements = []

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation
        #expect(mapped.sections == nil)
        #expect(mapped.slides.allSatisfy { $0.sectionId == nil })

        #expect(mapped.slides.count == 3)
        #expect(mapped.slides[0].objects[0].text == "Line one")

        var arranged = songDocument()
        arranged.cueGroups = [group("GRP-NONE", "", cueIDs: ["CUE-V1", "CUE-V2", "CUE-C1"], color: nil)]
        var arrangement = RVData_Presentation.Arrangement()
        arrangement.uuid = uuid("ARR-2")
        arrangement.name = "Sunday"
        arrangement.groupIdentifiers = [uuid("GRP-NONE")]
        arranged.arrangements = [arrangement]
        let kept = ProDocumentMapper.map(arranged, fallbackName: "fallback").presentation
        #expect(kept.sections?.count == 1)
    }

    private func chordAttribute(_ symbol: String, start: Int, end: Int) -> RVData_Graphics.Text.Attributes.CustomAttribute {
        var attr = RVData_Graphics.Text.Attributes.CustomAttribute()
        attr.range.start = Int32(start)
        attr.range.end = Int32(end)
        attr.attribute = .chord(symbol)
        return attr
    }

    @Test func chordPlacementsMapRangesToLineAndColumn() {

        var graphics = RVData_Graphics.Element()
        var text = RVData_Graphics.Text()
        text.attributes.customAttributes = [
            chordAttribute("G", start: 0, end: 5),
            chordAttribute("C/E", start: 5, end: 9),
            chordAttribute("Am7", start: 9, end: 14),
            chordAttribute("D", start: 99, end: 99),  
        ]
        graphics.text = text
        let placements = ProDocumentMapper.chordPlacements(graphics, plainText: "Line one\nLine two")
        #expect(placements.map(\.symbol) == ["G", "C/E", "Am7", "D"])
        #expect(placements.map(\.line) == [0, 0, 1, 1])

        #expect(placements.map(\.column) == [0, 5, 0, 8])
    }

    @Test func chordsAndKeysMapThroughTheDocument() {
        var doc = songDocument()
        var element = textElement(id: "EL-1", rtfText: "Line one")
        element.element.text.attributes.customAttributes = [
            chordAttribute("G", start: 0, end: 5),
            chordAttribute("C", start: 5, end: 8),
        ]
        element.element.text.chordPro.enabled = true
        element.element.text.chordPro.notation = .numbers
        element.element.text.chordPro.color = color(1, 0.72, 0.15)
        doc.cues[0] = slideCue(id: "CUE-V1", elements: [element])
        doc.music.original.musicKey = .g
        doc.music.user.musicKey = .a

        let mapped = ProDocumentMapper.map(doc, fallbackName: "X")
        #expect(mapped.presentation.musicKey == "G")
        #expect(mapped.presentation.displayKey == "A")

        let lyric = mapped.presentation.slides[0].objects[0]
        #expect(lyric.chords?.map(\.symbol) == ["G", "C"])
        #expect(lyric.chords?.map(\.column) == [0, 5])

        #expect(lyric.textStyle?.showChords == true)
        #expect(lyric.textStyle?.chordNotation == ChordNotation.numbers)
        #expect(lyric.textStyle?.chordColorHex != nil)
    }

    @Test func chordDataSurvivesWithDisplayOffAndKeysDedupe() {
        var doc = songDocument()
        var element = textElement(id: "EL-1", rtfText: "Line one")
        element.element.text.attributes.customAttributes = [chordAttribute("Em", start: 0, end: 8)]

        doc.cues[0] = slideCue(id: "CUE-V1", elements: [element])
        doc.music.original.musicKey = .dFlat
        doc.music.user.musicKey = .dFlat

        let mapped = ProDocumentMapper.map(doc, fallbackName: "X")
        #expect(mapped.presentation.musicKey == "Db")
        #expect(mapped.presentation.displayKey == nil)  
        let lyric = mapped.presentation.slides[0].objects[0]
        #expect(lyric.chords?.map(\.symbol) == ["Em"])
        #expect(lyric.textStyle?.showChords == nil)
    }

    @Test func legacyStringKeysBackFill() {
        var doc = songDocument()
        doc.music.originalMusicKey = "F#m"
        let mapped = ProDocumentMapper.map(doc, fallbackName: "X")
        #expect(mapped.presentation.musicKey == "F#m")

        var junk = songDocument()
        junk.musicKey = "unknown"
        #expect(ProDocumentMapper.map(junk, fallbackName: "X").presentation.musicKey == nil)
    }

    @Test func goToNextTimerMapsToAutoAdvance() {
        var doc = songDocument()

        doc.cues[0].completionTargetType = .next
        doc.cues[0].completionActionType = .afterTime
        doc.cues[0].completionTime = 7

        doc.cues[1].completionTargetType = .next
        doc.cues[1].completionActionType = .afterAction

        doc.cues[2].completionTargetType = .first
        doc.cues[2].completionActionType = .afterTime
        doc.cues[2].completionTime = 3
        let slides = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides

        #expect(slides[0].autoAdvance == AutoAdvance(delaySeconds: 7))
        #expect(slides[1].autoAdvance == AutoAdvance(delaySeconds: 0, afterPlayback: true))
        #expect(slides[2].autoAdvance == AutoAdvance(delaySeconds: 3, loopToStart: true))
    }

    @Test func documentSlideShowMapsToPresentationAutoAdvance() {
        var doc = songDocument()
        doc.slideShow = .slideShowDuration(5)
        let presentation = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation
        #expect(presentation.autoAdvance == AutoAdvance(delaySeconds: 5, loopToStart: true))
        #expect(presentation.slides.allSatisfy { $0.autoAdvance == nil })
    }

    @Test func timedGoToNextOnVideoCueAnchorsAtVideoEnd() {

        var media = RVData_Media()
        media.uuid = uuid("MEDIA-BUMPER")
        media.url.storage = .absoluteString("file:///Users/test/bumper.mov")
        media.typeProperties = .video(RVData_Media.VideoTypeProperties())
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .foreground
        var action = RVData_Action()
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)
        doc.cues[0].completionTargetType = .next
        doc.cues[0].completionActionType = .afterTime
        doc.cues[0].completionTime = 0

        doc.cues[1].completionTargetType = .next
        doc.cues[1].completionActionType = .afterTime
        doc.cues[1].completionTime = 5

        let slides = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides
        #expect(slides[0].autoAdvance == AutoAdvance(delaySeconds: 0, afterPlayback: true))
        #expect(slides[1].autoAdvance == AutoAdvance(delaySeconds: 5))
    }

    @Test func cueActionsBecomeSlideActions() {
        var doc = songDocument()

        var macroTrigger = RVData_Action.MacroType()
        macroTrigger.identification.parameterUuid = uuid("MACRO-1")
        var macroAction = RVData_Action()
        macroAction.actionTypeData = .macro(macroTrigger)

        var look = RVData_Action.AudienceLookType()
        look.identification.parameterUuid = uuid("LOOK-1")
        var lookAction = RVData_Action()
        lookAction.actionTypeData = .audienceLook(look)

        var timer = RVData_Action.TimerType()
        timer.actionType = .actionStart
        timer.timerIdentification.parameterUuid = uuid("TIMER-1")
        var timerAction = RVData_Action()
        timerAction.actionTypeData = .timer(timer)

        var transition = RVData_Action()
        transition.actionTypeData = .transition(RVData_Action.TransitionType())

        doc.cues[0].actions.append(contentsOf: [macroAction, lookAction, transition])
        doc.cues[1].actions.append(timerAction)

        let slides = ProDocumentMapper.map(
            doc, fallbackName: "fallback", timerIDsByProUUID: ["timer-1": "mxu-timer-9"]
        ).presentation.slides

        let first = try! #require(slides[0].actions)
        #expect(first.map(\.kind) == [.fireCombo, .switchOutputPreset])
        #expect(first[0].comboId == "macro-1")
        #expect(first[1].presetId == "look-1")
        #expect(slides[0].notes?.contains("transition") == true)

        let second = try! #require(slides[1].actions)
        #expect(second.map(\.kind) == [.timerStart])
        #expect(second[0].timerId == "mxu-timer-9")
        #expect(slides[2].actions == nil)
    }

    @Test func midiCueActionsBecomeMIDIOutSlideActions() {
        var doc = songDocument()

        var noteOn = RVData_Action.CommunicationType()
        var midi = RVData_Action.CommunicationType.MIDICommand()
        midi.state = .on
        midi.channel = 1  
        midi.note = 60
        midi.intensity = 100
        noteOn.commandTypeData = .midiCommand(midi)
        var onAction = RVData_Action()
        onAction.actionTypeData = .communication(noteOn)

        var noteOff = noteOn
        if case .midiCommand(var offMIDI) = noteOff.commandTypeData! {
            offMIDI.state = .off
            noteOff.commandTypeData = .midiCommand(offMIDI)
        }
        var offAction = RVData_Action()
        offAction.actionTypeData = .communication(noteOff)

        var sony = RVData_Action.CommunicationType()
        sony.commandTypeData = .sonyBvsCommand(RVData_Action.CommunicationType.SonyBVSCommand())
        var sonyAction = RVData_Action()
        sonyAction.actionTypeData = .communication(sony)

        doc.cues[0].actions.append(contentsOf: [onAction, sonyAction])
        doc.cues[1].actions.append(offAction)

        let slides = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides
        let first = try! #require(slides[0].actions)
        #expect(first.map(\.kind) == [.midiOut])
        #expect(first[0].midiKind == .noteOn)
        #expect(first[0].midiChannel == 2)
        #expect(first[0].midiNumber == 60)
        #expect(first[0].midiValue == 100)
        #expect(slides[0].notes?.contains("device control") == true)

        let second = try! #require(slides[1].actions)
        #expect(second[0].midiValue == 0)  
    }

    @Test func unmappableGoToNextShapesFlattenToNotes() {
        var doc = songDocument()

        doc.cues[0].completionTargetType = .random
        doc.cues[0].completionActionType = .afterTime
        doc.cues[0].completionTime = 5
        let slides = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides
        #expect(slides[0].autoAdvance == nil)
        #expect(slides[0].notes?.contains("go to next timer") == true)
    }

    @Test func mapsGroupsArrangementsAndCCLI() {
        let mapped = ProDocumentMapper.map(songDocument(), fallbackName: "fallback")
        let presentation = mapped.presentation

        #expect(presentation.name == "Test Song")
        #expect(presentation.id == "doc-1")
        #expect(presentation.slides.count == 3)

        #expect(presentation.canvasWidth == nil)

        let sections = try! #require(presentation.sections)
        #expect(sections.map(\.name) == ["Verse 1", "Chorus"])
        #expect(sections[0].colorHex == "#0078CCFF")
        #expect(presentation.slides.map(\.sectionId) == ["grp-v", "grp-v", "grp-c"])

        let arrangement = try! #require(presentation.arrangements?.first)
        #expect(arrangement.name == "Sunday")
        #expect(arrangement.sectionIds == ["grp-v", "grp-c", "grp-v"])
        #expect(presentation.defaultArrangementId == arrangement.id)

        #expect(presentation.ccli?.songNumber == 7106807)
        #expect(presentation.ccli?.author == "Test Author")
        #expect(presentation.ccli?.copyrightYear == 2018)
        #expect(mapped.warnings.isEmpty)
    }

    @Test func groupWithoutColorMapsToNilColorHex() {
        var doc = songDocument()
        var colorless = RVData_Presentation.CueGroup()
        colorless.group.uuid = uuid("GRP-B")
        colorless.group.name = "Bridge"
        colorless.cueIdentifiers = [uuid("CUE-C1")]
        doc.cueGroups = [doc.cueGroups[0], colorless]

        let sections = try! #require(
            ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.sections
        )
        #expect(sections.map(\.colorHex) == ["#0078CCFF", nil])
    }

    @Test func mapsTextStyleFromProtobufAttributesNotRTF() {
        let mapped = ProDocumentMapper.map(songDocument(), fallbackName: "fallback")
        let object = mapped.presentation.slides[0].objects[0]

        #expect(object.objectKind == .text)
        #expect(object.text == "Line one")
        #expect(object.x == 88)
        #expect(object.y == 944)
        #expect(object.width == 1744)
        #expect(object.rotationDegrees == nil)  

        let style = try! #require(object.textStyle)

        #expect(style.fontName == "DrukWide-Medium")
        #expect(style.fontSize == 70)
        #expect(style.colorHex == "#FFFFFFFF")
        #expect(style.tracking == 2)
        #expect(style.horizontalAlignment == .center)
        #expect(style.verticalAlignment == .middle)
    }

    @Test func linesOnlyFillImportsAsTextObjectWithLineFill() {
        var element = textElement(id: "EL-LF", rtfText: "All hail")
        element.element.fill.enable = true
        element.element.fill.fillType = .color(color(0, 0, 0))
        var mask = RVData_Graphics.Text.LineFillMask()
        mask.enabled = true
        mask.maskStyle = .lineWidth
        mask.widthOffset = 8
        mask.verticalOffset = -4
        mask.horizontalOffset = -1
        element.element.mask = .textLineMask(mask)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-LF", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = mapped.presentation.slides[0].objects[0]

        #expect(object.objectKind == .text)
        let lineFill = try! #require(object.textStyle?.lineFill)
        #expect(lineFill.fill.fillKind == .solid)
        #expect(lineFill.fill.colorHex == "#000000FF")
        #expect(lineFill.widthMode == .lineWidth)
        #expect(lineFill.verticalPadding == nil)  
        #expect(lineFill.horizontalPadding == 8)
        #expect(lineFill.verticalOffset == -4)
        #expect(lineFill.horizontalOffset == -1)
    }

    @Test func linesOnlyFillWithEmptyTextDropsElement() {
        var element = textElement(id: "EL-LF-EMPTY", rtfText: " ")
        element.element.fill.enable = true
        element.element.fill.fillType = .color(color(0, 0, 0))
        var mask = RVData_Graphics.Text.LineFillMask()
        mask.enabled = true
        mask.maskStyle = .lineWidth
        element.element.mask = .textLineMask(mask)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-LF-EMPTY", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        #expect(mapped.presentation.slides[0].objects.isEmpty)
    }

    @Test func linesOnlyFillWithEmptyTextKeepsEnabledStroke() {
        var element = textElement(id: "EL-LF-STROKE", rtfText: "")
        element.element.fill.enable = true
        element.element.fill.fillType = .color(color(0, 0, 0))
        element.element.stroke.enable = true
        element.element.stroke.color = color(1, 0, 0)
        element.element.stroke.width = 3
        var mask = RVData_Graphics.Text.LineFillMask()
        mask.enabled = true
        mask.maskStyle = .lineWidth
        element.element.mask = .textLineMask(mask)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-LF-STROKE", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = try! #require(mapped.presentation.slides[0].objects.first)
        #expect(object.fill == nil)
        #expect(object.stroke?.width == 3)
    }

    @Test func dataLinkedElementSurvivesEmptyTextAndNoInk() {
        var element = textElement(id: "EL-VC", rtfText: "")

        element.element.fill.enable = false
        element.element.fill.fillType = .color(color(0.13, 0.59, 0.95))
        var link = RVData_Slide.Element.DataLink()
        link.propertyType = .videoCountdown(RVData_Slide.Element.DataLink.VideoCountdown())
        element.dataLinks = [link]

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-VC", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = try! #require(mapped.presentation.slides[0].objects.first)
        #expect(object.objectKind == .text)
        #expect(object.textLink?.source == .videoCountdown)
        #expect(object.x == 88)  

        #expect(object.textLink?.showsVideoName == false)
    }

    @Test func timerLinkedElementWithTextGainsLinkAndMappedTimerID() {
        var element = textElement(id: "EL-TM", rtfText: "10:00")
        var timerText = RVData_Slide.Element.DataLink.TimerText()
        timerText.timerUuid = uuid("PRO-TIMER-1")
        var link = RVData_Slide.Element.DataLink()
        link.propertyType = .timerText(timerText)
        element.dataLinks = [link]

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-TM", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(
            doc, fallbackName: "fallback",
            timerIDsByProUUID: ["pro-timer-1": "mxu-timer-1"]
        )
        let object = try! #require(mapped.presentation.slides[0].objects.first)
        #expect(object.objectKind == .text)
        #expect(object.text == "10:00")
        #expect(object.textLink?.source == .timer)
        #expect(object.textLink?.timerId == "mxu-timer-1")
    }

    @Test func textMarginsImportAsInsets() {
        var element = textElement(id: "EL-M", rtfText: "Inset line")
        var margins = RVData_Graphics.EdgeInsets()
        margins.left = 20
        margins.top = 10
        margins.bottom = 5
        margins.right = 0
        element.element.text.margins = margins

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-M", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        let style = try! #require(object.textStyle)
        #expect(style.insetLeft == 20)
        #expect(style.insetTop == 10)
        #expect(style.insetBottom == 5)
        #expect(style.insetRight == nil)  
    }

    @Test func paragraphIndentsImportFromProtobufStyle() {
        var element = textElement(id: "EL-I", rtfText: "Indented line")
        element.element.text.attributes.paragraphStyle.firstLineHeadIndent = 10
        element.element.text.attributes.paragraphStyle.headIndent = 60
        element.element.text.attributes.paragraphStyle.tailIndent = -40
        element.element.text.attributes.paragraphStyle.paragraphSpacing = 24

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-I", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        let style = try! #require(object.textStyle)

        #expect(style.firstLineIndent == -50)
        #expect(style.leftIndent == 60)
        #expect(style.rightIndent == 40)
        #expect(style.paragraphSpacing == 24)
    }

    @Test func perParagraphRTFIndentsBecomeLineOverrides() {
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;}\\f0\\fs140 Line one\\par\\li1200\\fi-1200 Line two}"
        var element = textElement(id: "EL-P", rtfText: "ignored")
        element.element.text.rtfData = Data(rtf.utf8)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-P", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        #expect(object.text == "Line one\nLine two")
        let overrides = try! #require(object.textStyle?.lineStyles)
        #expect(overrides.count == 1)
        #expect(overrides[0].lineIndex == 1)
        #expect(overrides[0].leftIndent == 60)
        #expect(overrides[0].firstLineIndent == -60)
        #expect(overrides[0].rightIndent == nil)
    }

    @Test func nearFullBleedObjectsWarnWithoutResizing() {
        var short = textElement(id: "EL-NB", rtfText: "bg")
        short.element.bounds.origin.x = 0
        short.element.bounds.origin.y = 0
        short.element.bounds.size.width = 1919.9
        short.element.bounds.size.height = 1080

        var rotated = textElement(id: "EL-NBR", rtfText: "bg2")
        rotated.element.bounds.origin.x = 420
        rotated.element.bounds.origin.y = -419.9
        rotated.element.bounds.size.width = 1080
        rotated.element.bounds.size.height = 1919.879
        rotated.element.rotation = 90
        var exact = textElement(id: "EL-FB", rtfText: "bg3")
        exact.element.bounds.origin.x = 0
        exact.element.bounds.origin.y = 0
        exact.element.bounds.size.width = 1920
        exact.element.bounds.size.height = 1080

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-NB", elements: [short, rotated, exact])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")

        let bleedWarnings = mapped.warnings.filter { $0.contains("misses the canvas edge") }
        #expect(bleedWarnings.count == 2)
        #expect(bleedWarnings.contains { $0.contains("0.10") })
        #expect(bleedWarnings.contains { $0.contains("0.06") })

        let objects = mapped.presentation.slides[0].objects
        #expect(objects.contains { $0.width == 1919.9 })
        #expect(objects.contains { $0.height == 1919.879 })
    }

    @Test func boxFillWithoutLineMaskStaysShapeHoldingText() {
        var element = textElement(id: "EL-BOX", rtfText: "All hail")
        element.element.fill.enable = true
        element.element.fill.fillType = .color(color(0, 0, 0))

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-BOX", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = mapped.presentation.slides[0].objects[0]

        #expect(object.objectKind == .shape)
        #expect(object.textStyle?.lineFill == nil)
        #expect(object.fill?.fillKind == .solid)
    }

    @Test func slideOrderFollowsGroupsNotStorageOrder() {
        var doc = songDocument()

        doc.cues = [
            slideCue(id: "CUE-V1", elements: [textElement(id: "EL-1", rtfText: "One")]),
            slideCue(id: "CUE-C1", elements: [textElement(id: "EL-3", rtfText: "Chorus")]),
            slideCue(id: "CUE-V2", elements: [textElement(id: "EL-2", rtfText: "Two")]),
        ]
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")

        #expect(mapped.presentation.slides.map(\.id) == ["cue-v1", "cue-v2", "cue-c1"])
        #expect(mapped.presentation.slides.map(\.sectionId) == ["grp-v", "grp-v", "grp-c"])

        #expect(mapped.presentation.sections?.count == 2)
        #expect(mapped.warnings.isEmpty)
    }

    @Test func ungroupedCuesFollowInStorageOrderWithoutSections() {
        var doc = songDocument()
        doc.cues.append(slideCue(id: "CUE-LOOSE", elements: [textElement(id: "EL-9", rtfText: "Loose")]))
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        #expect(mapped.presentation.slides.last?.id == "cue-loose")
        #expect(mapped.presentation.slides.last?.sectionId == nil)
    }

    @Test func cueMediaBecomesSlideBackgroundWithPlaceholder() {
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-1")
        media.url.storage = .absoluteString("file:///Users/test/Media/Assets/loop%20one.mov")
        var local = RVData_URL.LocalRelativePath()
        local.path = "Media/Assets/loop one.mov"
        media.url.relativeFilePath = .local(local)
        var video = RVData_Media.VideoTypeProperties()
        video.transport.playbackBehavior = .loop
        media.typeProperties = .video(video)

        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .background

        var action = RVData_Action()
        action.uuid = uuid(UUID().uuidString)
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let background = try! #require(mapped.presentation.slides[0].background)
        #expect(background.mediaId.hasPrefix(ProDocumentMapper.placeholderPrefix))
        #expect(background.layer == .loopingVideos)
        #expect(background.loops == true)

        let want = try! #require(mapped.mediaWants.first)
        #expect(want.placeholderID == background.mediaId)
        #expect(want.absolutePath == "/Users/test/Media/Assets/loop one.mov")  
        #expect(want.relativePath == "Media/Assets/loop one.mov")
        #expect(want.classification == .background)

        #expect(want.loops == true)
    }

    @Test func playOnceBackgroundVideoStaysOnBackgroundMedia() {

        var media = RVData_Media()
        media.uuid = uuid("MEDIA-PO")
        media.url.storage = .absoluteString("file:///Users/test/Media/Assets/backdrop.mov")
        var video = RVData_Media.VideoTypeProperties()
        video.transport.playbackBehavior = .stop
        media.typeProperties = .video(video)

        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .background

        var action = RVData_Action()
        action.uuid = uuid(UUID().uuidString)
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let background = try! #require(mapped.presentation.slides[0].background)
        #expect(background.layer == .loopingVideos)
        #expect(background.loops == false)
        #expect(mapped.mediaWants.first?.classification == .background)
        #expect(mapped.mediaWants.first?.loops == nil, "play-once matches the import default — no stamp")
    }

    @Test func foregroundStillBecomesFireMediaActionNotBackground() {

        var media = RVData_Media()
        media.uuid = uuid("MEDIA-2")
        media.url.storage = .absoluteString("file:///Users/test/Media/Assets/announce.png")
        media.typeProperties = .image(RVData_Media.ImageTypeProperties())

        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .foreground

        var action = RVData_Action()
        action.uuid = uuid(UUID().uuidString)
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let slide = mapped.presentation.slides[0]
        #expect(slide.background == nil)
        let fire = try! #require(slide.actions?.first { $0.kind == .fireMedia })
        let placeholder = try! #require(fire.mediaId)
        #expect(placeholder.hasPrefix(ProDocumentMapper.placeholderPrefix))

        #expect(mapped.mediaWants.first?.classification == .foreground)

        let resolved = ProDocumentMapper.replacingMediaIDs(
            mapped.presentation, with: [placeholder: "real-id"])
        #expect(resolved.slides[0].actions?.first { $0.kind == .fireMedia }?.mediaId == "real-id")
    }

    @Test func backgroundStillBecomesFireMediaActionWithBackgroundClassification() {

        var media = RVData_Media()
        media.uuid = uuid("MEDIA-3")
        media.url.storage = .absoluteString("file:///Users/test/Media/Assets/backdrop.jpg")
        media.typeProperties = .image(RVData_Media.ImageTypeProperties())

        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .background

        var action = RVData_Action()
        action.uuid = uuid(UUID().uuidString)
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let slide = mapped.presentation.slides[0]
        #expect(slide.background == nil)
        let fire = try! #require(slide.actions?.first { $0.kind == .fireMedia })
        #expect(fire.mediaId?.hasPrefix(ProDocumentMapper.placeholderPrefix) == true)
        #expect(mapped.mediaWants.first?.classification == .background)
    }

    @Test func replacingMediaIDsRewritesAndStripsUnresolved() {
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-1")
        media.url.storage = .absoluteString("file:///missing.mov")

        media.typeProperties = .video(RVData_Media.VideoTypeProperties())
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .background
        var action = RVData_Action()
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)
        doc.cues[1].actions.append(action)  

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        #expect(mapped.mediaWants.count == 1)  
        let placeholder = mapped.mediaWants[0].placeholderID

        let resolved = ProDocumentMapper.replacingMediaIDs(mapped.presentation, with: [placeholder: "real-id"])
        #expect(resolved.slides[0].background?.mediaId == "real-id")
        #expect(resolved.slides[1].background?.mediaId == "real-id")

        let stripped = ProDocumentMapper.replacingMediaIDs(mapped.presentation, with: [:])
        #expect(stripped.slides[0].background == nil)
    }

    @Test func mediaElementBecomesMediaFilledShape() {
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-2")
        media.url.storage = .absoluteString("file:///Users/test/logo.png")
        var image = RVData_Media.ImageTypeProperties()
        image.drawing.scaleBehavior = .fit
        media.typeProperties = .image(image)

        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid("EL-M")
        graphics.bounds.origin.x = 100
        graphics.bounds.origin.y = 100
        graphics.bounds.size.width = 400
        graphics.bounds.size.height = 300
        graphics.opacity = 1
        graphics.fill.fillType = .media(media)
        var element = RVData_Slide.Element()
        element.element = graphics

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = mapped.presentation.slides[0].objects[0]

        #expect(object.objectKind == .shape)
        #expect(object.fill?.fillKind == .media)
        #expect(object.fill?.mediaId?.hasPrefix(ProDocumentMapper.placeholderPrefix) == true)
        #expect(object.fill?.mediaScaleMode == .fit)
        #expect(object.width == 400)
    }

    @Test func liveVideoElementBecomesDirectDeviceFill() {
        var media = RVData_Media()
        var live = RVData_Media.LiveVideoTypeProperties()
        live.liveVideo.videoDevice.type = .av
        live.liveVideo.videoDevice.uniqueID = "0xCAFE"
        live.liveVideo.videoDevice.name = "Center Camera"
        media.typeProperties = .liveVideo(live)

        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid("EL-LIVE")
        graphics.bounds.size.width = 800
        graphics.bounds.size.height = 450
        graphics.opacity = 1
        graphics.fill.fillType = .media(media)
        var element = RVData_Slide.Element()
        element.element = graphics

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.objectKind == .shape)
        #expect(object.fill?.fillKind == .media)

        #expect(object.fill?.mediaId == nil)
        #expect(mapped.mediaWants.isEmpty)
        #expect(object.fill?.captureSourceKind == .camera)
        #expect(object.fill?.captureSourceId == "0xCAFE")
    }

    @Test func rotationSignFlipsToClockwise() {

        var element = RVData_Graphics.Element()
        element.uuid = uuid("EL-ROT")
        element.bounds.size.width = 100
        element.bounds.size.height = 100
        element.rotation = 7
        element.opacity = 1
        element.fill.fillType = .color(color(1, 0, 0))
        element.fill.enable = true
        var slideElement = RVData_Slide.Element()
        slideElement.element = element

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [slideElement])]
        doc.cueGroups = []
        doc.arrangements = []

        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]
        #expect(object.rotationDegrees == -7)
    }

    @Test func powerPointOpacityScaleNormalizes() {

        var full = RVData_Graphics.Element()
        full.uuid = uuid("EL-O1")
        full.bounds.size.width = 100
        full.bounds.size.height = 100
        full.opacity = 100
        full.fill.fillType = .color(color(1, 0, 0))
        full.fill.enable = true

        var half = full
        half.uuid = uuid("EL-O2")
        half.opacity = 50

        var native = full
        native.uuid = uuid("EL-O3")
        native.opacity = 0.4

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [full, half, native].map { graphics in
            var element = RVData_Slide.Element()
            element.element = graphics
            return element
        })]
        doc.cueGroups = []
        doc.arrangements = []

        let objects = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects
        let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        #expect(byID["el-o1"]?.opacity == nil)  
        #expect(byID["el-o2"]?.opacity == 0.5)
        #expect(byID["el-o3"]?.opacity == 0.4)
    }

    @Test func invisibleOnlyTextKeepsShapeAndStroke() {

        var element = textElement(id: "EL-Z", rtfText: "\\uc0\\u8203 ")
        element.element.stroke.enable = true
        element.element.stroke.width = 3
        element.element.stroke.color = color(1, 1, 1)

        let decoded = NSAttributedString(
            rtf: element.element.text.rtfData, documentAttributes: nil
        )?.string
        #expect(decoded == "\u{200B}")

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []

        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]
        #expect(object.objectKind == .shape)
        #expect(object.text == "")
        #expect(object.stroke == ObjectStroke(colorHex: "#FFFFFFFF", width: 3))
    }

    @Test func cropInsetsImportAsMediaSourceRect() {

        var media = RVData_Media()
        media.uuid = uuid("MEDIA-C")
        media.url.storage = .absoluteString("file:///Users/test/scan.png")
        var image = RVData_Media.ImageTypeProperties()
        image.drawing.scaleBehavior = .stretch
        image.drawing.naturalSize.width = 1000
        image.drawing.naturalSize.height = 500
        image.drawing.cropEnable = true
        image.drawing.cropInsets.left = 100
        image.drawing.cropInsets.top = 50
        image.drawing.cropInsets.right = 400
        image.drawing.cropInsets.bottom = 200
        media.typeProperties = .image(image)

        var rectangle = RVData_Graphics.Element()
        rectangle.uuid = uuid("EL-C1")
        rectangle.bounds.size.width = 400
        rectangle.bounds.size.height = 300
        rectangle.opacity = 1
        rectangle.fill.fillType = .media(media)

        var freeform = RVData_Graphics.Element()
        freeform.uuid = uuid("EL-C2")
        freeform.bounds.size.width = 300
        freeform.bounds.size.height = 300
        freeform.opacity = 1
        freeform.path.closed = true
        freeform.path.shape.type = .custom
        freeform.path.points = [(0.5, 0.0), (1.0, 1.0), (0.0, 1.0)].map { x, y in
            var point = RVData_Graphics.Path.BezierPoint()
            point.point.x = x; point.point.y = y
            point.q0 = point.point; point.q1 = point.point
            return point
        }
        freeform.fill.fillType = .media(media)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [rectangle, freeform].map { graphics in
            var element = RVData_Slide.Element()
            element.element = graphics
            return element
        })]
        doc.cueGroups = []
        doc.arrangements = []

        let expected = MediaSourceRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let objects = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects
        let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        #expect(byID["el-c1"]?.objectKind == .shape)
        #expect(byID["el-c1"]?.fill?.mediaSourceRect == expected)
        #expect(byID["el-c2"]?.objectKind == .shape)
        #expect(byID["el-c2"]?.fill?.mediaSourceRect == expected)

        var uncropped = media
        var plain = RVData_Media.ImageTypeProperties()
        plain.drawing.scaleBehavior = .stretch
        uncropped.typeProperties = .image(plain)
        #expect(ProDocumentMapper.mediaSourceRect(of: uncropped) == nil)

        var outset = media
        var outsetImage = RVData_Media.ImageTypeProperties()
        outsetImage.drawing.naturalSize.width = 100
        outsetImage.drawing.naturalSize.height = 100
        outsetImage.drawing.cropEnable = true
        outsetImage.drawing.cropInsets.left = 10
        outsetImage.drawing.cropInsets.top = -20
        outsetImage.drawing.cropInsets.right = 40
        outsetImage.drawing.cropInsets.bottom = 30
        outset.typeProperties = .image(outsetImage)
        #expect(ProDocumentMapper.mediaSourceRect(of: outset)
            == MediaSourceRect(x: 0.1, y: -0.2, width: 0.5, height: 0.9))
    }

    @Test func roundedRectangleAndBezierPathsMap() {
        var rounded = RVData_Graphics.Element()
        rounded.uuid = uuid("EL-R")
        rounded.bounds.size.width = 200
        rounded.bounds.size.height = 200
        rounded.opacity = 1
        rounded.path.closed = true
        rounded.path.shape.type = .rectangle
        var rr = RVData_Graphics.Path.Shape.RoundedRectangle()
        rr.roundness = 24
        rounded.path.shape.additionalData = .roundedRectangle(rr)
        rounded.fill.fillType = .color(color(1, 0, 0))
        rounded.fill.enable = true

        var custom = RVData_Graphics.Element()
        custom.uuid = uuid("EL-P")
        custom.bounds.size.width = 300
        custom.bounds.size.height = 300
        custom.opacity = 1
        custom.path.closed = true
        custom.path.shape.type = .custom
        custom.path.points = [(0.5, 0.0), (1.0, 1.0), (0.0, 1.0)].map { x, y in
            var point = RVData_Graphics.Path.BezierPoint()
            point.point.x = x; point.point.y = y
            point.q0 = point.point; point.q1 = point.point
            return point
        }
        custom.fill.fillType = .color(color(0, 0, 1))
        custom.fill.enable = true

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-1", elements: [
            { var e = RVData_Slide.Element(); e.element = rounded; return e }(),
            { var e = RVData_Slide.Element(); e.element = custom; return e }(),
        ])]
        doc.cueGroups = []
        doc.arrangements = []

        let objects = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects
        #expect(objects[1].shapeKind == .roundedRectangle)
        #expect(objects[1].cornerRadius == 24)
        #expect(objects[1].fill?.fillKind == .solid)
        #expect(objects[1].fill?.colorHex == "#FF0000FF")

        #expect(objects[0].shapeKind == .path)
        let path = try! #require(objects[0].pathData)
        #expect(path.hasPrefix("M 0.5000 0.0000"))
        #expect(path.hasSuffix("Z"))
    }

    @Test func elementOrderReversesSoTextStaysAboveMedia() {
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-1")
        media.typeProperties = .image(RVData_Media.ImageTypeProperties())

        var band = RVData_Graphics.Element()
        band.uuid = uuid("EL-BAND")
        band.bounds.size.width = 1920
        band.bounds.size.height = 1080
        band.opacity = 1
        band.fill.fillType = .media(media)

        var doc = songDocument()

        doc.cues = [slideCue(id: "CUE-1", elements: [
            textElement(id: "EL-TEXT", rtfText: "Chris Lindberg"),
            { var e = RVData_Slide.Element(); e.element = band; return e }(),
        ])]
        doc.cueGroups = []
        doc.arrangements = []

        let objects = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects
        #expect(objects.count == 2)
        #expect(objects[0].fill?.fillKind == .media)
        #expect(objects[1].objectKind == .text)
        #expect(objects[1].text == "Chris Lindberg")
    }

    @Test func flattenedActionsLandInSlideNotes() {
        var doc = songDocument()
        var buildAction = RVData_Action()
        buildAction.uuid = uuid(UUID().uuidString)
        buildAction.label.text = "Move In"

        buildAction.actionTypeData = .transition(RVData_Action.TransitionType())
        doc.cues[0].actions.append(buildAction)

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let notes = try! #require(mapped.presentation.slides[0].notes)
        #expect(notes.contains("Move In"))
    }

    @Test func decodeRoundTripThroughSerializedBytes() throws {
        let data = try songDocument().serializedData()
        let decoded = try RVData_Presentation(serializedBytes: data)
        #expect(decoded.name == "Test Song")
        let mapped = ProDocumentMapper.map(decoded, fallbackName: "fallback")
        #expect(mapped.presentation.slides.count == 3)
    }

    private func rvTransition(_ name: String, duration: Double) -> RVData_Transition {
        var transition = RVData_Transition()
        transition.duration = duration
        transition.effect.name = name
        return transition
    }

    @Test func slideTransitionsImportWithDocFallback() {
        var doc = songDocument()
        doc.transition = rvTransition("Dissolve", duration: 0.8)
        if case .slide(var slideType)? = doc.cues[1].actions[0].actionTypeData {
            slideType.presentation.transition = rvTransition("Move In", duration: 1.2)
            doc.cues[1].actions[0].actionTypeData = .slide(slideType)
        }

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let slides = mapped.presentation.slides
        #expect(slides[0].transition == Transition(transitionKind: .dissolve, durationSeconds: 0.8))

        #expect(slides[1].transition == Transition(transitionKind: .dissolve, durationSeconds: 1.2))
        #expect(mapped.warnings.contains { $0.contains("Move In") })
        #expect(slides[2].transition == Transition(transitionKind: .dissolve, durationSeconds: 0.8))
    }

    @Test func transitionNameFamiliesMap() {
        var state = ProDocumentMapper.MapState()
        #expect(ProDocumentMapper.transition(from: rvTransition("Fade", duration: 1), state: &state)
            == Transition(transitionKind: .fadeBlack, durationSeconds: 1))
        #expect(ProDocumentMapper.transition(from: rvTransition("Blur Dissolve", duration: 2), state: &state)
            == Transition(transitionKind: .blurDissolve, durationSeconds: 2))
        #expect(ProDocumentMapper.transition(from: rvTransition("None", duration: 0.5), state: &state)
            == Transition(transitionKind: .cut))
        #expect(ProDocumentMapper.transition(from: RVData_Transition(), state: &state) == nil)
    }

    @Test func documentBackgroundImportsAsBackgroundFill() {
        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-BG", elements: [textElement(id: "EL", rtfText: "hi")])]
        doc.cueGroups = []
        doc.arrangements = []
        doc.background.isEnabled = true
        doc.background.fill = .color(color(0, 0, 0, 1))
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        #expect(mapped.presentation.backgroundFill == ObjectFill(fillKind: .solid, colorHex: "#000000FF"))

        doc.background.isEnabled = false
        let disabled = ProDocumentMapper.map(doc, fallbackName: "fallback")
        #expect(disabled.presentation.backgroundFill == nil)
    }

    @Test func underlineRunsImportAsStyleRuns() {
        var element = textElement(id: "EL-U", rtfText: "")
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;}\\f0\\fs140 Gracious {\\ul words} heal\\par softly}"
        element.element.text.rtfData = Data(rtf.utf8)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-U", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        let runs = try! #require(object.styleRuns)
        #expect(runs.count == 1)
        #expect(runs[0].line == 0)
        #expect(runs[0].column == 9)
        #expect(runs[0].length == 5)
        #expect(runs[0].underline == true)
        #expect(runs[0].strikethrough == nil)

        #expect(object.textStyle?.underline == nil)
    }

    @Test func midLineFontSizeAndColorImportAsStyleRuns() {
        var element = textElement(id: "EL-M", rtfText: "")
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;\\f1\\fnil\\fcharset0 Helvetica-Bold;}"
            + "{\\colortbl;\\red255\\green0\\blue0;}"
            + "\\f0\\fs140 Amazing {\\f1\\fs200 grace} how {\\cf1 sweet}}"
        element.element.text.rtfData = Data(rtf.utf8)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-M", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        let runs = try! #require(object.styleRuns)
        let bold = try! #require(runs.first { $0.fontName != nil })
        #expect(bold.line == 0)
        #expect(bold.column == 8)
        #expect(bold.length == 5)
        #expect(bold.fontName == "Helvetica-Bold")
        #expect(bold.fontSize == 100)  
        let colored = try! #require(runs.first { $0.colorHex != nil })
        #expect(colored.column == 18)
        #expect(colored.length == 5)

        #expect(colored.colorHex == "#FF2600FF")

        #expect(runs.allSatisfy { $0.column > 0 })
    }

    @Test func invisibleSpacerRunsEmitNoStyleRuns() {
        var element = textElement(id: "EL-Z", rtfText: "")
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;\\f1\\fnil\\fcharset0 Helvetica-Bold;}"
            + "\\f0\\fs140 Amazing{\\f1 \\u8203 ?}grace}"
        element.element.text.rtfData = Data(rtf.utf8)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-Z", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]
        #expect(object.styleRuns?.allSatisfy { $0.fontName == nil } != false)
    }

    @Test func protobufUnderlineBecomesBaseStyle() {
        var element = textElement(id: "EL-BU", rtfText: "All of it")
        element.element.text.attributes.underlineStyle.style = .single
        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-BU", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]
        #expect(object.textStyle?.underline == true)
    }

    @Test func perLineFontNamesCarryWithRTFGuard() {
        var element = textElement(id: "EL-F", rtfText: "")
        let boldLine = "{\\rtf1\\ansi{\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;\\f1\\fnil\\fcharset0 Helvetica-Bold;}\\f1\\fs140 TITLE LINE\\par\\f0 body line}"
        element.element.text.rtfData = Data(boldLine.utf8)

        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-F", elements: [element])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        let lines = try! #require(object.textStyle?.lineStyles)

        #expect(lines.first { $0.lineIndex == 0 }?.fontName == "Helvetica-Bold")
    }

    private func mediaElement(id: String, configure: (inout RVData_Media.DrawingProperties) -> Void) -> RVData_Slide.Element {
        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid(id)
        graphics.name = "Picture"
        graphics.bounds.size.width = 1920
        graphics.bounds.size.height = 1080
        graphics.opacity = 1
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-\(id)")
        media.url.storage = .absoluteString("file:///Users/test/picture.jpg")
        var image = RVData_Media.ImageTypeProperties()
        var drawing = RVData_Media.DrawingProperties()
        drawing.scaleBehavior = .fill
        configure(&drawing)
        image.drawing = drawing
        media.typeProperties = .image(image)
        graphics.fill.fillType = .media(media)
        var element = RVData_Slide.Element()
        element.element = graphics
        return element
    }

    @Test func mediaFlipsImportOntoTheObject() {
        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-FL", elements: [mediaElement(id: "EL-FL") {
            $0.flippedHorizontally = true
            $0.flippedVertically = true
        }])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]
        #expect(object.objectKind == .shape)
        #expect(object.fill?.fillKind == .media)
        #expect(object.flipHorizontal == true)
        #expect(object.flipVertical == true)
    }

    @Test func customImageBoundsImportAsSourceRect() {
        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-PZ", elements: [mediaElement(id: "EL-PZ") {
            $0.scaleBehavior = .custom
            $0.customImageBounds.origin.x = 0
            $0.customImageBounds.origin.y = -183.6
            $0.customImageBounds.size.width = 1920
            $0.customImageBounds.size.height = 1447.2
        }])]
        doc.cueGroups = []
        doc.arrangements = []
        let object = ProDocumentMapper.map(doc, fallbackName: "fallback").presentation.slides[0].objects[0]

        let rect = try! #require(object.fill?.mediaSourceRect)
        #expect(abs(rect.x - 0) < 0.0001)
        #expect(abs(rect.y - 183.6 / 1447.2) < 0.0001)
        #expect(abs(rect.width - 1) < 0.0001)
        #expect(abs(rect.height - 1080 / 1447.2) < 0.0001)
        #expect(object.fill?.mediaScaleMode == .stretch)
    }

    @Test func mediaEffectsMapAdjustColorAndAlphaWarnOthers() {
        func effect(_ name: String, _ variables: [(String, Double)]) -> RVData_Effect {
            var effect = RVData_Effect()
            effect.enabled = true
            effect.name = name
            effect.variables = variables.map { name, value in
                var variable = RVData_Effect.EffectVariable()
                variable.name = name
                var double = RVData_Effect.EffectVariable.EffectDouble()
                double.value = value
                variable.type = .double(double)
                return variable
            }
            return effect
        }
        var doc = songDocument()
        doc.cues = [slideCue(id: "CUE-FX", elements: [mediaElement(id: "EL-FX") {
            $0.effects = [
                effect("Adjust Color", [("hue", 0), ("saturation", 1.4), ("brightness", 0.1), ("contrast", 1.3)]),
                effect("Adjust Alpha", [("amount", 0.5)]),
                effect("Tile", [("cells", 15)]),
            ]
        }])]
        doc.cueGroups = []
        doc.arrangements = []
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let object = mapped.presentation.slides[0].objects[0]

        let effects = try! #require(object.effects)
        #expect(effects.count == 1)
        #expect(effects[0].effectKind == .colorAdjust)
        #expect(effects[0].saturation == 1.4)
        #expect(abs((effects[0].brightness ?? 0) - 0.1) < 0.0001)

        #expect(abs((effects[0].contrast ?? 0) - 0.3) < 0.0001)

        #expect(abs((object.opacity ?? 1) - 0.5) < 0.0001)
        #expect(mapped.warnings.contains { $0.contains("Tile") })
    }

    @Test func videoTransportRidesTheWant() {
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-TRIM")
        media.url.storage = .absoluteString("file:///Users/test/bumper.mov")
        var video = RVData_Media.VideoTypeProperties()
        var transport = RVData_Media.TransportProperties()
        transport.inPoint = 2.5
        transport.outPoint = 40
        transport.shouldFadeIn = true
        transport.fadeInDuration = 1.5
        video.transport = transport
        media.typeProperties = .video(video)
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        mediaType.layerType = .foreground
        var action = RVData_Action()
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")

        let want = try! #require(mapped.mediaWants.first { $0.absolutePath?.contains("bumper") == true })
        #expect(want.inPoint == 2.5)
        #expect(want.outPoint == 40)
        #expect(want.playRate == nil)
        #expect(want.fadeSeconds == 1.5)
    }

    @Test func audioCueBecomesFireAudioAction() {
        var media = RVData_Media()
        media.uuid = uuid("MEDIA-SFX")
        media.url.storage = .absoluteString("file:///Users/test/stinger.wav")
        var audio = RVData_Media.AudioTypeProperties()
        var transport = RVData_Media.TransportProperties()
        transport.playbackBehavior = .loop
        audio.transport = transport
        media.typeProperties = .audio(audio)
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        var action = RVData_Action()
        action.actionTypeData = .media(mediaType)

        var doc = songDocument()
        doc.cues[0].actions.append(action)
        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let slide = mapped.presentation.slides[0]

        #expect(slide.background == nil)
        let actions = try! #require(slide.actions)
        #expect(actions.count == 1)
        #expect(actions[0].kind == .fireAudio)
        #expect(actions[0].audioRepeat == true)
        let placeholder = try! #require(actions[0].audioItemId)
        #expect(placeholder.hasPrefix(ProDocumentMapper.placeholderPrefix))

        let resolved = ProDocumentMapper.replacingMediaIDs(
            mapped.presentation, with: [placeholder: "audio-77"])
        #expect(resolved.slides[0].actions?[0].audioItemId == "audio-77")
        let dropped = ProDocumentMapper.replacingMediaIDs(mapped.presentation, with: [:])
        #expect(dropped.slides[0].actions == nil)
    }

    @Test func elementBuildsImportAsSteps() {
        func transition(_ name: String, _ duration: Double) -> RVData_Transition {
            var t = RVData_Transition()
            t.duration = duration
            t.effect.name = name
            return t
        }
        var title = textElement(id: "EL-T", rtfText: "Title")
        title.buildIn.uuid = uuid("B-T-IN")
        title.buildIn.start = .withSlide
        title.buildIn.transition = transition("Fly In From Left", 0.8)
        title.buildOut.uuid = uuid("B-T-OUT")
        title.buildOut.start = .onClick
        title.buildOut.transition = transition("Zoom Out", 0.4)

        var points = textElement(id: "EL-P", rtfText: "One\\\nTwo\\\nThree")
        points.buildIn.uuid = uuid("B-P-IN")
        points.buildIn.transition = transition("Dissolve", 0.5)
        points.revealType = .underline
        points.childBuilds = (0..<3).map { index in
            var child = RVData_Slide.Element.ChildBuild()
            child.uuid = uuid("B-P-\(index)")
            child.index = UInt32(index)
            child.start = index == 0 ? .onClick : .afterPrevious
            child.delayTime = index == 0 ? 0 : 0.25
            return child
        }
        var odd = textElement(id: "EL-O", rtfText: "Odd")
        odd.buildIn.uuid = uuid("B-O-IN")
        odd.buildIn.transition = transition("Origami Fold", 1)

        var cue = slideCue(id: "CUE-B", elements: [title, points, odd])

        var action = cue.actions[0]
        if case .slide(var slideType) = action.actionTypeData {
            slideType.presentation.baseSlide.elementBuildOrder = [uuid("EL-P"), uuid("EL-T")]
            action.actionTypeData = .slide(slideType)
        }
        cue.actions = [action]
        var doc = RVData_Presentation()
        doc.uuid = uuid("DOC-B")
        doc.name = "Builds"
        doc.cues = [cue]

        let mapped = ProDocumentMapper.map(doc, fallbackName: "fallback")
        let slide = mapped.presentation.slides[0]
        let byID = Dictionary(uniqueKeysWithValues: slide.objects.map { ($0.id, $0) })

        let t = try! #require(byID["el-t"]?.animationSteps)
        #expect(t.map(\.kind) == [.in, .out])
        #expect(t[0].animation == .move && t[0].edge == .left && t[0].trigger == .withPrevious && t[0].durationSeconds == 0.8)
        #expect(t[1].animation == .scale && t[1].trigger == .onClick && t[1].id == "b-t-out")

        let p = try! #require(byID["el-p"]?.animationSteps)
        #expect(p.count == 3)
        #expect(p.map { $0.ranges?.first?.line } == [0, 1, 2])
        #expect(p[1].trigger == .afterPrevious && p[1].delaySeconds == 0.25 && p[0].trigger == .onClick)
        #expect(p.allSatisfy { $0.animation == .fade && $0.placeholderUnderline == true })

        let o = try! #require(byID["el-o"]?.animationSteps)
        #expect(o[0].animation == .fade)
        #expect(slide.notes?.contains("Origami Fold") == true)
        #expect(mapped.warnings.contains { $0.contains("Origami Fold") })

        var noisy = textElement(id: "EL-N", rtfText: "Noise")
        noisy.buildIn.uuid = uuid("B-N-IN")
        noisy.buildIn.transition = transition("Dissolve", 0.6000000238418579)
        noisy.buildIn.delayTime = 2.7755575615628914e-17
        var noisyCue = slideCue(id: "CUE-N", elements: [noisy])
        var noisyDoc = RVData_Presentation()
        noisyDoc.uuid = uuid("DOC-N"); noisyDoc.name = "N"; noisyDoc.cues = [noisyCue]
        let noisyStep = ProDocumentMapper.map(noisyDoc, fallbackName: "N").presentation.slides[0].objects[0].animationSteps![0]
        #expect(noisyStep.durationSeconds == 0.6)
        #expect(noisyStep.delaySeconds == nil)
        _ = noisyCue

        #expect(slide.animationOrder == ["b-p-0", "b-p-1", "b-p-2", "b-t-in", "b-t-out", "b-o-in"])

        #expect(slide.objects.allSatisfy { object in
            (object.animationSteps ?? []).allSatisfy { $0.trigger != .onDismiss }
        }, "Pro7 slide imports never author exit-group (onDismiss) steps")
    }

    @Test func buildUuidOrderAndRevealOutsMatchPro() {
        func transition(_ name: String, _ duration: Double) -> RVData_Transition {
            var t = RVData_Transition()
            t.duration = duration
            t.effect.name = name
            return t
        }
        func element(_ id: String, _ text: String, inID: String, outID: String, inStart: RVData_Slide.Element.Build.Start) -> RVData_Slide.Element {
            var e = textElement(id: id, rtfText: text)
            e.buildIn.uuid = uuid(inID)
            e.buildIn.start = inStart

            var moveIn = transition("Move In", 0.6)
            var direction = RVData_Effect.EffectVariable()
            direction.name = "Direction"
            var payload = RVData_Effect.EffectVariable.EffectDirection()
            payload.direction = .right
            direction.type = .direction(payload)
            moveIn.effect.variables = [direction]
            e.buildIn.transition = moveIn
            e.buildOut.uuid = uuid(outID)
            e.buildOut.start = outID == "B-T-OUT" ? .onClick : .withPrevious
            e.buildOut.transition = transition("Reveal", 0.6)
            return e
        }
        let plate = element("EL-PL", "Plate", inID: "B-PL-IN", outID: "B-PL-OUT", inStart: .withSlide)
        let title = element("EL-T", "Title", inID: "B-T-IN", outID: "B-T-OUT", inStart: .withPrevious)
        let name = element("EL-N", "Name", inID: "B-N-IN", outID: "B-N-OUT", inStart: .withPrevious)
        var cue = slideCue(id: "CUE-R", elements: [plate, title, name])
        var action = cue.actions[0]
        if case .slide(var slideType) = action.actionTypeData {
            slideType.presentation.baseSlide.elementBuildOrder =
                ["B-PL-IN", "B-T-IN", "B-N-IN", "B-T-OUT", "B-N-OUT", "B-PL-OUT"].map(uuid)
            action.actionTypeData = .slide(slideType)
        }
        cue.actions = [action]
        var doc = RVData_Presentation()
        doc.uuid = uuid("DOC-R"); doc.name = "R"; doc.cues = [cue]

        let slide = ProDocumentMapper.map(doc, fallbackName: "R").presentation.slides[0]
        #expect(slide.animationOrder == ["b-pl-in", "b-t-in", "b-n-in", "b-t-out", "b-n-out", "b-pl-out"],
                "Pro's interleaved build order survives verbatim")
        let byID = Dictionary(uniqueKeysWithValues: slide.objects.flatMap { ($0.animationSteps ?? []).map { step in (step.id, step) } })
        #expect(byID["b-t-out"]?.trigger == .onClick, "the outs are their own click, never glued to the fire group")
        #expect(byID["b-n-out"]?.trigger == .withPrevious && byID["b-pl-out"]?.trigger == .withPrevious)

        for id in ["b-pl-in", "b-t-in", "b-n-in"] {
            #expect(byID[id]?.edge == nil && byID[id]?.offsetX == 1832, Comment(rawValue: id))
        }
        for id in ["b-t-out", "b-n-out", "b-pl-out"] {
            #expect(byID[id]?.animation == .move, "Reveal out = move out")
            #expect(byID[id]?.edge == nil && byID[id]?.offsetX == 1832, "outs share the rigid vector too")
        }
    }
}
