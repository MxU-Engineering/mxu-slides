import CDeckLink
import Foundation

public struct DeckLinkInputFormat: Sendable, Equatable {
    public let name: String
    public let width: Int
    public let height: Int
    public let frameDuration: Int64
    public let timeScale: Int64
    public let interlaced: Bool

    public var framesPerSecond: Double {
        frameDuration == 0 ? 0 : Double(timeScale) / Double(frameDuration)
    }
}

public struct DeckLinkInputArrival {
    public let video: UnsafeRawPointer?
    public let rowBytes: Int
    public let width: Int
    public let height: Int
    public let interlaced: Bool
    public let hasSignal: Bool

    public let hostTime: Double
    public let captureHostTime: Double

    public let audio: UnsafePointer<Int32>?
    public let audioFrames: Int
    public let audioChannels: Int

    init(_ raw: DLKInputFrame) {
        video = raw.bytes.map { UnsafeRawPointer($0) }
        rowBytes = raw.rowBytes
        width = Int(raw.width)
        height = Int(raw.height)
        interlaced = raw.interlaced
        hasSignal = raw.hasSignal
        hostTime = raw.hostTime
        captureHostTime = raw.captureHostTime
        audio = raw.audio
        audioFrames = Int(raw.audioFrames)
        audioChannels = Int(raw.audioChannels)
    }
}

public final class DeckLinkInput: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (DeckLinkInputArrival) -> Void
    public typealias FormatHandler = @Sendable (DeckLinkInputFormat) -> Void

    private final class Handlers {
        let onFrame: FrameHandler
        let onFormat: FormatHandler
        init(onFrame: @escaping FrameHandler, onFormat: @escaping FormatHandler) {
            self.onFrame = onFrame
            self.onFormat = onFormat
        }
    }

    private let handlers: Handlers
    private let handle: OpaquePointer

    public init(
        persistentID: Int64, audioChannels: Int,
        onFrame: @escaping FrameHandler, onFormat: @escaping FormatHandler
    ) throws {
        let handlers = Handlers(onFrame: onFrame, onFormat: onFormat)
        self.handlers = handlers

        let context = Unmanaged.passUnretained(handlers).toOpaque()
        var error = [CChar](repeating: 0, count: 256)
        guard let opened = dlk_input_open(
            persistentID, Int32(audioChannels),
            { context, frame in
                guard let context, let frame else { return }
                Unmanaged<Handlers>.fromOpaque(context).takeUnretainedValue()
                    .onFrame(DeckLinkInputArrival(frame.pointee))
            },
            { context, name, width, height, duration, scale, interlaced in
                guard let context else { return }
                Unmanaged<Handlers>.fromOpaque(context).takeUnretainedValue()
                    .onFormat(DeckLinkInputFormat(
                        name: name.map { String(cString: $0) } ?? "",
                        width: Int(width), height: Int(height),
                        frameDuration: duration, timeScale: scale,
                        interlaced: interlaced))
            },
            context, &error, error.count)
        else {
            throw DeckLinkError.openFailed(String(cString: error))
        }
        handle = opened
    }

    deinit {
        dlk_input_close(handle)
    }

    public static func audioChannels(forMaximum maximum: Int) -> Int {
        if maximum >= 16 { return 16 }
        if maximum >= 8 { return 8 }
        return 2
    }
}
