import CoreVideo
import Foundation
import IOSurface
import NDIKit

final class NDIHelperService: NSObject, NDIHelperProtocol {
    private var sender: NDISender?
    private var senderName: String?
    private var frameRate: (numerator: Int32, denominator: Int32) = (30_000, 1_000)

    func startSender(
        name: String,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32,
        reply: @escaping (String?) -> Void
    ) {
        sender = nil
        do {
            let library = try NDILibrary.load()
            frameRate = (frameRateNumerator, frameRateDenominator)
            guard let fresh = NDISender(library: library, name: name) else {
                reply("NDI sender could not be created")
                return
            }
            sender = fresh
            senderName = name
            reply(nil)
        } catch {
            reply("NDI runtime unavailable: \(error)")
        }
    }

    func reloadNetworkPin(reply: @escaping (String?) -> Void) {

        sender = nil
        guard NDILibrary.reinitialize() else {
            reply("NDI runtime would not settle — the pin applies at the next send")
            return
        }
        guard let name = senderName else {
            reply(nil)
            return
        }
        startSender(
            name: name,
            frameRateNumerator: frameRate.numerator,
            frameRateDenominator: frameRate.denominator,
            reply: reply)
    }

    func sendFrame(_ surface: IOSurface, reply: @escaping () -> Void) {
        defer { reply() }
        guard let sender else { return }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        let surfaceRef = unsafeBitCast(surface, to: IOSurfaceRef.self)
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surfaceRef, nil, &unmanaged) == kCVReturnSuccess,
            let pixelBuffer = unmanaged?.takeRetainedValue()
        else { return }
        sender.send(
            pixelBuffer: pixelBuffer,
            frameRateNumerator: frameRate.numerator,
            frameRateDenominator: frameRate.denominator)
    }

    func stopSender() {
        sender = nil
        senderName = nil
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NDIHelperProtocol.self)
        connection.exportedObject = NDIHelperService()
        connection.resume()
        return true
    }
}

NDIRuntimeConfig.adopt()

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
