// Colour tags are layer-zero facts (spec L0). Every buffer and file Sharpy writes is tagged
// explicitly; every buffer it reads is interpreted by its tag. Untagged media gets the platform
// convention (601 for SD, 709 for HD) — and that assumption is reported, not hidden.

import AVFoundation
import CoreVideo

public enum YCbCrMatrix: UInt32, Sendable, CustomStringConvertible {
    case bt709 = 0, bt601 = 1, bt2020 = 2
    public var description: String { switch self { case .bt709: return "BT.709"; case .bt601: return "BT.601"; case .bt2020: return "BT.2020" } }
}

public struct ColorTag: Sendable, Equatable, CustomStringConvertible {
    public let matrix: YCbCrMatrix
    public let fullRange: Bool
    /// True when the matrix came from the platform default rather than the buffer's own tag.
    public let assumed: Bool
    public var description: String { "\(matrix) \(fullRange ? "full" : "video")-range\(assumed ? " (assumed)" : "")" }

    /// Read the matrix from a pixel buffer's attachments; fall back to the SD/HD convention.
    public static func of(_ pb: CVPixelBuffer) -> ColorTag {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return ColorTag(matrix: .bt709, fullRange: full, assumed: false) }
            if m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || m == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) { return ColorTag(matrix: .bt601, fullRange: full, assumed: false) }
            if m == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return ColorTag(matrix: .bt2020, fullRange: full, assumed: false) }
        }
        let hd = CVPixelBufferGetHeight(pb) >= 720
        return ColorTag(matrix: hd ? .bt709 : .bt601, fullRange: full, assumed: true)
    }

    /// Tag a buffer as BT.709 (the working convention for everything Sharpy produces until OCIO lands).
    public static func tag709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// AVAssetWriter colour properties for BT.709 output.
    public static var writer709: [String: Any] {
        [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }
}
