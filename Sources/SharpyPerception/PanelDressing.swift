// What goes on the panels besides the picture, and how tight the picture is — all read off the
// script or the reference, none of it invented.

import Foundation
import SharpyEngine

// MARK: - Framing

public enum PanelFraming {
    public struct FaceBox: Sendable {
        /// Fractions of the source frame.
        public let centreX: Double, centreY: Double, height: Double
    }

    /// The speaker's face in the source, as the median over every sampled frame of the largest face.
    /// Median, not mean: a frame where Vision found a hand instead does not drag the crop.
    public static func face(in vision: VisionIndex) -> FaceBox? {
        let boxes = vision.frames.compactMap { $0.faces.max(by: { $0.area < $1.area }) }
        guard boxes.count >= 3 else { return nil }
        func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
        let w = Double(max(vision.width, 1)), h = Double(max(vision.height, 1))
        return FaceBox(centreX: median(boxes.map { ($0.x + $0.width / 2) / w }),
                       centreY: median(boxes.map { ($0.y + $0.height / 2) / h }),
                       height: median(boxes.map { $0.height / h }))
    }

    /// A band cropped so the face is the size and in the place the reference puts it.
    ///
    /// The first render kept the whole landscape frame in each band, which made the face a fifth
    /// the size of the reference's. "Tight" is not a taste; the reference has a number for it —
    /// 21% of the band height on the one measured — and the crop is solved for that number. When
    /// the source cannot give it (a face too small in a too-wide shot) the crop keeps the whole
    /// height and the face comes out as large as it can, and the shortfall is reported rather than
    /// hidden by stretching.
    public static func placement(panel: Int, of panels: Int,
                                 sourceWidth: Int, sourceHeight: Int,
                                 outputWidth: Int, outputHeight: Int,
                                 face: FaceBox, target: ReferenceStyle.Face) -> (ClipPlacement, achieved: Double, note: String?) {
        let bandAspect = Double(outputWidth) / (Double(outputHeight) / Double(panels))
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        // The band shows keepH of the source height; the face is face.height of the source height;
        // so in the band the face is face.height / keepH. Solve for the reference's figure.
        var keepH = face.height / target.heightInBand
        var note: String?
        if keepH > 1 {
            // The face would need MORE than the whole frame to come out as small as the
            // reference's — the speaker is closer to camera than the reference's speaker. There is
            // no picture past the frame edge, so the whole height is kept and the face comes out
            // larger. Said plainly: the first version printed the target as if it were the result.
            keepH = 1
            note = String(format: "the shot is already tighter than the reference — face %.0f%% of the band against the reference's %.0f%% — so the full height is kept",
                          face.height * 100, target.heightInBand * 100)
        }
        // cropped aspect (keepW*srcW)/(keepH*srcH) must equal the band's.
        var keepW = keepH * bandAspect / sourceAspect
        if keepW > 1 {
            keepW = 1
            keepH = sourceAspect / bandAspect
            note = String(format: "face can only reach %.0f%% of the band height (reference %.0f%%) — the shot is too wide",
                          face.height / keepH * 100, target.heightInBand * 100)
        }
        let achieved = face.height / keepH
        let top = min(max(face.centreY - target.centreY * keepH, 0), 1 - keepH)
        let left = min(max(face.centreX - target.centreX * keepW, 0), 1 - keepW)
        func exact(_ v: Double) -> Rational { Rational(Int64((min(max(v, 0), 1) * 100_000).rounded()), 100_000) }
        let placement = ClipPlacement(x: .zero, y: Rational(Int64(panel), Int64(panels)), width: .one,
                                      cropLeft: exact(left), cropRight: exact(1 - keepW - left),
                                      cropTop: exact(top), cropBottom: exact(1 - keepH - top))
        return (placement, achieved, note)
    }
}

// MARK: - Where to hold

