import Foundation
import Testing
@testable import PresenterCore

struct AnimationPresetTests {
    @Test func recommendedCatalogIsWellFormed() {
        let all = AnimationPreset.recommended
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count, "ids unique")
        for preset in all {
            #expect(preset.id.hasPrefix("builtin."), Comment(rawValue: preset.name))

            #expect(!preset.steps.isEmpty || preset.scroll != nil, Comment(rawValue: preset.name))
            #expect(preset.steps.allSatisfy { $0.ranges == nil && $0.durationSeconds > 0 }, Comment(rawValue: preset.name))
        }
        let names = AnimationPreset.recommendedGroups.map(\.name)
        for expected in ["Settle", "Float", "Slide", "Bar Wipe", "Line Draw", "Pill Grow", "Bracket Pop",
                         "Blur Resolve", "Burn", "Glitch", "Type", "Roll", "Crawl"] {
            #expect(names.contains(expected), Comment(rawValue: expected))
        }
    }

    @Test func applyReplacesAddAppendsAndFollowersStagger() throws {
        let preset = try #require(AnimationPreset.recommended.first { $0.id == "builtin.settle.both" })
        let existing = [AnimationStep(id: "old", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)]
        var counter = 0
        func id() -> String { counter += 1; return "s\(counter)" }

        let leader = AnimationPresetApplication.apply(preset, to: existing, mode: .replace, position: 0, makeID: id)
        #expect(leader.animationSteps?.map(\.id) == ["s1", "s2"], "replace drops the old step; fresh ids")
        #expect(leader.animationSteps?[0].trigger == .onClick && leader.animationSteps?[1].trigger == .onDismiss)
        #expect(leader.animationSteps?[0].delaySeconds == nil)
        #expect(leader.addedIDs == ["s1", "s2"])

        let follower = AnimationPresetApplication.apply(preset, to: existing, mode: .add, position: 2, makeID: id)
        #expect(follower.animationSteps?.map(\.id) == ["old", "s3", "s4"], "add keeps what was there")
        #expect(follower.animationSteps?[1].trigger == .withPrevious, "a follower's lead step rides With Previous")
        #expect(follower.animationSteps?[1].delaySeconds == 0.3, "stagger × position")
        #expect(follower.animationSteps?[2].trigger == .onDismiss)
        #expect(follower.animationSteps?[2].delaySeconds == 0.3, "the Out staggers too")

        let roll = try #require(AnimationPreset.recommended.first { $0.id == "builtin.roll" })
        let rolled = AnimationPresetApplication.apply(roll, to: existing, mode: .replace, position: 0, makeID: id)
        #expect(rolled.animationSteps == nil)
        #expect(rolled.scroll?.axis == .up)
        let crawl = try #require(AnimationPreset.recommended.first { $0.id == "builtin.crawl" })
        #expect(crawl.tilt == 35 && (crawl.scroll?.fadeTowardTop ?? 0) > 0)

        var ranged = existing[0]
        ranged.ranges = [AnimationRange(line: 0, column: 0, length: 3)]
        #expect(AnimationPresetApplication.recipe(from: [ranged])[0].ranges == nil)
    }

    @Test func genericPlaceholderMatchesOnlyUntouchedDefaultCategories() {
        let defaults = Theme.defaultSlides()
        #expect(defaults.count == 4 && defaults.allSatisfy(StarterPack.isGenericPlaceholder))
        var restyled = defaults[0]
        restyled.objects[0].text = "Amazing grace"
        #expect(!StarterPack.isGenericPlaceholder(restyled), "edited sample text keeps the slide")
        var filed = defaults[1]
        filed.folder = "Full Slide"
        #expect(!StarterPack.isGenericPlaceholder(filed), "a filed category keeps its place")
        var added = defaults[2]
        added.objects.append(SlideObject(id: "x", objectKind: .shape, name: "Plate", text: ""))
        #expect(!StarterPack.isGenericPlaceholder(added), "a designed category stays")
    }

    @Test func addingLyricsDesignsFillsOnlyTheGaps() {
        let pack = StarterPack.cleanGeometric
        let full = pack.makeTheme().slides ?? []
        #expect(pack.addingLyricsDesigns(to: full) == full, "a complete theme is untouched")

        let missing = full.filter { !$0.id.hasPrefix("\(pack.themeID).lyrics") }
        let repaired = pack.addingLyricsDesigns(to: missing)
        #expect(Set(repaired.map(\.name)) == Set(full.map(\.name)), "every shipped design present")
        #expect(repaired.first?.name == "Lyrics")
        #expect(repaired.filter { $0.folder == "Lower Thirds" }.last?.name == "Lyrics (Lower Third)")
        #expect(repaired.filter { $0.folder == "Side Thirds" }.last?.name == "Lyrics (Side Third)")
        #expect(repaired.count == full.count)

        var own = Slide(id: "mine", name: "lyrics", objects: [])
        own.folder = nil
        let kept = pack.addingLyricsDesigns(to: [own] + missing.filter { $0.folder != nil })
        #expect(kept.first?.id == "mine" && !kept.contains { $0.id == "\(pack.themeID).lyrics" })
    }

    @Test func pagingThirdsSetsOnlyThePackThirdsPrimaries() {
        let pack = StarterPack.digital
        var stale = (pack.makeTheme().slides ?? []).map { slide -> Slide in
            var s = slide
            for i in s.objects.indices { s.objects[i].textStyle?.pageOnClick = nil; s.objects[i].textStyle?.autoShrink = nil }
            return s
        }
        stale.append(Slide(id: "mine", name: "My Third", objects: [SlideObject(id: "t", objectKind: .text, name: "Text", text: "")], folder: "Side Thirds"))
        let repaired = pack.pagingThirds(stale)
        for slide in repaired where slide.id.hasPrefix(pack.themeID) && slide.folder != "Full Slide" {
            let primary = slide.objects.first { $0.objectKind == .text }
            #expect(primary?.textStyle?.pageOnClick == true && primary?.textStyle?.autoShrink == true, "\(slide.name)")
        }
        #expect(repaired.filter { $0.folder == "Full Slide" }.allSatisfy { $0.objects.allSatisfy { $0.textStyle?.pageOnClick != true } })
        #expect(repaired.last?.objects[0].textStyle?.pageOnClick == nil, "the user's own design is untouched")
        #expect(pack.pagingThirds(pack.makeTheme().slides ?? []) == pack.makeTheme().slides, "a fresh theme is already right")
    }

    @Test func starterPacksAreConsistentDocuments() {
        for pack in StarterPack.allCases {
            let theme = pack.makeTheme()
            #expect(theme.id == pack.themeID && theme.name == pack.title)
            let names = Set((theme.slides ?? []).map(\.name))
            #expect(names.isSuperset(of: ["Points", "Verse + Reference", "Name + Title", "Point (Side Third)", "Lyrics", "Lyrics (Lower Third)", "Lyrics (Side Third)"]), Comment(rawValue: pack.title))

            #expect(!(theme.slides ?? []).contains(where: StarterPack.isGenericPlaceholder), Comment(rawValue: pack.title))
            #expect(theme.slides?.first?.name == "Lyrics", Comment(rawValue: pack.title))
            for folder in ["Lower Thirds", "Side Thirds"] {
                let run = (theme.slides ?? []).filter { $0.folder == folder }
                #expect(run.first?.name.hasPrefix("Lyrics") == false, "\(pack.title)/\(folder): the generic default still leads")
                #expect(run.contains { $0.name.hasPrefix("Lyrics") }, "\(pack.title)/\(folder): a Lyrics third")
            }

            let folders = Set((theme.slides ?? []).compactMap(\.folder))
            #expect(folders == ["Full Slide", "Lower Thirds", "Side Thirds"], Comment(rawValue: pack.title))
            #expect(names.count == (theme.slides ?? []).count, "theme slide names stay unique (themeSlideName matches by name)")
            for slide in theme.slides ?? [] { checkOrder(slide.objects, slide.animationOrder, "\(pack.title)/\(slide.name)") }

            let overlays = pack.makeOverlays()
            #expect(overlays.map(\.name).contains("Verse + Reference") && overlays.map(\.name).contains("Point"), Comment(rawValue: pack.title))
            #expect(Set(overlays.compactMap(\.folder)) == Set(["Lower Thirds", "Side Thirds", "Full Screen"].map { "\(pack.title)/\($0)" }))
            #expect(overlays.count == StarterPack.overlayItems.count, Comment(rawValue: pack.title))
            #expect(overlays.allSatisfy { $0.folder?.hasPrefix(pack.title + "/") == true })
            #expect(Set(overlays.map(\.id)).count == overlays.count)
            for overlay in overlays {
                checkOrder(overlay.objects, overlay.animationOrder, "\(pack.title)/\(overlay.name)")
                let steps = overlay.objects.flatMap { $0.animationSteps ?? [] }
                #expect(steps.contains { $0.kind == .in } && steps.contains { $0.kind == .out }, "\(overlay.name) has In + Out")
                for object in overlay.objects {

                    let animationSteps = object.animationSteps ?? []
                    if object.objectKind == .text {
                        #expect(animationSteps.allSatisfy { $0.animation != .move || $0.edge == nil }, "\(overlay.name)/\(object.name) text floats in place")
                    }
                    if animationSteps.contains(where: { $0.kind == .in }) {
                        #expect(animationSteps.contains { $0.kind == .out }, "\(overlay.name)/\(object.name) leaves too")
                    }
                }
            }

            let tickerObjects: [SlideObject] = overlays.first { $0.name == "Ticker" }?.objects ?? []
            #expect(tickerObjects.contains { $0.textStyle?.scroll?.axis == .left })
            let timedSteps: [AnimationStep] = overlays.first { $0.name == "Name + Title (timed)" }?.objects.flatMap { $0.animationSteps ?? [] } ?? []
            let leavesUnaided = timedSteps.contains { step in
                step.kind == .out && step.trigger == .afterPrevious && step.delaySeconds == 6
            }
            #expect(leavesUnaided)
        }

        for pack in StarterPack.allCases {
            let overlays = pack.makeOverlays()
            for name in ["Point (Side Third)", "Verse + Reference (Side Third)"] {
                let steps = overlays.first { $0.name == name }?.objects.flatMap { $0.animationSteps ?? [] } ?? []
                let pushes = steps.filter { $0.videoPush != nil }
                #expect(pushes.count == 2 && Set(pushes.map(\.kind)) == [.in, .out], Comment(rawValue: "\(pack.title)/\(name)"))
                #expect(pushes.allSatisfy { $0.videoPush?.backdrop == true }, Comment(rawValue: name))
            }
            let search = overlays.first { $0.name == "Search" }?.objects.flatMap { $0.animationSteps ?? [] } ?? []
            #expect(search.contains { $0.videoPush?.mode == .blurBackground && $0.kind == .in })
            let band = overlays.first { $0.name == "Verse + Reference" }?.objects.flatMap { $0.animationSteps ?? [] } ?? []
            #expect(band.allSatisfy { $0.videoPush == nil }, "lower thirds don't push")
        }

        #expect(Set(StarterPack.allCases.map(\.themeID)).count == 4)
        #expect(Set(StarterPack.allCases.map { $0.makeTheme().fontFamily }).count == 4)
    }

    private func checkOrder(_ objects: [SlideObject], _ order: [String]?, _ label: String) {
        let ids = Set(objects.flatMap { ($0.animationSteps ?? []).map(\.id) })
        #expect(ids.count == objects.flatMap { $0.animationSteps ?? [] }.count, "\(label): step ids unique")
        if let order {
            #expect(Set(order) == ids, "\(label): animationOrder names every step exactly")
            #expect(order.count == ids.count, "\(label): no duplicates in animationOrder")
        }
    }

    @LibraryActor @Test func animationPresetBoardIsASingletonDocumentKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        #expect(DocumentKind.animationPresetBoard.directoryName == "animation-presets")
        let board = AnimationPresetBoard(id: AnimationPresetBoard.wellKnownID, presets: [
            AnimationPreset(id: "u1", name: "Mine", steps: [AnimationStep(id: "x", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)]),
        ])
        try library.store.save(TypedDocument(board))
        let loaded = try library.store.load(AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID)
        #expect(loaded.value.presets.map(\.name) == ["Mine"])
    }
}

extension AnimationPresetTests {

    @LibraryActor @Test func defaultInOutSurviveReopenAndMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        var board = AnimationPresetBoard(id: AnimationPresetBoard.wellKnownID, presets: [])
        board.defaultIn = AnimationStep(
            id: "", kind: .in, animation: .wipe, trigger: .onClick, durationSeconds: 0.3
        )
        let document = try TypedDocument(board)
        try library.store.save(document)

        let reopened = try library.store.load(
            AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID
        )
        #expect(reopened.value.defaultIn?.animation == .wipe)
        #expect(reopened.value.defaultIn?.durationSeconds == 0.3)
        #expect(reopened.value.defaultOut == nil, "absent = the app default (Fade · Normal)")

        let replica = try reopened.fork()
        try replica.update {
            $0.defaultOut = AnimationStep(
                id: "", kind: .out, animation: .blur, trigger: .onDismiss, durationSeconds: 0.6
            )
        }
        try reopened.merge(replica)
        #expect(reopened.value.defaultIn?.animation == .wipe)
        #expect(reopened.value.defaultOut?.animation == .blur)
    }
}
