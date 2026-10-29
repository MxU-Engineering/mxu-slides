import Foundation
import PresenterCore

public enum ESVStorage {
    /// Conservative half-book thresholds from the bundled 66-book index. A 1%
    /// margin avoids treating differing verse numbering as extra storage rights.
    /// The global 500-verse allowance is applied independently of these thresholds.
    private static let bookLimits: [String: Int] = {
        let verses = (try? BibleTranslation.bundledWEB().verses) ?? []
        return Dictionary(grouping: verses, by: \.book).mapValues { min(500, $0.count * 49 / 100) }
    }()

    public static func ids(in slides: [Slide]) -> Set<String> {
        var result = Set<String>()
        for slide in slides {
            for line in (slide.notes ?? "").components(separatedBy: "\n") where line.hasPrefix("ESV-API-VERSES: ") {
                result.formUnion(line.dropFirst("ESV-API-VERSES: ".count).split(separator: ",").map(String.init))
            }
        }
        return result
    }

    public static func validate(pending: [BibleVerse], saved: Set<String>) throws {
        let combined = saved.union(pending.map(\.id))
        guard combined.count <= 500 else { throw ESVError.storageLimit }
        let grouped = Dictionary(grouping: combined) { $0.components(separatedBy: ".")[0] }
        for (book, ids) in grouped {
            guard let limit = bookLimits[book], ids.count <= limit else { throw ESVError.storageLimit }
        }
    }
}
