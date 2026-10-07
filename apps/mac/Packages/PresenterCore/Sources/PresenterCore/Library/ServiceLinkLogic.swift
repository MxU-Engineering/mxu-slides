import Foundation

public enum ServiceLinkLogic {

    public struct SongKeyUpdate: Equatable, Sendable {

        public var displayKey: String?

        public var appliedKey: String
    }

    public static func pendingSongKey(for item: ServiceItem) -> String? {
        guard item.itemKind == .presentation, !item.refId.isEmpty, item.mxuSongKeyApplied == nil,
              let key = item.mxuSongKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty
        else { return nil }
        return key
    }

    public static func songKeyUpdate(playing key: String, presentation: Presentation) -> SongKeyUpdate? {
        guard ChordMath.hasChords(in: presentation), let musicKey = presentation.musicKey,
              let spelled = ChordMath.displayKey(playing: key, musicKey: musicKey)
        else { return nil }
        let original = spelled.caseInsensitiveCompare(musicKey) == .orderedSame
        return SongKeyUpdate(displayKey: original ? nil : spelled, appliedKey: key)
    }

    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var name: String
        public var ccliNumber: Int?
        public var ccliSongTitle: String?

        public init(id: String, name: String, ccliNumber: Int? = nil, ccliSongTitle: String? = nil) {
            self.id = id
            self.name = name
            self.ccliNumber = ccliNumber
            self.ccliSongTitle = ccliSongTitle
        }
    }

    public enum Resolution: Equatable {

        case link(itemKind: ServiceItemKind, refId: String)
        case none
    }

    public static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(stripped)
            .split(separator: " ")
            .joined(separator: " ")
    }

    public static func resolve(
        item: ServiceItem,
        serviceTypeName: String?,
        rules: ServiceLinkRules,
        candidates: [Candidate]
    ) -> Resolution {
        if let rule = matchingRule(name: item.name, serviceTypeName: serviceTypeName, in: rules) {
            return .link(itemKind: rule.itemKind, refId: rule.refId)
        }

        guard item.mxuSongTitle != nil || item.mxuCcliNumber != nil else { return .none }

        if let ccli = item.mxuCcliNumber {
            let hits = candidates.filter { $0.ccliNumber == ccli }
            if hits.count == 1 { return .link(itemKind: .presentation, refId: hits[0].id) }
            if hits.count > 1 { return .none }
        }

        let wanted = normalize(item.mxuSongTitle ?? item.name)
        guard !wanted.isEmpty else { return .none }
        let hits = candidates.filter {
            normalize($0.name) == wanted
                || $0.ccliSongTitle.map { normalize($0) == wanted } == true
        }
        if hits.count == 1 { return .link(itemKind: .presentation, refId: hits[0].id) }
        return .none
    }

    public static func matchingRule(
        name: String, serviceTypeName: String?, in rules: ServiceLinkRules
    ) -> ServiceLinkRule? {
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return nil }
        return rules.rules.first {
            $0.normalizedName == normalized && $0.serviceTypeName == serviceTypeName
        }
    }

    public static func merged(team: [ServiceLinkRule], own: [ServiceLinkRule]) -> ServiceLinkRules {
        let covered = Set(team.map { [$0.normalizedName, $0.serviceTypeName ?? ""] })
        let kept = own.filter { !covered.contains([$0.normalizedName, $0.serviceTypeName ?? ""]) }
        return ServiceLinkRules(id: ServiceLinkRules.teamID, rules: team + kept)
    }

    public static func stampRule(
        into rules: inout ServiceLinkRules,
        itemName: String, serviceTypeName: String?,
        itemKind: ServiceItemKind, refId: String,
        newID: () -> String = { UUID().uuidString }
    ) {
        let normalized = normalize(itemName)
        guard !normalized.isEmpty else { return }
        if let index = rules.rules.firstIndex(where: {
            $0.normalizedName == normalized && $0.serviceTypeName == serviceTypeName
        }) {
            rules.rules[index].itemKind = itemKind
            rules.rules[index].refId = refId
        } else {
            rules.rules.append(ServiceLinkRule(
                id: newID(),
                normalizedName: normalized,
                serviceTypeName: serviceTypeName,
                itemKind: itemKind,
                refId: refId))
        }
    }

    public static func removeRule(
        from rules: inout ServiceLinkRules,
        itemName: String, serviceTypeName: String?
    ) {
        let normalized = normalize(itemName)
        rules.rules.removeAll {
            $0.normalizedName == normalized && $0.serviceTypeName == serviceTypeName
        }
    }

    public static func matchArrangement(
        named name: String?, in arrangements: [Arrangement]?
    ) -> String? {
        guard let name, let arrangements else { return nil }
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        return arrangements.first { normalize($0.name) == wanted }?.id
    }
}

public extension ServiceLinkLogic {

    static let minimumScore = 15

    static func suggestions(
        for item: ServiceItem,
        serviceTypeName: String?,
        rules: ServiceLinkRules,
        candidates: [Candidate],
        limit: Int = 5
    ) -> [Candidate] {
        let ruleRefId = matchingRule(
            name: item.name, serviceTypeName: serviceTypeName, in: rules
        )?.refId
        let wanted = normalize(item.mxuSongTitle ?? item.name)
        let wantedWords = Set(wanted.split(separator: " ").map(String.init))

        let scored: [(Candidate, Int)] = candidates.compactMap { candidate in
            var score = 0
            if candidate.id == ruleRefId { score += 100 }
            if let ccli = item.mxuCcliNumber, candidate.ccliNumber == ccli { score += 50 }

            let name = normalize(candidate.name)
            let ccliTitle = candidate.ccliSongTitle.map(normalize)
            if !wanted.isEmpty {
                if name == wanted || ccliTitle == wanted {
                    score += 30
                } else if name.hasPrefix(wanted) || wanted.hasPrefix(name) {
                    score += 15
                } else {

                    let words = Set(name.split(separator: " ").map(String.init))
                    let shared = wantedWords.intersection(words).count
                    if shared > 0, !wantedWords.isEmpty {
                        score += min(12, shared * 12 / max(wantedWords.count, 1))
                    }
                }
            }
            return score >= minimumScore ? (candidate, score) : nil
        }

        return scored
            .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
            .prefix(limit)
            .map(\.0)
    }
}
