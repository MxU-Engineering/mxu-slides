import CryptoKit
import Foundation

public enum RunOnlyPasscode {

    public static func record(for pin: String) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        for index in salt.indices {
            salt[index] = UInt8.random(in: .min ... .max)
        }
        return hex(salt) + "$" + digest(pin: pin, salt: salt)
    }

    public static func matches(_ pin: String, record: String) -> Bool {
        let parts = record.split(separator: "$", maxSplits: 1)
        guard parts.count == 2, let salt = bytes(fromHex: String(parts[0])) else {
            return false
        }
        return digest(pin: pin, salt: salt) == String(parts[1])
    }

    public static func isValid(pin: String) -> Bool {
        (4 ... 6).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func digest(pin: String, salt: [UInt8]) -> String {
        var data = Data(salt)
        data.append(Data(pin.utf8))
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

public struct RunOnlyAttempts: Equatable, Sendable {
    public static let freeTries = 5
    public static let wait: TimeInterval = 30

    public private(set) var failures = 0
    public private(set) var lockedUntil: Date?

    public init() {}

    public func secondsLeft(at now: Date) -> Int {
        if let lockedUntil, lockedUntil > now {
            Int(lockedUntil.timeIntervalSince(now).rounded(.up))
        } else {
            0
        }
    }

    public mutating func noteFailure(at now: Date) {
        failures += 1
        if failures >= Self.freeTries {
            lockedUntil = now.addingTimeInterval(Self.wait)
        }
    }

    public mutating func noteSuccess() {
        self = RunOnlyAttempts()
    }
}
