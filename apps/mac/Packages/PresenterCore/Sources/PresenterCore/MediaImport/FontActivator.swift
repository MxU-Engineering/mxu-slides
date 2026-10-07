import CoreText
import CryptoKit
import Foundation

@MainActor
public enum FontActivator {

    public static func store(dataURL: URL, libraryRoot: URL) -> URL? {
        guard var data = try? Data(contentsOf: dataURL) else { return nil }
        if sniffExtension(data) == nil {

            guard data.count > 32, let key = guidBytes(fromPartName: dataURL.lastPathComponent) else { return nil }
            let reversedKey = Array(key.reversed())
            for index in 0..<32 {
                data[data.startIndex + index] ^= reversedKey[index % 16]
            }
        }
        guard let ext = sniffExtension(data), isEmbeddingAllowed(data) else { return nil }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = libraryRoot.appendingPathComponent("fonts", isDirectory: true)
        let url = directory.appendingPathComponent("\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
            } catch {
                return nil
            }
        }
        return url
    }

    @discardableResult
    nonisolated public static func register(url: URL) -> Bool {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    @discardableResult
    nonisolated public static func install(blobURL: URL, hash: String, ext: String, libraryRoot: URL) throws -> URL {
        let directory = libraryRoot.appendingPathComponent("fonts", isDirectory: true)
        let url = directory.appendingPathComponent("\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: blobURL, to: url)
        }
        register(url: url)
        return url
    }

    public static func activateStored(libraryRoot: URL) {
        let directory = libraryRoot.appendingPathComponent("fonts", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            register(url: file)
        }
    }

    nonisolated static func sniffExtension(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let magic = [UInt8](data.prefix(4))
        switch magic {
        case [0x00, 0x01, 0x00, 0x00], Array("true".utf8): return "ttf"
        case Array("OTTO".utf8): return "otf"
        case Array("ttcf".utf8): return "ttc"
        default: return nil
        }
    }

    nonisolated static func isEmbeddingAllowed(_ data: Data) -> Bool {
        guard let fsType = fsType(of: data) else { return true }
        return (fsType & 0x000F) != 0x0002
    }

    nonisolated static func fsType(of data: Data) -> UInt16? {
        func u16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            return UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[data.startIndex + offset + $1]) }
        }

        var base = 0
        if [UInt8](data.prefix(4)) == Array("ttcf".utf8) {
            guard let first = u32(12) else { return nil }
            base = Int(first)
        }
        guard let numTables = u16(base + 4) else { return nil }
        for index in 0..<Int(numTables) {
            let record = base + 12 + index * 16
            guard record + 16 <= data.count else { return nil }
            let tag = data[(data.startIndex + record)..<(data.startIndex + record + 4)]
            guard [UInt8](tag) == Array("OS/2".utf8) else { continue }
            guard let offset = u32(record + 8) else { return nil }
            return u16(Int(offset) + 8)
        }
        return nil
    }

    static func guidBytes(fromPartName name: String) -> [UInt8]? {
        let stem = (name as NSString).deletingPathExtension
        let digits = stem.filter(\.isHexDigit)
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
