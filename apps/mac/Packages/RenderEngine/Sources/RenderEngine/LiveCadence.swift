import Foundation

public struct LiveCadence: Equatable, Sendable {
    public var lastArrival: CFTimeInterval

    public var period: Double

    public init(lastArrival: CFTimeInterval, period: Double) {
        self.lastArrival = lastArrival
        self.period = period
    }
}

extension MediaTextureSource {

    public func liveCadence(for mediaID: String) -> LiveCadence? { nil }
}

extension RenderScene {

    public var visibleMediaIDs: [String] {
        layers.filter { !$0.isHidden }.flatMap { $0.items.compactMap(\.content.mediaID) }
    }
}