extension PanelFraming {
    /// The latest instant at or before `instant` where the picture still shows a face.
    ///
    /// The last thing on a take is the speaker reaching for the camera. A panel frozen on the
    /// frame its last line ends on was frozen on a hand over the lens, and held there for the rest
    /// of the piece — because the freeze instant was chosen by the sound, and nothing asked what the
    /// picture showed. Steps back through the Vision samples until one has a face, up to `within`
    /// seconds; past that the instant is returned unchanged rather than jumping to some earlier
    /// moment of the take.
    public static func lastFaceInstant(before instant: TimeValue, in vision: VisionIndex,
                                       frameRate: FrameRate, within: Double = 2.5) -> TimeValue {
        let samples = vision.frames.filter { $0.time <= instant }.sorted { $0.time < $1.time }
        guard let nearest = samples.last else { return instant }
        // The sample covering this instant already shows a face: hold where the sound says.
        if !nearest.faces.isEmpty { return instant }
        let floor = instant.seconds.doubleValue - within
        guard let good = samples.last(where: { !$0.faces.isEmpty && $0.time.seconds.doubleValue >= floor })
        else { return instant }
        return TimeValue(frames: good.time.nearestFrame(at: frameRate), at: frameRate)
    }
}

// MARK: - Labels

public enum PanelLabels {
    /// The label for each panel, taken from the first line the script gives that panel.
    ///
    /// The reference labels its bands TOP / MIDDLE / BOTTOM because its intro line is "top of the
    /// funnel, middle of the funnel, bottom of the funnel". The user's intro is "First folders.
    /// Second: instruction files. Third: hooks." — so their labels are FOLDERS, INSTRUCTION FILES,
    /// HOOKS. The ordinal is the list's scaffolding, not the label; it is removed.
    public static func derive(from script: ParsedScript, panels: Int) -> [Int: String] {
        var out: [Int: String] = [:]
        for cut in script.body.sorted(by: { $0.order < $1.order }) {
            guard let row = cut.panel.row(of: panels), out[row] == nil else { continue }
            out[row] = label(from: cut.text)
        }
        return out
    }

    static let ordinals: Set<String> = ["first", "second", "third", "fourth", "fifth",
                                        "1st", "2nd", "3rd", "4th", "5th", "one", "two", "three",
                                        "number", "no"]

    public static func label(from line: String) -> String {
        var words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let first = words.first,
              ordinals.contains(first.lowercased().filter { $0.isLetter || $0.isNumber }) {
            words.removeFirst()
        }
        let joined = words.joined(separator: " ")
        // Up to the first full stop: a label is a noun phrase, not the sentence after it.
        let phrase = joined.split(separator: ".").first.map(String.init) ?? joined
        return phrase.trimmingCharacters(in: CharacterSet(charactersIn: " :,;-—")).uppercased()
    }
}

// MARK: - Captions

public enum CaptionGroups {
    public struct Group: Sendable {
        public let text: String
        /// In SOURCE time.
        public let range: TimeRange
    }

    /// The words of a span, in groups the size the reference uses, each timed to the words in it.
    ///
    /// Groups break at pauses as well as at the count, so a caption never straddles a breath — the
    /// reference's captions follow the phrasing, not a metronome.
    public static func groups(words: [Word], size: Int, breath: Double = 0.35) -> [Group] {
        var out: [Group] = []
        var current: [Word] = []
        func flush() {
            guard let f = current.first, let l = current.last else { return }
            out.append(Group(text: current.map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
                                        .joined(separator: " "),
                             range: TimeRange(start: f.range.start, end: l.range.end)))
            current = []
        }
        for (i, w) in words.enumerated() {
            current.append(w)
            let pauseNext = i + 1 < words.count
                && (words[i + 1].range.start - w.range.end).seconds.doubleValue >= breath
            let endsSentence = w.text.last.map { $0 == "." || $0 == "?" || $0 == "!" } ?? false
            if current.count >= max(size, 1) || pauseNext || endsSentence { flush() }
        }
        flush()
        return out
    }
}
