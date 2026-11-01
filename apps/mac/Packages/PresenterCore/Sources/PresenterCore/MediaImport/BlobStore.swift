import CryptoKit
import Foundation

public struct BlobStore: Sendable {
    public let directory: URL

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var byStem: [String: URL]?

        private var absent: Set<String> = []
        private var listedStamp: Stamp?

        private var listings = 0

        var listingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return listings
        }

        func url(forHash hash: String, directory: URL) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            listIfStale(directory)
            return verified(hash, directory: directory)
        }

        func presence(forHashes hashes: some Sequence<String>, directory: URL) -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            listIfStale(directory)
            return Set(hashes.filter { verified($0, directory: directory) != nil })
        }

        private func verified(_ hash: String, directory: URL) -> URL? {
            var found = lookup(hash)
            if let hit = found, !FileManager.default.fileExists(atPath: hit.path) {
                list(directory)
                found = lookup(hash)
            }
            return found
        }

        func note(hash: String, url: URL) {
            lock.lock()
            defer { lock.unlock() }
            byStem?[hash] = url
            absent.remove(hash)
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            byStem = nil
            absent = []
            listedStamp = nil
        }

        private func listIfStale(_ directory: URL) {
            if byStem == nil || Self.stamp(of: directory) != listedStamp {
                list(directory)
            }
        }

        private func list(_ directory: URL) {
            listedStamp = Self.stamp(of: directory)
            byStem = Dictionary(
                ((try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                )) ?? []).map { ($0.deletingPathExtension().lastPathComponent, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            absent = []
            listings += 1
        }

        private func lookup(_ hash: String) -> URL? {
            var found: URL?
            if !absent.contains(hash) {
                found = byStem?[hash] ?? byStem?.first { $0.key.hasPrefix(hash) }?.value
                if found == nil { absent.insert(hash) }
            }
            return found
        }

        private struct Stamp: Equatable {
            var seconds: Int
            var nanoseconds: Int
        }

        private static func stamp(of directory: URL) -> Stamp? {
            var info = stat()
            let status = directory.withUnsafeFileSystemRepresentation { path in
                path.map { stat($0, &info) } ?? -1
            }
            return status == 0
                ? Stamp(seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
                : nil
        }
    }

    private let cache = Cache()

    public init(libraryRoot: URL) throws {
        directory = libraryRoot.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func store(fileURL: URL) throws -> String {
        let hash = try Self.sha256(of: fileURL)
        let destination = url(forHash: hash, ext: fileURL.pathExtension)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: fileURL, to: destination)
            Self.stampKnown(destination)
        }
        cache.note(hash: hash, url: destination)
        return hash
    }

    public func adopt(fileURL: URL) throws -> String {
        let hash = try Self.sha256(of: fileURL)
        let destination = url(forHash: hash, ext: fileURL.pathExtension)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            Self.stampKnown(destination)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        cache.note(hash: hash, url: destination)
        return hash
    }

    static let knownTimeAttribute = "com.getmxu.slides.known-mtime"

    public static func stampKnown(_ url: URL) {
        guard let time = modificationTime(url) else { return }
        let write = { time.withCString { setxattr(url.path, knownTimeAttribute, $0, strlen($0), 0, 0) } }
        if write() != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            _ = write()
        }
    }

    static func knownTime(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let count = getxattr(url.path, knownTimeAttribute, &buffer, buffer.count - 1, 0, 0)
        return count > 0 ? String(cString: buffer) : nil
    }

    public static func modificationTime(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    public func editedFiles(now: Date = Date(), settle: TimeInterval) -> (settled: [(hash: String, url: URL)], settling: Bool) {
        var settled: [(hash: String, url: URL)] = []
        var settling = false
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            let hash = url.deletingPathExtension().lastPathComponent
            guard hash.count == 64, let time = Self.modificationTime(url), Self.knownTime(url) != time else { continue }
            if Self.isSettled(url, settle: settle, now: now) {
                settled.append((hash, url))
            } else {
                settling = true
            }
        }
        return (settled, settling)
    }

    public static func isSettled(_ url: URL, settle: TimeInterval, now: Date = Date()) -> Bool {

        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) >= settle
    }

    public func unlockAll() {
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where !FileManager.default.isWritableFile(atPath: url.path) {
            Self.stampKnown(url)
        }
    }

    public func url(forHash hash: String) -> URL? {
        cache.url(forHash: hash, directory: directory)
    }

    public func presence(forHashes hashes: some Sequence<String>) -> Set<String> {
        cache.presence(forHashes: hashes, directory: directory)
    }

    public func noteDirectoryChanged() {
        cache.invalidate()
    }

    var directoryListings: Int { cache.listingCount }

    @discardableResult
    public func remove(hash: String) throws -> Bool {
        if let stored = url(forHash: hash) {
            try FileManager.default.removeItem(at: stored)
            cache.invalidate()
            return true
        } else {
            return false
        }
    }

    public func allHashes() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private func url(forHash hash: String, ext: String) -> URL {
        let name = ext.isEmpty ? hash : "\(hash).\(ext.lowercased())"
        return directory.appendingPathComponent(name)
    }

    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
