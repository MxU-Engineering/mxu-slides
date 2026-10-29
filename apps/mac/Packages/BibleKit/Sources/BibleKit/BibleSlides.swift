import Foundation
import PresenterCore

public struct BiblePage: Sendable, Equatable, Identifiable {
    public let id: String
    public let reference: String
    public let text: String
    public let verseIDs: [String]
}

public enum BibleSlideStyle: String, Sendable, CaseIterable {
    case dark = "Full Screen · Dark"
    case light = "Full Screen · Light"
    case lowerThird = "Lower Third"
}

public enum BibleSlides {
    public static func pages(verses: [BibleVerse], oneVersePerSlide: Bool = true, verseNumbers: Bool = true, maxCharacters: Int = 450) -> [BiblePage] {
        let limit = max(100, min(1200, maxCharacters))
        var pages: [BiblePage] = []
        var pageText = ""
        var pageVerses: [BibleVerse] = []
        func flush() {
            guard !pageText.isEmpty else { return }
            pages.append(BiblePage(id: "page-\(pages.count)", reference: BibleCorpus.reference(for: pageVerses), text: pageText, verseIDs: pageVerses.map(\.id)))
            pageText = ""; pageVerses = []
        }
        // Keep source verse provenance even when a long verse spans several pages.
        // Repeated references are intentional; words are never truncated to fit.
        for verse in verses {
            if oneVersePerSlide { flush() }
            let text = (verseNumbers ? "\(verse.displayNumber) " : "") + verse.text
            for word in text.split(whereSeparator: \.isWhitespace) {
                let next = String(word)
                if !pageText.isEmpty && pageText.count + 1 + next.count > limit { flush() }
                if pageVerses.last?.id != verse.id { pageVerses.append(verse) }
                if !pageText.isEmpty { pageText += " " }
                pageText += next
            }
        }
        flush()
        return pages
    }

    public static func slide(page: BiblePage, translation: BibleTranslation, style: BibleSlideStyle = .dark,
                             showTranslation: Bool = true, showCopyright: Bool = true,
                             themeID: String = "", design: String = "Bible", template: Slide? = nil,
                             mapping: BibleBlockMapping = BibleBlockMapping(), shortCopyright: Bool = false) -> Slide {
        let lower = style == .lowerThird
        let ink = style == .light ? "#172033FF" : "#FFFFFFFF"
        let background = style == .light ? "#F6F4EFFF" : "#101820FF"
        let themed = !themeID.isEmpty
        var objects: [SlideObject] = []
        if lower && !themed {
            objects.append(SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Bible Background", text: "",
                                       x: 0, y: 660, width: 1920, height: 420, shapeKind: .rectangle,
                                       fill: ObjectFill(fillKind: .solid, colorHex: "#101820EE")))
        }
        objects.append(SlideObject(id: UUID().uuidString, objectKind: .text, name: "Verse", text: page.text,
                                   x: themed ? nil : 120, y: themed ? nil : (lower ? 700 : 140),
                                   width: themed ? nil : 1680, height: themed ? nil : (lower ? 220 : 660),
                                   textStyle: themed ? nil : TextStyle(fontName: "HelveticaNeue", fontSize: lower ? 48 : 72,
                                       colorHex: ink, lineHeightMultiple: 1.14, horizontalAlignment: .left,
                                       verticalAlignment: .middle, autoShrink: true, minFontSize: lower ? 24 : 32)))
        let reference = page.reference + (showTranslation ? " (\(translation.id))" : "")
        objects.append(SlideObject(id: UUID().uuidString, objectKind: .text, name: "Reference", text: reference,
                                   x: themed ? nil : 120, y: themed ? nil : (lower ? 935 : 850),
                                   width: themed ? nil : 1680, height: themed ? nil : 65,
                                   textStyle: themed ? nil : TextStyle(fontName: "HelveticaNeue-Bold", fontSize: lower ? 30 : 40,
                                       colorHex: ink, horizontalAlignment: .left, autoShrink: true, minFontSize: 20)))
        // Visibility affects slide objects only. Source/copyright metadata remains
        // in notes and the translation file, including when this footer is hidden.
        if showCopyright {
            objects.append(SlideObject(id: UUID().uuidString, objectKind: .text, name: "Copyright", text: shortCopyright ? BibleCopyright.short(translation) : translation.copyright,
                                   x: 120, y: 1020, width: 1680, height: 40,
                                   textStyle: TextStyle(fontName: "HelveticaNeue", fontSize: 18, colorHex: ink,
                                       horizontalAlignment: .left, autoShrink: true, minFontSize: 10)))
        }
        if themed, let template {
            let targets = mapping.resolved(in: template)
            // Bind the chosen block by its existing template name so ordinary
            // theme edits keep propagating. Duplicate names require a snapshot
            // because the upstream renderer matches placeholders by name.
            for index in objects.indices {
                let target: SlideObject? = switch objects[index].name {
                case "Verse": targets.verse
                case "Reference": targets.reference
                case "Copyright": targets.copyright
                default: nil
                }
                guard var block = target else { continue }
                let text = objects[index].text
                if template.objects.filter({ $0.objectKind == .text && $0.name.caseInsensitiveCompare(block.name) == .orderedSame }).count == 1 {
                    objects[index] = SlideObject(id: UUID().uuidString, objectKind: .text, name: block.name, text: text)
                } else {
                    // Duplicate names cannot be distinguished by the upstream
                    // name-based renderer. Snapshot the chosen ID's appearance.
                    block.id = UUID().uuidString; block.text = text; block.textLink = nil
                    objects[index] = block
                }
            }
        }
        let provenance = translation.source?.contains("api.esv.org") == true
            ? "\nESV-API-VERSES: " + page.verseIDs.joined(separator: ",") : ""
        return Slide(id: UUID().uuidString, name: page.reference, objects: objects,
                     backgroundFill: themed || lower ? nil : ObjectFill(fillKind: .solid, colorHex: background),
                     themeSlideName: themed ? design : nil, themeId: themed ? themeID : nil,
                     notes: "\(translation.name)\n\(translation.copyright)\n\(translation.source ?? "Imported Bible")\(provenance)")
    }
}
