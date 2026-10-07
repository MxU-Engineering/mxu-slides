import AppKit
import CoreGraphics

public typealias DisplayUUID = String

public struct DisplaySnapshot: Identifiable, Equatable, Sendable {
    public var id: DisplayUUID { uuid }
    public let uuid: DisplayUUID
    public let displayID: CGDirectDisplayID
    public let name: String

    public let frame: CGRect
    public let maximumFramesPerSecond: Int
    public let isMain: Bool

    public init(
        uuid: DisplayUUID,
        displayID: CGDirectDisplayID,
        name: String,
        frame: CGRect,
        maximumFramesPerSecond: Int,
        isMain: Bool
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.isMain = isMain
    }

    @MainActor
    public static func connectedDisplays() -> [DisplaySnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuidRef) as String?
            else { return nil }
            return DisplaySnapshot(
                uuid: uuidString,
                displayID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                maximumFramesPerSecond: screen.maximumFramesPerSecond,
                isMain: displayID == CGMainDisplayID()
            )
        }
    }

    @MainActor
    public func currentScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuidRef) as String?
            else { return false }
            return uuidString == uuid
        }
    }
}
