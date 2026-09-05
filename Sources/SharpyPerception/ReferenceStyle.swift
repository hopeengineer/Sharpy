// How the reference dresses its panels — measured, so the copy can be held to it.
//
// The first three-panel render had no labels, no captions and a loose crop, and every check passed,
// because every check compared the output with the SOURCE. Nothing compared it with the thing it
// was supposed to look like. These are the properties of the reference that a copy must match, read
// off the reference itself: how big the face is in each band, what text sits on every frame at a
// fixed place (the labels), and what text comes and goes with the speech (the captions).
//
// Labels and captions are told apart by PERSISTENCE, not by what they say. A label is on screen
// for most of the piece at the same spot; a caption is there for a moment. Reading the words would
// mean guessing which words are furniture, and the reference's furniture happens to say TOP and
// MIDDLE — a different reference would say something else.

import Foundation
import SharpyEngine

public struct ReferenceStyle: Sendable {
    public struct Face: Sendable {
        /// Face height as a fraction of the BAND height. This is what "tight" means, in a number.
        public let heightInBand: Double
        /// Face centre, as fractions of the band's width and height.
        public let centreX: Double
        public let centreY: Double
    }
    public struct PersistentText: Sendable {
        public let text: String
        public let panel: Int
        /// Box in fractions of the band: x, y from the band's top-left; height of the band.
        public let x: Double, y: Double, height: Double
        /// Fraction of sampled frames it appears in.
        public let persistence: Double
    }
    public struct Captions: Sendable {
        /// Fraction of sampled frames with a transient caption somewhere.
        public let coverage: Double
        /// Where they sit within the band they are in, as fractions.
        public let centreX: Double
        public let centreY: Double
        public let heightInBand: Double
        public let medianWords: Int
    }

    public let panels: Int
    public let width: Int, height: Int
    public let faces: [Int: Face]
    /// Longest stretch, in seconds, with no face in the band. A speaker's panel never loses the
    /// speaker; a held frame of a hand over the lens does, for as long as it is held.
    public let longestFacelessRun: [Int: Double]
    public let labels: [PersistentText]
    public let captions: Captions?

    public var summary: String {
        var lines = ["style: \(panels) band(s) in \(width)x\(height)"]
        for panel in 0..<panels {
            if let f = faces[panel] {
                lines.append(String(format: "  band %d: face is %.0f%% of the band height, centred at %.0f%% across, %.0f%% down; longest faceless stretch %.1f s",
                                    panel + 1, f.heightInBand * 100, f.centreX * 100, f.centreY * 100, longestFacelessRun[panel] ?? 0))
            } else {
                lines.append("  band \(panel + 1): no face measured")
            }
        }
        if labels.isEmpty {
            lines.append("  no persistent text — the reference has no labels")
        } else {
            for l in labels {
                lines.append(String(format: "  label \"%@\" on band %d at %.0f%%,%.0f%% of the band, %.0f%% tall, on %.0f%% of frames",
                                    l.text as CVarArg, l.panel + 1, l.x * 100, l.y * 100, l.height * 100, l.persistence * 100))
            }
        }
        if let c = captions {
            lines.append(String(format: "  captions on %.0f%% of frames: ~%d words, %.0f%% of band height, centred %.0f%% across, %.0f%% down the band",
                                c.coverage * 100, c.medianWords, c.heightInBand * 100, c.centreX * 100, c.centreY * 100))
        } else {
            lines.append("  no transient text — the reference has no captions")
        }
        return lines.joined(separator: "\n")
    }

    public static func measure(url: URL, panels: Int, samplesPerSecond: Double = 2) throws -> ReferenceStyle {
        let options = VisionIndexOptions(samplesPerSecond: samplesPerSecond, detectFaces: true,
                                          detectText: true, detectHands: false, accurateText: true)
        let index = try VisionIndexer(options: options).index(url: url, asset: NodeID(contentOf: url.path))
        let band = Double(index.height) / Double(max(panels, 1))
        let w = Double(index.width)
        func panel(ofY y: Double) -> Int { min(max(Int(y / band), 0), panels - 1) }
        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
        }

