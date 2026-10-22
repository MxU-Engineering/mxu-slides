import Foundation

public enum EditSidebarLogic {
    public static let settingKey = "edit.hideSidebar"

    public static let rememberedKey = "shell.sidebarBeforeEdit"

    public struct Result: Equatable, Sendable {
        public var visible: Bool
        public var remembered: Bool?

        public init(visible: Bool, remembered: Bool?) {
            self.visible = visible
            self.remembered = remembered
        }
    }

    public static func switching(
        from old: String, to new: String, visible: Bool, hideOnEdit: Bool, remembered: Bool?
    ) -> Result {
        if new == "edit", old != "edit", hideOnEdit {
            Result(visible: false, remembered: visible)
        } else if old == "edit", new != "edit", let remembered {
            Result(visible: remembered, remembered: nil)
        } else {
            Result(visible: visible, remembered: remembered)
        }
    }
}
