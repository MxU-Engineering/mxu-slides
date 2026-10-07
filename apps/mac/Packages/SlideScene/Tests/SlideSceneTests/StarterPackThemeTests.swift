import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing

@testable import SlideScene

@Test func packThirdFoldersLeadWithASimplifiedDefault() {
    for pack in StarterPack.allCases {
        let theme = pack.makeTheme()
        #expect(theme.slideFolders == ["Full Slide", "Lower Thirds", "Side Thirds"])
        for (folder, item) in [("Lower Thirds", "lowerDefault"), ("Side Thirds", "sideDefault")] {
            let scoped = theme.scoped(toSlideFolder: folder)
            guard let first = scoped.slides?.first else {
                Issue.record("\(pack.title) \(folder): empty folder")
                continue
            }
            #expect(first.id == "\(pack.themeID).\(item)",
                    "\(pack.title) \(folder): generic default leads the folder")

            let stepIDs = Set(first.objects.flatMap { ($0.animationSteps ?? []).map(\.id) })
            #expect((first.animationOrder ?? []).allSatisfy { stepIDs.contains($0) },
                    "\(pack.title) \(folder): dangling animationOrder id")
            let firstText = first.objects.first(where: { $0.objectKind == .text })
            #expect(firstText?.id == "\(pack.themeID).\(item).text")
        }
    }
}

@Test func scopedThemeBindsPlainSlideAndDonatedBuildsPlay() {

    let lyric = Slide(id: "s", name: "Verse 1", objects: [
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "Amazing grace"),
    ])
    for pack in StarterPack.allCases {
        for folder in ["Lower Thirds", "Side Thirds"] {
            let scoped = pack.makeTheme().scoped(toSlideFolder: folder)
            var show = ShowState()
            show.slideThemeOverrides = [scoped]
            show.fire(slide: lyric, atHostTime: 1)
            let items = show.scene(slideThemeOverride: scoped)
                .layers.first { $0.kind == .slide }?.items ?? []
            let bound = items.filter { $0.id.hasPrefix("lyrics") }
            #expect(!bound.isEmpty, "\(pack.title) › \(folder): lyric binds a placeholder")
            #expect(bound.allSatisfy { !$0.animationSteps.isEmpty },
                    "\(pack.title) › \(folder): donated animationSteps ride the bound text")
            show.clear(layer: .slide, atHostTime: 5)
            #expect(show.liveSlide != nil, "\(pack.title) › \(folder): the Out plays before removal")
        }
    }
}

@Test func packThemePromotesPrimaryPlaceholdersAheadOfKickers() {

    for pack in StarterPack.allCases {
        let theme = pack.makeTheme()
        let side = theme.slides?.first { $0.name == "Point (Side Third)" }
        #expect(side?.objects.first { $0.objectKind == .text }?.id == "\(pack.themeID).pointSide.text")
        let lower = theme.slides?.first { $0.name == "Point (Lower Third)" }
        #expect(lower?.objects.first { $0.objectKind == .text }?.id == "\(pack.themeID).pointLower.text")
    }
}

@Test func packThirdsShrinkTheirPrimaryTextAndFullSlidesDoNot() {
    for pack in StarterPack.allCases {
        let theme = pack.makeTheme()
        for folder in ["Lower Thirds", "Side Thirds"] {
            for slide in theme.scoped(toSlideFolder: folder).slides ?? [] {
                let primary = slide.objects.first { $0.objectKind == .text }
                #expect(primary?.textStyle?.autoShrink == true, "\(pack.title)/\(slide.name) primary shrinks")
                #expect(primary?.textStyle?.pageOnClick == true, "\(pack.title)/\(slide.name) primary pages")
            }
        }
        for slide in theme.scoped(toSlideFolder: "Full Slide").slides ?? [] {
            #expect(slide.objects.allSatisfy { $0.textStyle?.autoShrink != true && $0.textStyle?.pageOnClick != true }, "\(pack.title)/\(slide.name) stays warn-only")
        }
    }
}
