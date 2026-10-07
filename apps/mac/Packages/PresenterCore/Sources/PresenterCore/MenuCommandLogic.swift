import Foundation

public struct MenuAction: Equatable {
    public let id: String
    public let run: () -> Void

    public init(_ id: String, run: @escaping () -> Void) {
        self.id = id
        self.run = run
    }

    public func callAsFunction() {
        run()
    }

    public static func == (lhs: MenuAction, rhs: MenuAction) -> Bool {
        lhs.id == rhs.id
    }
}

public enum UndoMenuLogic {
    public enum Target: Equatable {

        case editor

        case journal

        case responderChain

        case nothing
    }

    public static func target(editorOpen: Bool, fieldEditorCan: Bool, journalCan: Bool) -> Target {
        if editorOpen {
            .editor
        } else if fieldEditorCan {
            .responderChain
        } else if journalCan {
            .journal
        } else {
            .nothing
        }
    }

    public static func disabled(editorOpen: Bool, editorCan: Bool) -> Bool {
        editorOpen && !editorCan
    }
}
