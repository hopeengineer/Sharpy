// The third tier: what the plan predicted against what the file actually contains.
//
// Tiers one and two each have a blind spot. The ID pass proves what the compositor did but not
// what the encoder wrote. Signal QC measures the written file but has no idea what was intended —
// a deliverable that is 6 LU quiet is perfectly legal and completely wrong.
//
// This tier closes that by asserting the DELTA. It is the one that catches a wrong colour
// transform, a dropped frame, and an encoder that quietly missed the loudness target: all faults
// where the output is individually plausible and simply is not what was asked for.

import Foundation
import SharpyEngine

/// What the render undertook to produce.
public struct RenderPrediction: Sendable {
    public let frames: Int
    public let duration: TimeValue
    /// Integrated loudness the render aimed at, when a target was set.
    public let loudnessTarget: Double?
    /// Set when the render already knew it could not reach the target because the true-peak
    /// ceiling bound the gain. A deliverable that is quiet ON PURPOSE must not be reported as a
    /// missed target — that is a false alarm, and false alarms are how a gate gets switched off.
    public let loudnessKnownShortfall: Double?
    /// Whether consecutive frames were supposed to differ.
    ///
    /// Only the caller knows. A talking-head cut from live footage should never repeat a frame;
    /// a timeline holding on a static graphic card repeats every frame of it by design, and the
    /// user's own reel contains 416 such frames, all correct. Defaulting this to true would flag
    /// a legitimate edit, and a gate that cries wolf gets switched off.
    public let expectsDistinctFrames: Bool

    public init(frames: Int, duration: TimeValue, loudnessTarget: Double? = nil,
                loudnessKnownShortfall: Double? = nil, expectsDistinctFrames: Bool = false) {
        self.frames = frames; self.duration = duration
        self.loudnessTarget = loudnessTarget
        self.loudnessKnownShortfall = loudnessKnownShortfall
        self.expectsDistinctFrames = expectsDistinctFrames
    }

    public init(report: RenderReport, target: LoudnessTarget?) {
        self.init(frames: report.framesRendered, duration: report.duration,
                  loudnessTarget: target?.integrated,
                  loudnessKnownShortfall: report.loudnessTargetMissedBy)
    }
}

public struct DeliveryFinding: Sendable, Equatable, CustomStringConvertible {
    public let check: String
    public let detail: String
    public var description: String { "\(check): \(detail)" }
}

public struct DeliveryComparison: Sendable {
    public let findings: [DeliveryFinding]
    public var isClean: Bool { findings.isEmpty }
    public var summary: String {
        isClean ? "delivery: matches prediction"
                : "delivery: \(findings.count) mismatch(es) between predicted and achieved"
    }
}

public enum PredictedVsAchieved {
    /// Loudness tolerance, LU. EBU R128 delivery specs commonly allow ±0.5 LU, and this meter
    /// agrees with ffmpeg's `ebur128` to within 0.06 LU (bench/results/ffmpeg.txt), so 0.5 is the
    /// spec's tolerance rather than an allowance for the measurement.
    public static let loudnessToleranceLU = 0.5

    public static func compare(predicted: RenderPrediction, achieved: OutputQCReport) -> DeliveryComparison {
        var findings: [DeliveryFinding] = []

        // A check that could not run is a failure, not a pass.
        for reason in achieved.couldNotRun {
            findings.append(DeliveryFinding(check: "incomplete", detail: reason))
        }

        if achieved.framesMeasured != predicted.frames {
            findings.append(DeliveryFinding(
                check: "frame count",
                detail: "predicted \(predicted.frames), file contains \(achieved.framesMeasured)"))
        }

        if predicted.expectsDistinctFrames, !achieved.repeatedFrames.isEmpty {
            // A repeat in a rendered deliverable is not a stylistic choice; the timeline asked for
            // a distinct frame and the file has the previous one again.
            let sample = achieved.repeatedFrames.prefix(5).map(String.init).joined(separator: ", ")
            findings.append(DeliveryFinding(
                check: "repeated frames",
                detail: "\(achieved.repeatedFrames.count) frame(s) identical to their predecessor (\(sample)\(achieved.repeatedFrames.count > 5 ? ", …" : ""))"))
        }

        if !achieved.illegalLevelFrames.isEmpty {
            let sample = achieved.illegalLevelFrames.prefix(5).map(String.init).joined(separator: ", ")
            findings.append(DeliveryFinding(
                check: "levels",
                detail: "\(achieved.illegalLevelFrames.count) frame(s) outside the EBU R103 tolerance (\(sample)\(achieved.illegalLevelFrames.count > 5 ? ", …" : "")) — usually a missing or doubled range conversion"))
        }

        if !achieved.blackFrames.isEmpty {
            let sample = achieved.blackFrames.prefix(5).map(String.init).joined(separator: ", ")
            findings.append(DeliveryFinding(
                check: "black frames",
                detail: "\(achieved.blackFrames.count) frame(s) effectively black (\(sample)\(achieved.blackFrames.count > 5 ? ", …" : ""))"))
        }

        if let target = predicted.loudnessTarget {
            guard let measured = achieved.loudness?.integrated else {
                findings.append(DeliveryFinding(
                    check: "loudness",
                    detail: "a target of \(String(format: "%.1f", target)) LUFS was set but the output measures silent"))
                return DeliveryComparison(findings: findings)
            }
            let delta = measured - target
            // Subtract what the render already declared it could not deliver, so the only thing
            // asserted here is the part nobody accounted for.
            let expected = -(predicted.loudnessKnownShortfall ?? 0)
            let unexplained = abs(delta - expected)
            if unexplained > loudnessToleranceLU {
                findings.append(DeliveryFinding(
                    check: "loudness",
                    detail: String(format: "predicted %.1f LUFS, achieved %.2f — %.2f LU unexplained (tolerance %.1f)",
                                   target, measured, unexplained, loudnessToleranceLU)))
            }
        }

        return DeliveryComparison(findings: findings)
    }
}
