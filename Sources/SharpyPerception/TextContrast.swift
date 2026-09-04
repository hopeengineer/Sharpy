// Can the caption actually be read?
//
// The safe-area and duration checks ask where text is and how long it stays. Neither asks the
// question a viewer asks, which is whether it is legible at all. White text over a bright sky is
// inside the safe area, on screen for six seconds, and invisible.
//
// Measured as WCAG 2.1 defines contrast: relative luminance of the lighter and darker elements,
// (L1 + 0.05) / (L2 + 0.05). WCAG is a text-legibility standard rather than a video one, which is
// why this is cited as a craft rule with its source rather than as a platform requirement — but
// its 4.5:1 and 3:1 thresholds are the only widely published, measurable numbers for the question,
// and using a real standard beats inventing a threshold.
//
// Text and background are separated by percentile rather than by segmentation. Inside a tight text
// box the pixels are close to bimodal — glyph and ground — so the 10th and 90th percentiles are
// good stand-ins for the two elements, and unlike a mean they are not dragged around by antialiasing
// at the glyph edges. It is an approximation, and it is stated as one.

import Foundation
import AVFoundation
import CoreVideo
import SharpyEngine
import SharpyRender

public struct TextContrastReading: Sendable {
    public let time: TimeValue
    public let text: String
    /// WCAG contrast ratio, 1…21.
    public let ratio: Double
    public let lighterLuminance: Double
    public let darkerLuminance: Double

    /// WCAG 2.1 AA for large text, which is what a caption burned into a frame is.
    public var meetsLargeTextAA: Bool { ratio >= 3.0 }
    /// AA for body text — the stricter bar, reported so a caller can choose.
    public var meetsNormalTextAA: Bool { ratio >= 4.5 }
}

public enum TextContrastError: Error, CustomStringConvertible {
    case noFrame(TimeValue)
    public var description: String {
        switch self {
        case .noFrame(let t): return "no frame at \(t) to measure contrast against"
        }
    }
}

public struct TextContrastMeter: Sendable {
    /// Percentile treated as the background, and its complement as the text.
    public let lowPercentile: Double
    public let highPercentile: Double

    public init(lowPercentile: Double = 0.1, highPercentile: Double = 0.9) {
        self.lowPercentile = lowPercentile
        self.highPercentile = highPercentile
    }

    /// WCAG relative luminance from non-linear sRGB in 0…1.
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    public static func ratio(lighter: Double, darker: Double) -> Double {
        (max(lighter, darker) + 0.05) / (min(lighter, darker) + 0.05)
    }

    /// Measure every text line an observation found, against the frame it was found in.
    public func measure(url: URL, vision: VisionIndex,
                        limit: Int = Int.max) throws -> [TextContrastReading] {
        let source = try SequentialFrameSource(url: url)
        var readings: [TextContrastReading] = []
        for observation in vision.frames {
            guard !observation.text.isEmpty else { continue }
            guard let frame = try source.frame(at: observation.time) else { continue }
            let luminances = try luminancePlane(frame.pixelBuffer)
            for line in observation.text {
                guard readings.count < limit else { return readings }
                guard let reading = measure(line: line, in: luminances, at: observation.time) else { continue }
                readings.append(reading)
            }
        }
        return readings
    }

    private struct LuminanceImage {
        let values: [Double]     // 0…1 relative luminance
        let width: Int
        let height: Int
    }

    /// Decode once per frame into relative luminance. BGRA is converted properly rather than by
    /// averaging channels — green carries most of perceived brightness, and a channel average
    /// would call yellow-on-white high contrast.
    private func luminancePlane(_ buffer: CVPixelBuffer) throws -> LuminanceImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var values = [Double](repeating: 0, count: width * height)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        if format == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return LuminanceImage(values: values, width: width, height: height) }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let p = bytes + y * stride + x * 4
                    values[y * width + x] = Self.relativeLuminance(r: Double(p[2]) / 255,
                                                                   g: Double(p[1]) / 255,
                                                                   b: Double(p[0]) / 255)
                }
            }
        } else {
            // Bi-planar YCbCr: the luma plane already IS brightness, and for a contrast ratio the
            // chroma contributes little. Video-range is undone so 16…235 maps to 0…1.
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return LuminanceImage(values: values, width: width, height: height) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            for y in 0..<height {
                for x in 0..<width {
                    let raw = Double(bytes[y * stride + x]) / 255
                    let normalised = full ? raw : min(max((raw * 255 - 16) / 219, 0), 1)
                    // The luma plane is non-linear; apply the same transfer WCAG expects.
                    values[y * width + x] = Self.relativeLuminance(r: normalised, g: normalised, b: normalised)
                }
            }
        }
        return LuminanceImage(values: values, width: width, height: height)
    }

    private func measure(line: TextLine, in image: LuminanceImage, at time: TimeValue) -> TextContrastReading? {
        let x0 = max(0, Int(line.box.x)), y0 = max(0, Int(line.box.y))
        let x1 = min(image.width, Int(line.box.maxX)), y1 = min(image.height, Int(line.box.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        var samples: [Double] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            let row = y * image.width
            for x in x0..<x1 { samples.append(image.values[row + x]) }
        }
        guard samples.count >= 16 else { return nil }   // too few pixels to have two elements
        samples.sort()
        let dark = samples[Int(Double(samples.count - 1) * lowPercentile)]
        let light = samples[Int(Double(samples.count - 1) * highPercentile)]
        return TextContrastReading(time: time, text: line.text,
                                   ratio: Self.ratio(lighter: light, darker: dark),
                                   lighterLuminance: light, darkerLuminance: dark)
    }
}

/// Text a viewer cannot read is decoration. Warns rather than blocks: the measurement is an
/// approximation of a standard written for web pages, and blocking a delivery on it would be
/// asserting more confidence than the method carries.
public struct TextHasEnoughContrast: Assertion {
    public let readings: [TextContrastReading]
    /// WCAG 2.1 AA for large text. Burned-in captions are large text.
    public let minimumRatio: Double

    public init(readings: [TextContrastReading], minimumRatio: Double = 3.0) {
        self.readings = readings; self.minimumRatio = minimumRatio
    }

    public let name = "on-screen text has enough contrast to read"
    public let category = AssertionCategory.legibility
    public let mode = AssertionMode.warn

    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        var reported = Set<String>()
        var out: [AssertionFailure] = []
        for reading in readings where reading.ratio < minimumRatio {
            guard !reported.contains(reading.text) else { continue }
            reported.insert(reading.text)
            out.append(AssertionFailure(
                assertion: name, category: category, mode: mode,
                detail: String(format: "\"%@\" measures %.1f:1 against its background (WCAG AA large text wants %.1f:1)",
                               reading.text, reading.ratio, minimumRatio),
                at: reading.time))
        }
        return out
    }
}
