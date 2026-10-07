import Foundation
import IOSurface

@objc protocol NDIHelperProtocol {

    func startSender(
        name: String,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        reply: @escaping (String?) -> Void
    )

    func sendFrame(_ surface: IOSurface, reply: @escaping () -> Void)

    func stopSender()

    func reloadNetworkPin(reply: @escaping (String?) -> Void)

    func ping(reply: @escaping (Bool) -> Void)
}

enum NDIHelperIdentity {

    static let serviceName = "com.example.mxuslides.NDIHelper"
}
