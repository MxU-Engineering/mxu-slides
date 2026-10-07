import Foundation
import MachO

public struct BuildIdentity: Equatable, Sendable {
    public var version: String
    public var build: String

    public var commit: String?

    public static let commitKey = "MXUGitCommit"

    public init(version: String, build: String, commit: String?) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    public init(info: [String: Any]?) {
        let commit = (info?[Self.commitKey] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            commit: commit.isEmpty || commit.contains("$(") ? nil : commit)
    }

    public var commitLabel: String {
        commit ?? "unknown"
    }

    public var reportFields: [String: String] {
        ["app_version": version, "app_build": build, "app_commit": commitLabel]
    }

    public func launchLine(os: String, image: LoadedImage?) -> String {
        let base = "v\(version) (\(build)) commit \(commitLabel) on macOS \(os)"
        if let image {
            return base + ", image \(image.description)"
        } else {
            return base + ", image unknown"
        }
    }
}

public struct LoadedImage: Equatable, Sendable {
    public var name: String
    public var loadAddress: UInt
    public var uuid: UUID?

    public init(name: String, loadAddress: UInt, uuid: UUID?) {
        self.name = name
        self.loadAddress = loadAddress
        self.uuid = uuid
    }

    public init?(containing address: UnsafeRawPointer) {
        var info = Dl_info()
        if dladdr(address, &info) != 0, let base = info.dli_fbase {
            let path = info.dli_fname.map { String(cString: $0) } ?? "?"
            self.init(
                name: (path as NSString).lastPathComponent,
                loadAddress: UInt(bitPattern: base),
                uuid: Self.uuid(inMachHeader: UnsafeRawPointer(base)))
        } else {
            return nil
        }
    }

    public var description: String {
        "\(name) at 0x\(String(loadAddress, radix: 16)) uuid \(uuid?.uuidString ?? "unknown")"
    }

    public static func uuid(inMachHeader header: UnsafeRawPointer) -> UUID? {
        let mach = header.loadUnaligned(as: mach_header_64.self)
        var found: UUID?
        if mach.magic == MH_MAGIC_64 {
            var cursor = header + MemoryLayout<mach_header_64>.size
            var remaining = mach.ncmds
            while remaining > 0, found == nil {
                let command = cursor.loadUnaligned(as: load_command.self)
                if command.cmd == UInt32(LC_UUID) {
                    found = UUID(uuid: cursor.loadUnaligned(as: uuid_command.self).uuid)
                }
                cursor += Int(command.cmdsize)
                remaining -= 1
            }
        }
        return found
    }
}
