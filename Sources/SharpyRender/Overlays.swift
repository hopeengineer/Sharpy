// Things drawn over the picture: labels that stay, captions that come and go.

import Foundation
import CoreVideo
import SharpyEngine

public protocol OverlaySource: Sendable {
    /// Layers to composite over the video at this instant, bottom first.
    func layers(at time: TimeValue) -> [CompositeLayer]
}

/// Text overlays with a life span. Each piece of text is rendered once, however many frames it is
/// on — rendering a label 2,655 times for 2,655 frames would be the slow way to draw one word.
public struct TextOverlays: OverlaySource, @unchecked Sendable {
    public struct Item: @unchecked Sendable {
        public let range: TimeRange
        public let layer: CompositeLayer
    }
    private let items: [Item]

    public init(items: [Item]) { self.items = items }

    public func layers(at time: TimeValue) -> [CompositeLayer] {
        items.filter { $0.range.contains(time) }.map(\.layer)
    }

    /// Render `text` once and place it, centred on `anchor` in output fractions, so it appears for
    /// the given span. Text that repeats (the same caption twice, or a label once per render) shares
    /// one buffer through `cache`.
    public static func item(_ text: String, style: TextStyle, anchor: (x: Double, y: Double),
                            outputWidth: Int, outputHeight: Int, during range: TimeRange,
                            cache: inout [String: RenderedText]) throws -> Item {
        let key = text + "|" + style.fontName + "|" + String(style.pointSize) + "|" + String(style.uppercase)
        let rendered: RenderedText
        if let hit = cache[key] { rendered = hit } else {
            rendered = try TextRenderer.render(text, style: style)
            cache[key] = rendered
        }
        let placement = TextRenderer.placement(for: rendered, in: outputWidth, outputHeight: outputHeight,
                                               anchor: anchor)
        return Item(range: range, layer: CompositeLayer(pixelBuffer: rendered.pixelBuffer, placement: placement))
    }

    /// The same, anchored by its TOP-LEFT corner, which is how a label is measured off a reference:
    /// Vision reports where the box begins, and the box's width depends on the word.
    public static func item(_ text: String, style: TextStyle, topLeft: (x: Double, y: Double),
                            outputWidth: Int, outputHeight: Int, during range: TimeRange,
                            cache: inout [String: RenderedText]) throws -> Item {
        let key = text + "|" + style.fontName + "|" + String(style.pointSize) + "|" + String(style.uppercase)
        let rendered: RenderedText
        if let hit = cache[key] { rendered = hit } else {
            rendered = try TextRenderer.render(text, style: style)
            cache[key] = rendered
        }
        let placement = LayerPlacement(offset: SIMD2(Float(topLeft.x * Double(outputWidth)),
                                                     Float(topLeft.y * Double(outputHeight))),
                                       scale: 1, opacity: 1, usesAlpha: true)
        return Item(range: range, layer: CompositeLayer(pixelBuffer: rendered.pixelBuffer, placement: placement))
    }
}
