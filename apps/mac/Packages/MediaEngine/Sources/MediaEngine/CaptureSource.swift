import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import RenderEngine

final class CaptureSource: NSObject, @unchecked Sendable {
    private let device: AVCaptureDevice

    private let frameRate: Double?
    private let session: AVCaptureSession
    private let deliveryQueue: DispatchQueue
    private let latest = Locked<CVPixelBuffer?>(nil)
    private let sizeBox = Locked<CGSize>(.zero)
    private let lastFrameHostTime = Locked<CFTimeInterval?>(nil)
    private let arrivals = Locked(ArrivalWindow())

    var naturalSize: CGSize { sizeBox.value }

    init(device: AVCaptureDevice, frameRate: Double? = nil) throws {
        self.device = device
        self.frameRate = frameRate
        session = AVCaptureSession()
        deliveryQueue = DispatchQueue(
            label: "mediaEngine.capture.\(device.uniqueID)", qos: .userInitiated)
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw MediaEngineError.captureSetupFailed(device.localizedName)
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard session.canAddOutput(output) else {
            throw MediaEngineError.captureSetupFailed(device.localizedName)
        }
        session.addOutput(output)
    }

    func start() {

        deliveryQueue.async { [self] in

            let locked = (try? device.lockForConfiguration()) != nil
            if locked {
                applyBestFormat()
            } else {
                MediaEngine.captureNote.value?("format: \(device.localizedName) busy, left at default")
            }
            session.startRunning()
            if locked { device.unlockForConfiguration() }
        }
    }

    private func applyBestFormat() {
        let formats = device.formats
        let (candidates, active) = Self.candidates(of: device)
        let defaultRate = Self.rate(of: device.activeVideoMinFrameDuration)
        let choice = CaptureFormatChoice.best(among: candidates, active: active, preferred: frameRate)
        let range = choice.flatMap { choice in
            formats[choice.index].videoSupportedFrameRateRanges
                .first { $0.maxFrameRate == choice.frameRate }
        }
        if let choice, let range {
            device.activeFormat = formats[choice.index]

            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
            MediaEngine.captureNote.value?(String(
                format: "format: %@ %dx%d @%.2f (default @%.2f)",
                device.localizedName, active.width, active.height,
                choice.frameRate, defaultRate))
        } else {
            MediaEngine.captureNote.value?(String(
                format: "format: %@ %dx%d left at default @%.2f",
                device.localizedName, active.width, active.height, defaultRate))
        }
    }

    static func candidates(
        of device: AVCaptureDevice
    ) -> (all: [CaptureFormatChoice.Candidate], active: CaptureFormatChoice.Candidate) {
        let formats = device.formats
        return (
            formats.enumerated().map { candidate($1, index: $0) },
            candidate(device.activeFormat, index: formats.firstIndex(of: device.activeFormat) ?? 0))
    }

    private static func candidate(_ format: AVCaptureDevice.Format, index: Int) -> CaptureFormatChoice.Candidate {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return CaptureFormatChoice.Candidate(
            index: index,
            width: Int(dimensions.width), height: Int(dimensions.height),
            subtype: CMFormatDescriptionGetMediaSubType(format.formatDescription),
            frameRates: format.videoSupportedFrameRateRanges.map(\.maxFrameRate))
    }

    private static func rate(of frameDuration: CMTime) -> Double {
        frameDuration.seconds > 0 ? 1 / frameDuration.seconds : 0
    }

    func stop() {
        deliveryQueue.async { [session] in session.stopRunning() }
    }

    func latestFrame() -> CVPixelBuffer? {
        latest.value
    }

    var cadence: LiveCadence? { arrivals.value.cadence }

    func frameAge(at hostTime: CFTimeInterval) -> Double? {
        lastFrameHostTime.value.map { max(0, hostTime - $0) }
    }
}

extension CaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sizeBox.value = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer))
        latest.value = pixelBuffer
        let now = CACurrentMediaTime()
        lastFrameHostTime.value = now
        arrivals.withLock { $0.record(now) }
        RenderPulse.shared.captureFrame(source: device.localizedName)
    }
}
