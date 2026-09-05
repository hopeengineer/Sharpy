// A default render must show exactly what was recorded — no crop, no zoom, no reframe.
//
// Cropping without being asked is the most dishonest thing an editor can do, because the person
// cannot tell it happened: the picture still looks like a picture. The user watched a cut, said it
// looked zoomed, and was right — a rotation bug was drawing landscape pixels into a portrait
// canvas. This is the guard that would have caught it without them having to look.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyPerception
@testable import SharpyRender

final class NoDefaultCropTests: XCTestCase {

    /// The shape of the output must match the shape the source asks to be shown at.
    func testADefaultRenderKeepsTheSourceShape() throws {
        let source = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/20260904_014657.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("no 4K asset") }
        let frames = try SequentialFrameSource(url: source)

        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: frames.nominalFrameRate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: source.path,
                                          duration: frames.duration, frameRate: frames.nominalFrameRate,
                                          hasVideo: true, hasAudio: true)))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        let end = TimeValue(frames: 6, at: frames.nominalFrameRate)
        try log.append(.placeClip(track: 0,
            clip: Clip(asset: id, source: TimeRange(start: .zero, end: end), start: .zero),
            decision: Decision(kind: .cut, at: .zero,
                               basis: .clientRule(rule: "render as recorded"))))

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-nocrop-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let session = try RenderSession(document: log.head,
                                        options: RenderOptions(width: frames.width, height: frames.height,
                                                               codec: .h264(bitrate: 20_000_000),
                                                               sampleRate: 48_000))
        _ = try session.render(to: out)

        // Same shape as the source presents itself.
        let rendered = try SequentialFrameSource(url: out)
        XCTAssertEqual(Double(rendered.width) / Double(rendered.height),
                       Double(frames.width) / Double(frames.height), accuracy: 0.01,
                       "a default render must not change the shape of the frame")

        // And the same FIELD OF VIEW: the subject must occupy the same fraction of the frame. A
        // zoom keeps the aspect ratio and still throws away the edges, so shape alone is not enough.
        let options = VisionIndexOptions(samplesPerSecond: 4, detectFaces: true,
                                          detectText: false, detectHands: false, accurateText: false)
        let indexer = VisionIndexer(options: options)
        let sourceVision = try indexer.index(url: source, asset: NodeID(contentOf: "s"), maximumFrames: 3)
        let outputVision = try indexer.index(url: out, asset: NodeID(contentOf: "o"), maximumFrames: 3)

        func faceFraction(_ v: VisionIndex) -> Double? {
            guard let face = v.frames.compactMap({ $0.faces.first }).first else { return nil }
            return (face.width * face.height) / Double(v.width * v.height)
        }
        guard let sourceFace = faceFraction(sourceVision), let outputFace = faceFraction(outputVision) else {
            throw XCTSkip("no face found to compare field of view against")
        }
        XCTAssertEqual(outputFace, sourceFace, accuracy: sourceFace * 0.25,
                       "the subject fills \(outputFace) of the output against \(sourceFace) of the source — the render is zoomed")
    }

    /// Reframing is opt-in. Nothing may crop unless it was asked for.
    func testReframingOnlyHappensWhenRequested() {
        let untouched = Reframer.plan(sourceWidth: 2160, sourceHeight: 3840,
                                      targetAspect: 2160.0 / 3840.0, subject: (x: 0.3, y: 0.2))
        XCTAssertEqual(untouched.cropLeft + untouched.cropRight
                       + untouched.cropTop + untouched.cropBottom, 0, accuracy: 0.0001,
                       "asking for the shape it already is must crop nothing, wherever the subject sits")
        XCTAssertNil(Reframer.parse("original"), "'original' means leave it alone")
    }
}
