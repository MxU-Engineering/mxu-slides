import CryptoKit
import Foundation

public enum APIScope: String, Codable, CaseIterable, Sendable, Comparable {
    case view
    case control
    case edit

    private var rank: Int {
        switch self {
        case .view: 0
        case .control: 1
        case .edit: 2
        }
    }

    public static func < (lhs: APIScope, rhs: APIScope) -> Bool {
        lhs.rank < rhs.rank
    }

    public func allows(_ required: APIScope) -> Bool {
        rank >= required.rank
    }
}

public struct APIToken: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var scope: APIScope
    public var secretRecord: String
    public var prefix: String
    public var createdAt: Date

    public init(
        id: String, name: String, scope: APIScope,
        secretRecord: String, prefix: String, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.secretRecord = secretRecord
        self.prefix = prefix
        self.createdAt = createdAt
    }
}

enum APISecretHash {
    static func record(for secret: String) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        for index in salt.indices {
            salt[index] = UInt8.random(in: .min ... .max)
        }
        return hex(salt) + "$" + digest(secret: secret, salt: salt)
    }

    static func matches(_ secret: String, record: String) -> Bool {
        let parts = record.split(separator: "$", maxSplits: 1)
        guard parts.count == 2, let salt = bytes(fromHex: String(parts[0])) else {
            return false
        }
        return digest(secret: secret, salt: salt) == String(parts[1])
    }

    private static func digest(secret: String, salt: [UInt8]) -> String {
        var data = Data(salt)
        data.append(Data(secret.utf8))
        return hex(Array(SHA256.hash(data: data)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex string: String) -> [UInt8]? {
        guard string.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public struct APIDefaultKeyVault: Sendable {
    public var load: @Sendable () -> String?
    public var save: @Sendable (String) -> Void
    public var clear: @Sendable () -> Void

    public init(
        load: @escaping @Sendable () -> String?,
        save: @escaping @Sendable (String) -> Void,
        clear: @escaping @Sendable () -> Void
    ) {
        self.load = load
        self.save = save
        self.clear = clear
    }

    public static func inMemory() -> APIDefaultKeyVault {
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        return APIDefaultKeyVault(
            load: { box.value },
            save: { box.value = $0 },
            clear: { box.value = nil }
        )
    }
}

public final class APITokenStore: @unchecked Sendable {

    public static let defaultKeyName = "Default key"

    private let fileURL: URL
    private let vault: APIDefaultKeyVault
    private let lock = NSLock()
    private var tokens: [APIToken]

    public init(fileURL: URL, vault: APIDefaultKeyVault = .inMemory()) {
        self.fileURL = fileURL
        self.vault = vault
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([APIToken].self, from: data) {
            tokens = decoded
        } else {
            tokens = []
        }
    }

    public var all: [APIToken] {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public var defaultKeySecret: String? {
        guard let secret = vault.load() else { return nil }
        guard verify(secret: secret) != nil else {
            vault.clear()
            return nil
        }
        return secret
    }

    @discardableResult
    public func ensureDefaultKey(evenIfPopulated: Bool = false) -> String? {
        if let existing = defaultKeySecret { return existing }
        guard all.isEmpty || evenIfPopulated else { return nil }
        let minted = create(name: Self.defaultKeyName, scope: .control)
        vault.save(minted.secret)
        return minted.secret
    }

    @discardableResult
    public func create(name: String, scope: APIScope) -> (token: APIToken, secret: String) {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        let secret = "mxu_" + bytes.map { String(format: "%02x", $0) }.joined()
        let token = APIToken(
            id: UUID().uuidString,
            name: name,
            scope: scope,
            secretRecord: APISecretHash.record(for: secret),
            prefix: String(secret.prefix(9)),
            createdAt: Date()
        )
        lock.lock()
        tokens.append(token)
        persistLocked()
        lock.unlock()
        return (token, secret)
    }

    public func rename(id: String, to name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = tokens.firstIndex(where: { $0.id == id }) else { return }
        tokens[index].name = name
        persistLocked()
    }

    public func revoke(id: String) {

        if let secret = vault.load(),
           let token = verify(secret: secret), token.id == id {
            vault.clear()
        }
        lock.lock()
        defer { lock.unlock() }
        tokens.removeAll { $0.id == id }
        persistLocked()
    }

    public func verify(secret: String) -> APIToken? {
        lock.lock()
        defer { lock.unlock() }
        return tokens.first { APISecretHash.matches(secret, record: $0.secretRecord) }
    }

    /// Recheck an authenticated session without retaining its bearer secret.
    func activeToken(id: String) -> APIToken? {
        lock.lock()
        defer { lock.unlock() }
        return tokens.first { $0.id == id }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tokens) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
