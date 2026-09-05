// Drawing words onto the picture.
//
// The thing that was entirely missing. Sharpy could READ on-screen text well — it measured all 116
// caption lines in the user's reference and found none below WCAG AA — and could not produce a
// single one. For short-form video that is not a gap in a feature list, it is most of what is on
// screen: the reference has text in 100% of its frames, and the labels and badges carry the whole
// structure of the edit.
//
// Rendered with CoreText into a premultiplied BGRA buffer, composited as an ordinary layer. Two
// things this does that a naive text draw does not:
//
//   IT MEASURES FIRST and sizes the buffer to the text, so a caption is a tight layer placed where
//   it belongs rather than a full-frame image that happens to have words in it. Full-frame overlays
//   cost a 4K texture per caption.
//
//   IT CARRIES ITS OWN CONTRAST. A pill or a stroke behind the words is not decoration — white text
//   over a bright wall is exactly the failure the contrast measurement already flags, and text this
//   system draws should never be text this system would then complain about.

import Foundation
import CoreText
import CoreGraphics
import CoreVideo
import SharpyEngine

public struct TextStyle: Sendable {
    public enum Backing: Sendable {
        /// Nothing behind the words.
        case none
        /// A filled rounded rectangle — the caption pill.
        case pill(red: Double, green: Double, blue: Double, alpha: Double, cornerRadius: Double)
        /// An outline around the glyphs, which survives any background without a block of colour.
        case stroke(red: Double, green: Double, blue: Double, width: Double)
    }

    public var fontName: String
    public var pointSize: Double
    public var red: Double, green: Double, blue: Double, alpha: Double
    public var backing: Backing
    /// Space between the words and the edge of the pill.
    public var padding: Double
    /// Extra space between lines, as a multiple of the point size.
    public var lineSpacing: Double
    public var uppercase: Bool
    /// Widest the text may run before wrapping, in pixels. Nil is one line however long.
    public var maximumWidth: Double?

    public init(fontName: String = "HelveticaNeue-Bold", pointSize: Double = 64,
                red: Double = 1, green: Double = 1, blue: Double = 1, alpha: Double = 1,
                backing: Backing = .none, padding: Double = 24, lineSpacing: Double = 0.15,
                uppercase: Bool = false, maximumWidth: Double? = nil) {
        self.fontName = fontName; self.pointSize = pointSize
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        self.backing = backing; self.padding = padding; self.lineSpacing = lineSpacing
        self.uppercase = uppercase; self.maximumWidth = maximumWidth
    }

    /// A burned-in caption: heavy, upper case, on a dark pill so it reads over anything.
    public static func caption(pointSize: Double, maximumWidth: Double? = nil) -> TextStyle {
        TextStyle(pointSize: pointSize,
                  backing: .pill(red: 0, green: 0, blue: 0, alpha: 0.72, cornerRadius: pointSize * 0.28),
                  padding: pointSize * 0.34, uppercase: false, maximumWidth: maximumWidth)
    }

    /// A section label — the "TOP" / "MIDDLE" / "BOTTOM" furniture.
    public static func label(pointSize: Double) -> TextStyle {
        TextStyle(pointSize: pointSize,
                  backing: .stroke(red: 0, green: 0, blue: 0, width: pointSize * 0.09),
                  padding: pointSize * 0.2, uppercase: true)
    }
}

public struct RenderedText: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int
}

public enum TextRenderError: Error, CustomStringConvertible {
    case emptyText
    case couldNotAllocate(Int, Int)
    public var description: String {
        switch self {
        case .emptyText: return "no text to draw"
        case .couldNotAllocate(let w, let h): return "could not allocate a \(w)×\(h) text layer"
        }
    }
}

public enum TextRenderer {

    static func attributed(_ text: String, style: TextStyle) -> CFAttributedString {
        let shown = style.uppercase ? text.uppercased() : text
        let font = CTFontCreateWithName(style.fontName as CFString, style.pointSize, nil)
        let colour = CGColor(red: style.red, green: style.green, blue: style.blue, alpha: style.alpha)
        var settings = [CTParagraphStyleSetting]()
        var spacing = CGFloat(style.pointSize * style.lineSpacing)
        withUnsafeBytes(of: &spacing) { _ in }
        let paragraph = withUnsafePointer(to: &spacing) { pointer -> CTParagraphStyle in
            settings.append(CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                                    valueSize: MemoryLayout<CGFloat>.size,
                                                    value: pointer))
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): colour,
            .init(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        return CFAttributedStringCreate(nil, shown as CFString, attributes as CFDictionary)
    }

    /// Draw `text` into a buffer sized to fit it.
    public static func render(_ text: String, style: TextStyle) throws -> RenderedText {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextRenderError.emptyText
        }
        let attributed = TextRenderer.attributed(text, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: style.maximumWidth ?? .greatestFiniteMagnitude,
                                height: .greatestFiniteMagnitude)
        var fitRange = CFRange()
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, &fitRange)

        // Room for the pill, and for a stroke which spills OUTSIDE the glyphs — forgetting that
        // clips the outline on the outermost letters, which looks like a rendering fault.
        var extra = style.padding * 2
        if case .stroke(_, _, _, let width) = style.backing { extra += width * 2 }
        let w = Int((measured.width + extra).rounded(.up))
        let h = Int((measured.height + extra).rounded(.up))
        guard w > 0, h > 0, w < 16384, h < 16384 else { throw TextRenderError.couldNotAllocate(w, h) }

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:],
                             kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        guard let pixels = buffer else { throw TextRenderError.couldNotAllocate(w, h) }

        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels),
              let context = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw TextRenderError.couldNotAllocate(w, h)
        }
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))

        if case .pill(let r, let g, let b, let a, let radius) = style.backing {
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
            let rect = CGRect(x: 0, y: 0, width: Double(w), height: Double(h))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                                   transform: nil))
            context.fillPath()
        }

        let inset = style.padding + { if case .stroke(_, _, _, let width) = style.backing { return width } else { return 0 } }()
        let textRect = CGRect(x: inset, y: inset,
                              width: Double(w) - inset * 2, height: Double(h) - inset * 2)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        if case .stroke(let r, let g, let b, let width) = style.backing {
            // Stroke first, then fill over it, so the outline sits BEHIND the letterform rather
            // than eating into it — the difference between an outlined glyph and a thinner one.
            context.setTextDrawingMode(.stroke)
            context.setLineWidth(width)
            context.setStrokeColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.setLineJoin(.round)
            CTFrameDraw(frame, context)
            context.setTextDrawingMode(.fill)
        }
        CTFrameDraw(frame, context)

        return RenderedText(pixelBuffer: pixels, width: w, height: h)
    }

    /// Placement for a rendered text layer, positioned by fractions of the output.
    ///
    /// - Parameter anchor: 0…1 in each axis, where 0.5,0.5 is the middle of the output and the
    ///   text is centred on that point.
    public static func placement(for rendered: RenderedText, in outputWidth: Int, outputHeight: Int,
                                 anchor: (x: Double, y: Double),
                                 scale: Double = 1, opacity: Double = 1) -> LayerPlacement {
        let w = Float(rendered.width) * Float(scale)
        let h = Float(rendered.height) * Float(scale)
        let cx = Float(anchor.x) * Float(outputWidth)
        let cy = Float(anchor.y) * Float(outputHeight)
        return LayerPlacement(offset: SIMD2(cx - w / 2, cy - h / 2),
                              scale: Float(scale), opacity: Float(opacity), usesAlpha: true)
    }
}
