import CDeckLink
import Foundation

public struct DeckLinkDevice: Sendable, Equatable, Codable {
    public let name: String

    public let persistentID: Int64
    public let supportsPlayback: Bool
    public let supportsInternalKeying: Bool
    public let supportsExternalKeying: Bool

    public init(
        name: String, persistentID: Int64, supportsPlayback: Bool,
        supportsInternalKeying: Bool, supportsExternalKeying: Bool
    ) {
        self.name = name
        self.persistentID = persistentID
        self.supportsPlayback = supportsPlayback
        self.supportsInternalKeying = supportsInternalKeying
        self.supportsExternalKeying = supportsExternalKeying
    }
}

public struct DeckLinkDisplayMode: Sendable, Equatable, Codable {
    public let name: String

    public let modeID: UInt32
    public let width: Int
    public let height: Int

    public let frameDuration: Int64
    public let timeScale: Int64
    public let progressive: Bool

    public let supportsKeying: Bool

    public init(
        name: String, modeID: UInt32, width: Int, height: Int,
        frameDuration: Int64, timeScale: Int64, progressive: Bool,
        supportsKeying: Bool = true
    ) {
        self.name = name
        self.modeID = modeID
        self.width = width
        self.height = height
        self.frameDuration = frameDuration
        self.timeScale = timeScale
        self.progressive = progressive
        self.supportsKeying = supportsKeying
    }

    public var framesPerSecond: Double {
        Double(timeScale) / Double(frameDuration)
    }

    public static func bestMatch(
        width: Int, height: Int, framesPerSecond: Int,
        in modes: [DeckLinkDisplayMode]
    ) -> DeckLinkDisplayMode? {
        let target = Double(framesPerSecond)
        let candidates = modes.filter {
            $0.width == width && $0.height == height
                && abs($0.framesPerSecond - target) / target <= 0.002
        }
        return candidates.min { lhs, rhs in
            let lhsExact = lhs.timeScale % lhs.frameDuration == 0
                && lhs.timeScale / lhs.frameDuration == Int64(framesPerSecond)
            let rhsExact = rhs.timeScale % rhs.frameDuration == 0
                && rhs.timeScale / rhs.frameDuration == Int64(framesPerSecond)
            if lhsExact != rhsExact { return rhsExact }
            if lhs.progressive != rhs.progressive { return lhs.progressive }
            return false
        }
    }
}

public enum DeckLinkRuntime {

    public static var isAvailable: Bool {
        dlk_runtime_available()
    }

    public static let requiredAPIMajor: Int64 = 16

    public static var apiVersionString: String? {
        let raw = dlk_api_version()
        guard raw != 0 else { return nil }
        return "\((raw >> 24) & 0xFF).\((raw >> 16) & 0xFF).\((raw >> 8) & 0xFF)"
    }

    public static var runtimeIsTooOld: Bool {
        let raw = dlk_api_version()
        return raw != 0 && (raw >> 24) & 0xFF < requiredAPIMajor
    }

    public static func configuredOutputMode(persistentID: Int64) -> UInt32? {
        let mode = dlk_configured_output_mode(persistentID)
        return mode == 0 ? nil : mode
    }

    public static func referenceLocked(persistentID: Int64) -> Bool {
        dlk_reference_locked(persistentID)
    }

    public static func outputLinkConfiguration(persistentID: Int64) -> String? {
        switch dlk_output_link_configuration(persistentID) {
        case 0x6C63736C: return "single"
        case 0x6C63646C: return "dual"
        case 0x6C63716C: return "quad"
        default: return nil
        }
    }

    public static func displayModes(persistentID: Int64) -> [DeckLinkDisplayMode] {
        let capacity = 128
        var raw = [DLKDisplayModeInfo](
            repeating: DLKDisplayModeInfo(), count: capacity)
        let count = raw.withUnsafeMutableBufferPointer { buffer in
            dlk_copy_display_modes(persistentID, buffer.baseAddress, Int32(capacity))
        }
        return raw.prefix(Int(count)).map { info in
            DeckLinkDisplayMode(
                name: withUnsafeBytes(of: info.name) { bytes in
                    String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
                },
                modeID: info.modeID,
                width: Int(info.width),
                height: Int(info.height),
                frameDuration: info.frameDuration,
                timeScale: info.timeScale,
                progressive: info.progressive,
                supportsKeying: info.supportsKeying
            )
        }
    }

    public static func devices() -> [DeckLinkDevice] {
        let capacity = 16
        var raw = [DLKDeviceInfo](repeating: DLKDeviceInfo(), count: capacity)
        let count = raw.withUnsafeMutableBufferPointer { buffer in
            dlk_copy_devices(buffer.baseAddress, Int32(capacity))
        }
        return raw.prefix(Int(count)).map { info in
            DeckLinkDevice(
                name: withUnsafeBytes(of: info.name) { bytes in
                    String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
                },
                persistentID: info.persistentID,
                supportsPlayback: info.supportsPlayback,
                supportsInternalKeying: info.supportsInternalKeying,
                supportsExternalKeying: info.supportsExternalKeying
            )
        }
    }
}
