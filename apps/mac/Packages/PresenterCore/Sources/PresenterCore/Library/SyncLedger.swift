import Automerge
import CryptoKit
import Foundation

public enum SyncLedger {
    public struct Key: Hashable, Sendable {
        public var kind: DocumentKind
        public var id: String

        public init(kind: DocumentKind, id: String) {
            self.kind = kind
            self.id = id
        }
    }

    public struct Entry: Codable, Equatable, Sendable {

        public var lastPushedHeads: [String]
        public var appliedSeq: Int
        public var remoteSeq: Int

        public var pending: Bool
        public var lastSnapshotAt: Date?

        public init(lastPushedHeads: [String] = [], appliedSeq: Int = 0, remoteSeq: Int = 0, pending: Bool = false, lastSnapshotAt: Date? = nil) {
            self.lastPushedHeads = lastPushedHeads
            self.appliedSeq = appliedSeq
            self.remoteSeq = remoteSeq
            self.pending = pending
            self.lastSnapshotAt = lastSnapshotAt
        }
    }

    public struct HeldDelete: Equatable, Hashable, Sendable {
        public enum Side: String, Sendable {

            case remote

            case local
        }

        public var key: Key
        public var side: Side

        public var namespace: SyncScope
        public var heldAt: Date

        public init(key: Key, side: Side, namespace: SyncScope, heldAt: Date = Date()) {
            self.key = key
            self.side = side
            self.namespace = namespace
            self.heldAt = heldAt
        }

        public func sameHold(as other: HeldDelete) -> Bool {
            key == other.key && side == other.side && namespace == other.namespace
        }
    }

    public struct Quarantined: Equatable, Sendable {
        public var seq: Int
        public var bytes: Data
        public var error: String
        public var quarantinedAt: Date
    }

    public static func signature(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    public static func hex(_ heads: Set<ChangeHash>) -> [String] {
        heads.map(\.debugDescription).sorted()
    }

    public static func heads(_ hex: [String]) -> Set<ChangeHash> {
        var bytes = Data()
        for text in hex {
            var index = text.startIndex
            while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                  let byte = UInt8(text[index..<next], radix: 16) {
                bytes.append(byte)
                index = next
            }
        }
        return bytes.heads() ?? []
    }
}
