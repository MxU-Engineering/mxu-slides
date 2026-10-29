import Foundation
import PresenterCore

/// Persist object IDs rather than display names: humans may rename theme blocks.
/// Empty IDs mean automatic; the footer sentinel explicitly bypasses a theme box.
public struct BibleBlockMapping: Codable, Sendable, Equatable {
    public static let footer = "__bible_footer__"
    public var verse = ""
    public var reference = ""
    public var copyright = ""
    public init() {}

    public func resolved(in template: Slide?) -> (verse: SlideObject?, reference: SlideObject?, copyright: SlideObject?) {
        let blocks = template?.objects.filter { $0.objectKind == .text } ?? []
        func named(_ name: String) -> SlideObject? { blocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        let verseBlock = blocks.first { $0.id == verse } ?? named("Verse")
            ?? blocks.first { $0.name.caseInsensitiveCompare("Copyright") != .orderedSame }
        let available = blocks.filter { $0.id != verseBlock?.id }
        let referenceBlock = available.first { $0.id == reference }
            ?? available.first { $0.name.caseInsensitiveCompare("Reference") == .orderedSame }
            ?? available.first { $0.name.caseInsensitiveCompare("Copyright") != .orderedSame }
        let copyrightBlock = copyright == Self.footer ? nil : blocks.first {
            $0.id != verseBlock?.id && $0.id != referenceBlock?.id &&
            ($0.id == copyright || (copyright.isEmpty && $0.name.caseInsensitiveCompare("Copyright") == .orderedSame))
        }
        return (verseBlock, referenceBlock, copyrightBlock)
    }
}

public enum BibleCopyright {
    /// Use the edition's actual years, not a hard-coded year for an abbreviation.
    /// Unknown/localized notices are left intact rather than guessed or truncated.
    public static func short(_ translation: BibleTranslation) -> String {
        let full = translation.copyright
        let abbreviation = translation.id.uppercased()
        if translation.source?.contains("api.esv.org") == true { return "ESV © 2001 Crossway." }
        guard ["NIV", "NLT", "MSG"].contains(abbreviation),
              let regex = try? NSRegularExpression(pattern: #"(?:©|\(c\))\s*((?:19|20)\d{2}(?:\s*,\s*(?:19|20)\d{2})*)"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: full, range: NSRange(full.startIndex..., in: full)),
              let range = Range(match.range(at: 1), in: full) else { return full }
        let years = String(full[range])
        let holder: String
        switch abbreviation {
        case "NIV" where full.localizedCaseInsensitiveContains("Biblica"): holder = "Biblica, Inc."
        case "NIV" where full.localizedCaseInsensitiveContains("International Bible Society"): holder = "International Bible Society"
        case "NLT" where full.localizedCaseInsensitiveContains("Tyndale House Foundation"): holder = "Tyndale House Foundation"
        case "NLT" where full.localizedCaseInsensitiveContains("Tyndale House Publishers"): holder = "Tyndale House Publishers"
        case "MSG" where full.localizedCaseInsensitiveContains("Peterson"): holder = "Eugene H. Peterson"
        default: return full
        }
        let period = holder.hasSuffix(".") ? "" : "."
        return "\(abbreviation) © \(years) \(holder)\(period) All rights reserved."
    }
}
