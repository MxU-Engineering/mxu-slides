import CryptoKit
import Foundation

public enum ImportConflictPolicy: String, Codable, CaseIterable, Sendable {

    case keepMine

    case updateUnedited

    case replace

    public var displayName: String {
        switch self {
        case .keepMine: "Keep mine — only add new"
        case .updateUnedited: "Update unedited — keep anything I've changed"
        case .replace: "Replace with imported"
        }
    }
}

public enum ImportFingerprint {
    public static func hash(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ImportLedger {

    public static let hotKeyPrefix = "hotkey."

    public func value(for docId: String) -> String? {
        entries.first { $0.docId == docId }?.hash
    }

    public mutating func stamp(_ docId: String, _ hash: String) {
        if let index = entries.firstIndex(where: { $0.docId == docId }) {
            entries[index].hash = hash
        } else {
            entries.append(ImportLedgerEntry(docId: docId, hash: hash))
        }
    }

    public func isUnedited(docId: String, currentHash: String?) -> Bool {
        guard let currentHash, let stamped = value(for: docId) else { return false }
        return stamped == currentHash
    }
}

extension GroupPalette {

    public mutating func applyImportedHotKeys(
        _ imported: [String: String],
        policy: ImportConflictPolicy,
        ledger: ImportLedger
    ) -> [(docId: String, hash: String)] {
        var stamps: [(docId: String, hash: String)] = []
        for index in groups.indices {
            let name = GroupPalette.normalizedName(groups[index].name)
            guard let letter = imported[name]?.lowercased(), letter.count == 1,
                  letter.first?.isLetter == true else { continue }
            let stampId = ImportLedger.hotKeyPrefix + name
            let mayWrite: Bool
            switch policy {
            case .keepMine:
                mayWrite = groups[index].hotKey == nil
            case .updateUnedited:
                mayWrite = groups[index].hotKey == nil
                    || groups[index].hotKey == ledger.value(for: stampId)
            case .replace:
                mayWrite = true
            }
            guard mayWrite else { continue }

            if GroupPalette.defaultHotKeys[name] == letter {

                if groups[index].hotKey != nil { groups[index].hotKey = nil }
            } else if groups[index].hotKey != letter {
                groups[index].hotKey = letter
                stamps.append((stampId, letter))
            }
        }
        return stamps
    }
}
