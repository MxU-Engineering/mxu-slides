import Foundation

public struct MediaWant: Sendable, Equatable {

    public var placeholderID: String

    public var absolutePath: String?

    public var relativePath: String?

    public var inPoint: Double?
    public var outPoint: Double?
    public var playRate: Double?
    public var fadeSeconds: Double?

    public var classification: MediaClassification?

    public var loops: Bool?

    public init(
        placeholderID: String, absolutePath: String?, relativePath: String?,
        inPoint: Double? = nil, outPoint: Double? = nil,
        playRate: Double? = nil, fadeSeconds: Double? = nil
    ) {
        self.placeholderID = placeholderID
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.playRate = playRate
        self.fadeSeconds = fadeSeconds
    }
}
