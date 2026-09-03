// Frame rates as exact rationals, with drop-frame timecode where the industry uses it.
// 29.97 is 30000/1001 — never 29.97, never 30/1.001 in floating point.

public struct FrameRate: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Frames per second, exact.
    public let fps: Rational
    /// SMPTE drop-frame timecode counting. Only meaningful for 30000/1001 and 60000/1001.
    public let dropFrame: Bool

    public init(fps: Rational, dropFrame: Bool = false) {
        if dropFrame {
            precondition(fps == FrameRate.ntsc30.fps || fps == FrameRate.ntsc60.fps,
                         "drop-frame only defined for 29.97 and 59.94")
        }
        self.fps = fps
        self.dropFrame = dropFrame
    }

    public static let film24 = FrameRate(fps: Rational(24))
    public static let ntsc24 = FrameRate(fps: Rational(24000, 1001))          // 23.976
    public static let pal25 = FrameRate(fps: Rational(25))
    public static let ntsc30 = FrameRate(fps: Rational(30000, 1001))          // 29.97 NDF
    public static let ntsc30DF = FrameRate(fps: Rational(30000, 1001), dropFrame: true)
    public static let r30 = FrameRate(fps: Rational(30))
    public static let pal50 = FrameRate(fps: Rational(50))
    public static let ntsc60 = FrameRate(fps: Rational(60000, 1001))
    public static let ntsc60DF = FrameRate(fps: Rational(60000, 1001), dropFrame: true)
    public static let r60 = FrameRate(fps: Rational(60))

    /// Duration of one frame in seconds, exact.
    public var frameDuration: Rational { Rational(fps.den, fps.num) }

    /// Nominal integer rate used by timecode (30 for 29.97, 60 for 59.94, 24 for 23.976).
    public var nominalTimecodeRate: Int64 { fps.doubleValue.rounded().toInt64 }

    public var description: String {
        let s: String
        switch fps {
        case FrameRate.ntsc24.fps: s = "23.976"
        case FrameRate.ntsc30.fps: s = "29.97"
        case FrameRate.ntsc60.fps: s = "59.94"
        default: s = fps.den == 1 ? "\(fps.num)" : String(format: "%.3f", fps.doubleValue)
        }
        return dropFrame ? s + " DF" : s
    }
}

extension Double {
    var toInt64: Int64 { Int64(self) }
}

/// A moment on a timeline, in exact seconds. Compare, add and subtract freely.
public struct TimeValue: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let seconds: Rational

    public init(seconds: Rational) { self.seconds = seconds }
    public init(frames: Int64, at rate: FrameRate) { self.seconds = Rational(frames) * rate.frameDuration }

    public static let zero = TimeValue(seconds: .zero)

    /// Frame index at a given rate, floored — the frame that contains this instant.
    public func frame(at rate: FrameRate) -> Int64 { (seconds * rate.fps).floor }

    /// Nearest frame at a given rate.
    public func nearestFrame(at rate: FrameRate) -> Int64 { (seconds * rate.fps).rounded }

    /// True when this instant lies exactly on a frame boundary at the rate.
    public func isFrameAligned(at rate: FrameRate) -> Bool { (seconds * rate.fps).den == 1 }

    public static func + (a: TimeValue, b: TimeValue) -> TimeValue { TimeValue(seconds: a.seconds + b.seconds) }
    public static func - (a: TimeValue, b: TimeValue) -> TimeValue { TimeValue(seconds: a.seconds - b.seconds) }
    public static func < (a: TimeValue, b: TimeValue) -> Bool { a.seconds < b.seconds }

    public var description: String { "\(seconds)s" }
}

/// Half-open range [start, end) on a timeline.
public struct TimeRange: Hashable, Sendable, Codable, CustomStringConvertible {
    public let start: TimeValue
    public let end: TimeValue

    public init(start: TimeValue, end: TimeValue) {
        precondition(!(end < start), "TimeRange end before start")
        self.start = start
        self.end = end
    }

    public init(start: TimeValue, duration: TimeValue) { self.init(start: start, end: start + duration) }

    public var duration: TimeValue { end - start }
    public var isEmpty: Bool { start == end }

    public func contains(_ t: TimeValue) -> Bool { !(t < start) && t < end }
    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = max(start, other.start), e = min(end, other.end)
        return s < e ? TimeRange(start: s, end: e) : nil
    }

    public var description: String { "[\(start), \(end))" }
}
