import CoreVideo
import Foundation
import VideoToolbox

final class PixelScaler {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolHDR = false

    func transfer(_ source: CVPixelBuffer, width: Int, height: Int, hdr: Bool) -> CVPixelBuffer? {
        if session == nil {
            var fresh: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &fresh)
            guard let fresh else { return nil }
            VTSessionSetProperty(
                fresh, key: kVTPixelTransferPropertyKey_ScalingMode,
                value: kVTScalingMode_Letterbox)
            session = fresh
        }
        if pool == nil || poolWidth != width || poolHeight != height || poolHDR != hdr {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: hdr
                    ? kCVPixelFormatType_ARGB2101010LEPacked
                    : kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var fresh: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &fresh)
            pool = fresh
            poolWidth = width
            poolHeight = height
            poolHDR = hdr

            if let session {
                VTSessionSetProperty(
                    session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                    value: hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(
                    session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                    value: hdr ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2)
                VTSessionSetProperty(
                    session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                    value: hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
        }
        guard let session, let pool else { return nil }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess,
              let target else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: target) == noErr else {
            return nil
        }

        if hdr {
            CVBufferSetAttachment(target, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(target, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(target, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        } else {
            CVBufferSetAttachment(target, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(target, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        return target
    }
}
