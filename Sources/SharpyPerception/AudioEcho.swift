// The echo, measured in the sound.
//
// The opening of a stacked reel plays the same line in every panel a beat apart. Two attempts to
// see that in the picture failed for reasons worth keeping: correlating panel MOTION asked a
// shifted copy of one panel's movement to beat "no shift" by a fifth, which nothing can do when the
// panels are already 94% alike; correlating the panel PICTURES then found no minimum either, which
// says the panels are probably three separate takes rather than one take delayed.
//
// The sound has no such problem. One phrase arriving three times over is periodic, and the period
// is the echo — the thing to reproduce. It is measured off the loudness envelope rather than the
// waveform, because two utterances of the same words never line up sample for sample but their
// shapes do.

import Foundation
import SharpyEngine
import SharpyRender

public enum AudioEcho {

    /// Shortest and longest echo worth believing. Below 60 ms it is a room reflection, not an edit;
    /// above a second the panels are taking turns rather than overlapping.
    /// 15 ms is the shortest the ear separates into two arrivals; under that a copy thickens the
    /// voice rather than repeating it. Set at 60 ms first, and the reference's peak sat exactly on
    /// that floor — a boundary, not a measurement — so the floor moved to where hearing puts it.
    public static let shortest = 0.015
    public static let longest = 1.0

    public struct Measurement: Sendable {
        public let seconds: Double
        /// How much better the peak is than the flat average: 1 means no periodicity at all.
        public let strength: Double
        public var description: String {
            String(format: "echo of %.3f s in the opening (%.2f× the surrounding correlation)", seconds, strength)
        }
    }

    /// - Parameter within: the opening, where the panels overlap. Outside it they take turns and
    ///   there is nothing periodic to find.
    public static func measure(url: URL, within: ClosedRange<Double>,
                               sampleRate: Int = 48_000) throws -> Measurement? {
        guard within.upperBound > within.lowerBound + 2 * shortest else { return nil }
        let source = try AudioSource(url: url, sampleRate: sampleRate, channels: 1)
        func time(_ seconds: Double) -> TimeValue {
            TimeValue(seconds: Rational(Int64((seconds * 1000).rounded()), 1000))
        }
        let samples = try source.read(TimeRange(start: time(within.lowerBound), end: time(within.upperBound)))
        guard samples.count > sampleRate / 4 else { return nil }

        // Loudness envelope at 200 Hz — fine enough to place a 60 ms echo, coarse enough that the
        // carrier itself does not show up as the period.
        let hop = max(sampleRate / 200, 1)
        var envelope: [Double] = []
        envelope.reserveCapacity(samples.count / hop)
        var index = 0
        while index + hop <= samples.count {
            var sum = 0.0
            for i in index..<(index + hop) { sum += Double(samples[i]) * Double(samples[i]) }
            envelope.append((sum / Double(hop)).squareRoot())
            index += hop
        }
        guard envelope.count > 8 else { return nil }
        // Remove the mean, or every lag correlates strongly with every other and the peak is the
        // signal's loudness rather than its rhythm.
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        let centred = envelope.map { $0 - mean }
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }

        let perSecond = Double(sampleRate) / Double(hop)
        let low = max(Int(shortest * perSecond), 1)
        let high = min(Int(longest * perSecond), centred.count / 2)
        guard high > low else { return nil }

        var correlations: [Double] = []
        for lag in low...high {
            var sum = 0.0
            for i in 0..<(centred.count - lag) { sum += centred[i] * centred[i + lag] }
            correlations.append(sum / energy)
        }
        guard let peak = correlations.enumerated().max(by: { $0.element < $1.element }),
              peak.element > 0 else { return nil }
        let average = correlations.map(abs).reduce(0, +) / Double(correlations.count)
        guard average > 0 else { return nil }
        let strength = peak.element / average
        // A peak has to stand well clear of the rest of the curve. Speech is bumpy, and the highest
        // bump on a flat curve is a bump, not a period.
        guard strength > 1.8 else { return nil }
        // A peak sitting on the edge of the search is not a measurement of the echo, it is a
        // measurement of where I stopped looking. The first run returned exactly 0.06 s — the
        // floor — at 4.35× strength, which reads as a confident answer and is an artefact.
        let atLag = low + peak.offset
        guard atLag > low, atLag < high else { return nil }
        return Measurement(seconds: Double(atLag) / perSecond, strength: strength)
    }
}
