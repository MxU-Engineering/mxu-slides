import AVFoundation
import CoreVideo
import Foundation
import OutputEngine
import QuartzCore

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: recorder-kill-harness <output.mov>\n".utf8))
    exit(64)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

let configuration = RecordingConfiguration(
    codec: .h264, width: 1280, height: 720, frameRate: 30, fragmentInterval: 1)
let recorder: Recorder
do {
    recorder = try Recorder(url: url, configuration: configuration)
} catch {
    FileHandle.standardError.write(Data("recorder init failed: \(error)\n".utf8))
    exit(70)
}

var pixelBufferOut: CVPixelBuffer?
CVPixelBufferCreate(
    kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
    &pixelBufferOut)
guard let pixelBuffer = pixelBufferOut else { exit(70) }

CVPixelBufferLockBaseAddress(pixelBuffer, [])
if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {

    memset(base, 0x80, CVPixelBufferGetBytesPerRow(pixelBuffer) * 720)
}
CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

print("HARNESS_RECORDING")
fflush(stdout)

while true {
    recorder.append(pixelBuffer, atHostSeconds: CACurrentMediaTime())
    Thread.sleep(forTimeInterval: 1.0 / 30.0)
}
