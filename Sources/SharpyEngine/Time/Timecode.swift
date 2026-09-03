// SMPTE timecode. Non-drop: HH:MM:SS:FF. Drop-frame (29.97 / 59.94): HH:MM:SS;FF, where
// frame numbers 0 and 1 (0–3 at 59.94) are skipped at the start of every minute that is not
// a multiple of ten, so that the displayed clock tracks wall-clock time.
//
// Reference invariants (SMPTE ST 12-1): at 29.97 DF, frame 1800 → 00:01:00;02,
// frame 17982 → 00:10:00;00, frame 107892 → 01:00:00;00.

public struct Timecode: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let rate: FrameRate

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: FrameRate) {
        self.hours = hours; self.minutes = minutes; self.seconds = seconds; self.frames = frames; self.rate = rate
    }

    /// Timecode for a zero-based frame index.
    public init(frameIndex: Int64, rate: FrameRate) {
        let nominal = rate.nominalTimecodeRate
        var f = frameIndex
        if rate.dropFrame {
            // SMPTE drop-frame: add back the dropped frame numbers.
            let dropPerMinute: Int64 = nominal == 60 ? 4 : 2
            let framesPer10Min = nominal * 60 * 10 - dropPerMinute * 9   // 17982 at 29.97
            let framesPerMinute = nominal * 60 - dropPerMinute            // 1798 at 29.97
            let d = f / framesPer10Min
            let m = f % framesPer10Min
            if m > dropPerMinute - 1 {
                f += dropPerMinute * 9 * d + dropPerMinute * ((m - dropPerMinute) / framesPerMinute)
            } else {
                f += dropPerMinute * 9 * d
            }
        }
        let fr = Int(f % nominal)
        let totalSeconds = f / nominal
        self.init(hours: Int(totalSeconds / 3600), minutes: Int((totalSeconds / 60) % 60),
                  seconds: Int(totalSeconds % 60), frames: fr, rate: rate)
    }

    /// Zero-based frame index for this timecode.
    public var frameIndex: Int64 {
        let nominal = rate.nominalTimecodeRate
        let totalMinutes = Int64(hours * 60 + minutes)
        var f = ((Int64(hours) * 3600 + Int64(minutes) * 60 + Int64(seconds)) * nominal) + Int64(frames)
        if rate.dropFrame {
            let dropPerMinute: Int64 = nominal == 60 ? 4 : 2
            f -= dropPerMinute * (totalMinutes - totalMinutes / 10)
        }
        return f
    }

    /// Exact time of the first sample of this frame.
    public var time: TimeValue { TimeValue(frames: frameIndex, at: rate) }

    public var description: String {
        let sep = rate.dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// Parse "HH:MM:SS:FF" or "HH:MM:SS;FF". The separator before FF decides drop-frame only
    /// if the rate permits it; the rate argument is authoritative.
    public init?(string: String, rate: FrameRate) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" }).map { Int($0) }
        guard parts.count == 4, let h = parts[0], let m = parts[1], let s = parts[2], let f = parts[3] else { return nil }
        let nominal = Int(rate.nominalTimecodeRate)
        guard (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s), (0..<nominal).contains(f) else { return nil }
        if rate.dropFrame {
            let drop = nominal == 60 ? 4 : 2
            if s == 0 && m % 10 != 0 && f < drop { return nil }   // a dropped frame number is not a valid timecode
        }
        self.init(hours: h, minutes: m, seconds: s, frames: f, rate: rate)
    }
}
