import AVFoundation
import CoreGraphics
import CoreText
import Foundation

public enum SyncTestPattern {
    public static let name = "MxU Sync Test"
    public static let framesPerSecond = 30
    public static let beatsPerMinute = 120
    public static let framesPerBeat = framesPerSecond * 60 / beatsPerMinute
    public static let beatsPerBar = 4
    public static let framesPerBar = framesPerBeat * beatsPerBar
    public static let barsPerLoop = 4
    public static let loopFrames = framesPerBar * barsPerLoop
    public static let flashFrames = 3
    public static let clickSeconds = 0.040

    public static let downbeatSeconds = 0.160
    public static let clickHertz = 1_000.0
    public static let downbeatHertz = 1_500.0
    public static let size = CGSize(width: 1920, height: 1080)

    public static func isFlash(frame: Int) -> Bool {
        frame % framesPerBeat < flashFrames
    }

    public static func isDownbeat(frame: Int) -> Bool {
        frame % framesPerBar < framesPerBeat
    }

    public static func audio(loops: Int = 1) -> [Float] {
        let rate = MediaAuthoring.audioSampleRate
        let samplesPerBeat = Int(rate) * 60 / beatsPerMinute
        let beats = beatsPerBar * barsPerLoop * loops
        var samples = [Float](repeating: 0, count: samplesPerBeat * beats)
        let ramp = Int(0.002 * rate)
        for beat in 0..<beats {
            let downbeat = beat % beatsPerBar == 0
            let hertz = downbeat ? downbeatHertz : clickHertz
            let click = Int((downbeat ? downbeatSeconds : clickSeconds) * rate)
            for index in 0..<click {
                let envelope = min(1, Double(min(index, click - index)) / Double(ramp))
                samples[beat * samplesPerBeat + index] = Float(
                    0.5 * envelope * sin(2 * .pi * hertz * Double(index) / rate))
            }
        }
        return samples
    }

    public static func write(to url: URL, loops: Int = 1) async throws {
        try await MediaAuthoring.writeMovie(
            to: url, codec: .h264, size: size,
            frameCount: loopFrames * loops,
            framesPerSecond: Int32(framesPerSecond),
            monoAudio: audio(loops: loops)
        ) { context, frame in
            draw(frame: frame, in: context, size: size)
        }
    }

    public static let version = 3

    static let writeAttempts = 3

    public static func cachedMovie(
        in directory: URL,
        write: (URL) async throws -> Void = { try await SyncTestPattern.write(to: $0) }
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sync-test-v\(version).mov")
        if !FileManager.default.fileExists(atPath: url.path) {

            let partial = directory.appendingPathComponent("sync-test-v\(version).partial.mov")
            var attempt = 0
            var written = false
            while !written {
                attempt += 1
                try? FileManager.default.removeItem(at: partial)
                do {
                    try await write(partial)
                    written = true
                } catch where attempt < writeAttempts {
                    continue
                }
            }
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return url
    }

    static let symbolCenter = CGPoint(x: 150, y: 930)
    static let symbolRadius = 70.0

    static func draw(frame: Int, in context: CGContext, size: CGSize) {
        let s = size.width / Self.size.width
        context.saveGState()
        context.scaleBy(x: s, y: s)
        let w = Self.size.width
        let h = Self.size.height
        let frameInLoop = frame % loopFrames
        let frameInBar = frameInLoop % framesPerBar
        let bar = frameInLoop / framesPerBar + 1
        let beat = frameInBar / framesPerBeat + 1
        let frameInBeat = frameInBar % framesPerBeat
        let flash = isFlash(frame: frame)
        let downbeat = isDownbeat(frame: frame)
        let orange = CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)
        let dim = CGColor(gray: 0.35, alpha: 1)

        if flash, downbeat {
            context.setFillColor(orange)
        } else {
            context.setFillColor(gray: 0.06, alpha: 1)
        }
        context.fill(CGRect(origin: .zero, size: Self.size))

        let symbol = CGRect(
            x: symbolCenter.x - symbolRadius, y: symbolCenter.y - symbolRadius,
            width: symbolRadius * 2, height: symbolRadius * 2)
        if flash {
            context.setFillColor(white)
            context.fillEllipse(in: symbol)
        } else {
            context.setStrokeColor(dim)
            context.setLineWidth(4)
            context.strokeEllipse(in: symbol.insetBy(dx: 2, dy: 2))
        }

        text("\(name)   \(beatsPerMinute) BPM   \(framesPerSecond) fps", size: 48,
             color: CGColor(gray: 0.6, alpha: 1), at: CGPoint(x: 300, y: 905), in: context)

        let center = CGPoint(x: w / 2, y: h / 2 + 40)
        let radius = 270.0
        let wedge = CGMutablePath()
        wedge.move(to: center)
        let sweep = Double(frameInBar + 1) / Double(framesPerBar)
        for step in 0...Int(sweep * 360) {
            let angle = .pi / 2 - Double(step) / 180 * .pi
            wedge.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        }
        wedge.closeSubpath()
        context.addPath(wedge)
        context.setFillColor(downbeat ? CGColor(red: 0.5, green: 0.28, blue: 0.05, alpha: 1) : dim)
        context.fillPath()
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
        context.setLineWidth(6)
        context.strokeEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setLineWidth(2)
        for quarter in 0..<beatsPerBar {
            let angle = .pi / 2 - Double(quarter) / Double(beatsPerBar) * 2 * .pi
            context.move(to: center)
            context.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            context.strokePath()
        }
        text("\(beat)", size: 260, color: white, centeredAt: CGPoint(x: center.x, y: center.y - 90), in: context)

        let rulerY = 190.0
        let rulerLeft = 160.0
        let rulerWidth = w - rulerLeft * 2
        let tickSpacing = rulerWidth / Double(framesPerBar)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: rulerLeft, y: rulerY - 2, width: rulerWidth, height: 4))
        for tick in 0...framesPerBar {
            let x = rulerLeft + Double(tick) * tickSpacing
            let onBeat = tick % framesPerBeat == 0
            context.fill(CGRect(x: x - 1.5, y: rulerY, width: 3, height: onBeat ? 60 : 24))
            if onBeat, tick < framesPerBar {
                text("\(tick / framesPerBeat + 1)", size: 40, color: CGColor(gray: 0.6, alpha: 1),
                     at: CGPoint(x: x + 10, y: rulerY + 70), in: context)
            }
        }
        context.setFillColor(flash ? (downbeat ? orange : white) : CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: rulerLeft + Double(frameInBar) * tickSpacing - 4, y: rulerY - 60, width: 8, height: 130))

        text(String(format: "Bar %d   Beat %d   Frame %02d", bar, beat, frameInBeat), size: 40,
             color: CGColor(gray: 0.7, alpha: 1), at: CGPoint(x: rulerLeft, y: 80), in: context)
        context.restoreGState()
    }

    private static func line(_ string: String, size: CGFloat, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
                .foregroundColor: color,
            ]))
    }

    private static func text(_ string: String, size: CGFloat, color: CGColor, at origin: CGPoint, in context: CGContext) {
        context.textPosition = origin
        CTLineDraw(line(string, size: size, color: color), context)
    }

    private static func text(_ string: String, size: CGFloat, color: CGColor, centeredAt center: CGPoint, in context: CGContext) {
        let made = line(string, size: size, color: color)
        let width = CTLineGetTypographicBounds(made, nil, nil, nil)
        context.textPosition = CGPoint(x: center.x - width / 2, y: center.y)
        CTLineDraw(made, context)
    }
}
