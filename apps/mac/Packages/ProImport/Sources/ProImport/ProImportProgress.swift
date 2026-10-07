import Foundation

public struct ProImportProgress: Sendable, Equatable {
    public var phase: String
    public var detail: String
    public var completed: Int
    public var total: Int?

    public init(phase: String, detail: String = "", completed: Int = 0, total: Int? = nil) {
        self.phase = phase
        self.detail = detail
        self.completed = completed
        self.total = total
    }
}

public typealias ProImportProgressHandler = @MainActor (ProImportProgress) -> Void