        // Faces, per band. The largest face in a band is the speaker.
        var perBand: [Int: [(Double, Double, Double)]] = [:]
        for frame in index.frames {
            var best: [Int: DetectedBox] = [:]
            for face in frame.faces {
                let p = panel(ofY: face.y + face.height / 2)
                if face.area > (best[p]?.area ?? 0) { best[p] = face }
            }
            for (p, face) in best {
                perBand[p, default: []].append((face.height / band,
                                                (face.x + face.width / 2) / w,
                                                (face.y + face.height / 2 - Double(p) * band) / band))
            }
        }
        var longestFacelessRun: [Int: Double] = [:]
        for p in 0..<panels {
            var longest = 0.0, runStart: Double?
            for frame in index.frames {
                let has = frame.faces.contains { panel(ofY: $0.y + $0.height / 2) == p }
                let t = frame.time.seconds.doubleValue
                if has { if let s = runStart { longest = max(longest, t - s) }; runStart = nil }
                else if runStart == nil { runStart = t }
            }
            if let s = runStart, let last = index.frames.last { longest = max(longest, last.time.seconds.doubleValue - s + 1 / samplesPerSecond) }
            longestFacelessRun[p] = longest
        }
        var faces: [Int: Face] = [:]
        for (p, list) in perBand where list.count >= 3 {
            faces[p] = Face(heightInBand: median(list.map(\.0)), centreX: median(list.map(\.1)),
                            centreY: median(list.map(\.2)))
        }

        // Text, grouped by where it sits and what it says.
        struct Key: Hashable { let text: String; let panel: Int; let cellX: Int; let cellY: Int }
        var seen: [Key: [TextLine]] = [:]
        var framesWithTransient = 0
        var transient: [(Double, Double, Double, Int)] = []
        let total = max(index.frames.count, 1)
        for frame in index.frames {
            for line in frame.text {
                let p = panel(ofY: line.box.y + line.box.height / 2)
                let key = Key(text: line.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                              panel: p, cellX: Int(line.box.x / w * 10), cellY: Int((line.box.y - Double(p) * band) / band * 10))
                seen[key, default: []].append(line)
            }
        }
        var labels: [PersistentText] = []
        var persistentKeys = Set<Key>()
        for (key, lines) in seen {
            let persistence = Double(lines.count) / Double(total)
            // Numbers under a label (view counts) persist too; they are furniture as much as the
            // word above them and are kept as labels in their own right.
            guard persistence >= 0.6, !key.text.isEmpty else { continue }
            persistentKeys.insert(key)
            labels.append(PersistentText(
                text: lines[0].text, panel: key.panel,
                x: median(lines.map { $0.box.x / w }),
                y: median(lines.map { ($0.box.y - Double(key.panel) * band) / band }),
                height: median(lines.map { $0.box.height / band }),
                persistence: persistence))
        }
        labels.sort { ($0.panel, $0.y) < ($1.panel, $1.y) }

        for frame in index.frames {
            var any = false
            for line in frame.text {
                let p = panel(ofY: line.box.y + line.box.height / 2)
                let key = Key(text: line.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                              panel: p, cellX: Int(line.box.x / w * 10), cellY: Int((line.box.y - Double(p) * band) / band * 10))
                guard !persistentKeys.contains(key) else { continue }
                // Persistent text drifting a cell is still furniture: same words, same band.
                if persistentKeys.contains(where: { $0.text == key.text && $0.panel == key.panel }) { continue }
                any = true
                transient.append(((line.box.x + line.box.width / 2) / w,
                                  (line.box.y + line.box.height / 2 - Double(p) * band) / band,
                                  line.box.height / band,
                                  line.text.split(separator: " ").count))
            }
            if any { framesWithTransient += 1 }
        }
        let captions: Captions? = transient.count >= 3 ? Captions(
            coverage: Double(framesWithTransient) / Double(total),
            centreX: median(transient.map(\.0)), centreY: median(transient.map(\.1)),
            heightInBand: median(transient.map(\.2)),
            medianWords: Int(median(transient.map { Double($0.3) }))) : nil

        return ReferenceStyle(panels: panels, width: index.width, height: index.height,
                              faces: faces, longestFacelessRun: longestFacelessRun, labels: labels, captions: captions)
    }
}
