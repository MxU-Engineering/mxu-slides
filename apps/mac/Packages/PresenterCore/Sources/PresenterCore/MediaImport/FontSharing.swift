import CoreText
import CryptoKit
import Foundation

public enum FontSharing {

    public struct Face: Equatable, Sendable {
        public var name: String
        public var family: String
        public var url: URL

        public init(name: String, family: String, url: URL) {
            self.name = name
            self.family = family
            self.url = url
        }
    }

    public static func names(in value: some Encodable) -> Set<String> {
        var found = Set<String>()
        if let data = try? JSONEncoder().encode(value), let tree = try? JSONSerialization.jsonObject(with: data) {
            collect(tree, into: &found)
        }
        return found
    }

    private static func collect(_ node: Any, into found: inout Set<String>) {
        if let map = node as? [String: Any] {
            for (key, child) in map {
                if key == "fontName" || key == "fontFamily", let name = child as? String, !name.isEmpty {
                    found.insert(name)
                } else {
                    collect(child, into: &found)
                }
            }
        } else if let list = node as? [Any] {
            for child in list { collect(child, into: &found) }
        }
    }

    public static func isSystem(path: String) -> Bool {
        ["/System/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    public static func isShareable(path: String, data: Data) -> Bool {
        !isSystem(path: path) && FontActivator.sniffExtension(data) != nil && FontActivator.isEmbeddingAllowed(data)
    }

    public static func filesToShare(names: Set<String>, shared: Set<String>, resolve: (String) -> [Face]) -> [URL: [Face]] {
        var files: [URL: [Face]] = [:]
        for name in names.sorted() where !shared.contains(name) {
            for face in resolve(name) where !isSystem(path: face.url.path) && !shared.contains(face.name) {
                if !(files[face.url]?.contains(face) ?? false) {
                    files[face.url, default: []].append(face)
                }
            }
        }
        return files
    }

    public static func needsInstall(faces: [String], available: (String) -> Bool) -> Bool {
        faces.isEmpty || faces.contains { !available($0) }
    }

    public static func resolve(_ name: String) -> [Face] {
        let byName = CTFontDescriptorCreateWithNameAndSize(name as CFString, 0)
        let exact = face(of: byName).map { $0.name == name ? [$0] : [] } ?? []
        if exact.isEmpty {
            let family = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            let matches = CTFontDescriptorCreateMatchingFontDescriptors(family, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor] ?? []
            return matches.compactMap(face(of:)).filter { $0.family == name }
        } else {
            return exact
        }
    }

    public static func isAvailable(_ name: String) -> Bool {
        face(of: CTFontDescriptorCreateWithNameAndSize(name as CFString, 0))?.name == name
    }

    public static func faces(inFileAt url: URL) -> (family: String, faces: [String])? {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        let family = descriptors.first.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        return family.map { (family: $0, faces: names) }
    }

    private static func face(of descriptor: CTFontDescriptor) -> Face? {
        let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
        if let name, let family, let url {
            return Face(name: name, family: family, url: url)
        } else {
            return nil
        }
    }

    public static func document(forFileAt url: URL) -> FontFile? {
        if let data = try? Data(contentsOf: url), isShareable(path: url.path, data: data),
           let ext = FontActivator.sniffExtension(data), let inside = faces(inFileAt: url) {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return FontFile(id: hash, family: inside.family, faces: inside.faces, ext: ext, byteSize: data.count)
        } else {
            return nil
        }
    }
}

