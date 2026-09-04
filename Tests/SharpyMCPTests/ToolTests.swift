// The agent surface, tested at the tool boundary.
//
// What matters here is not that the happy path works — it is that the *refusals* are usable. An
// agent that gets "error" with no route forward burns a whole turn guessing, so every failure
// these tests exercise is checked for naming the way out.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyMCPCore

final class ToolTests: XCTestCase {
    var storeRoot: URL!
    var session: Session!

    override func setUp() {
        super.setUp()
        storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        session = try! Session(storeRoot: storeRoot)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: storeRoot); super.tearDown() }

    func call(_ name: String, _ args: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let data = try! JSONSerialization.data(withJSONObject: args)
        let value = try! JSONDecoder().decode(JSONValue.self, from: data)
        let result = runTool(name, value, session)
        let content = result["content"] as! [[String: Any]]
        return (content[0]["text"] as! String, (result["isError"] as? Bool) ?? false)
    }

    /// A short silent movie so tools that need real media have some.
    static func makeMovie(seconds: Double = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-media-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let w = 160, h = 120
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let total = Int(seconds * 30)
        let group = DispatchGroup(); group.enter()
        var next = 0
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "mcp.fixture")) {
            while input.isReadyForMoreMediaData {
                guard next < total else { input.markAsFinished(); group.leave(); return }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                let buf = pb!
                CVPixelBufferLockBaseAddress(buf, [])
                let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buf)
                let v = UInt8(40 + (next % 180))
                for y in 0..<h { for x in 0..<w {
                    let p = base + y * stride + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 255 } }
                CVPixelBufferUnlockBaseAddress(buf, [])
                _ = adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: 30))
                next += 1
            }
        }
        group.wait()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        return url
    }

    // MARK: the tool surface itself

    func testEveryToolDeclaresANameDescriptionAndSchema() {
        // Pinned deliberately: the agent surface is the product, and a tool appearing without a
        // decision is how a surface becomes a junk drawer. Bump it when you mean to.
        XCTAssertEqual(tools.count, 19)
        for t in tools {
            let name = t["name"] as? String
            XCTAssertNotNil(name)
            let description = t["description"] as? String ?? ""
            XCTAssertGreaterThan(description.count, 40, "\(name ?? "?") needs a description an agent can act on")
            let schema = t["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(name ?? "?") schema")
            XCTAssertNotNil(schema?["properties"], "\(name ?? "?") must declare properties")
        }
    }

    /// The interface's central promise: no tool asks an agent for a frame number.
    func testNoToolTakesFrameArithmetic() {
        for t in tools {
            let schema = t["inputSchema"] as! [String: Any]
            let properties = schema["properties"] as! [String: Any]
            for key in properties.keys {
                let lower = key.lowercased()
                XCTAssertFalse(lower.contains("frame"), "\(t["name"]!) exposes '\(key)' — the agent must not do frame arithmetic")
                XCTAssertFalse(lower.contains("timecode"), "\(t["name"]!) exposes '\(key)'")
            }
        }
    }

    // MARK: refusals that lead somewhere

    func testToolsBeforeOpenMediaSayWhatToCallFirst() {
        for name in ["get_transcript", "get_timeline", "get_report", "verify", "tighten_pauses"] {
            let r = call(name, name == "tighten_pauses" ? ["maxSeconds": 0.4] : [:])
            XCTAssertTrue(r.isError, "\(name) should refuse with no media open")
            XCTAssertTrue(r.text.contains("open_media"), "\(name) must name the tool to call first, said: \(r.text)")
        }
    }

    func testOpeningAMissingFileNamesThePath() {
        let r = call("open_media", ["path": "/nope/missing.mov"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("/nope/missing.mov"))
    }

    func testOpenMediaWithoutAPathSaysSo() {
        let r = call("open_media", [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("path"))
    }

    func testUnknownToolIsNamed() {
        let r = call("frobnicate", [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("frobnicate"))
    }

    func testUndoWithNothingToUndoRefuses() {
        let r = call("undo")
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.lowercased().contains("nothing to undo"))
    }

    // MARK: with real media

    func testOpenMediaReportsTheContainerFacts() throws {
        let url = try Self.makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = call("open_media", ["path": url.path])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("160×120"))
        XCTAssertTrue(r.text.contains("duration 2.000s"))
        XCTAssertTrue(r.text.contains("audio: none"), "this fixture is silent and the tool should say so")
        XCTAssertNotNil(session.document)
    }

    func testTimelineShowsClipsAndTheDecisionRecord() throws {
        let url = try Self.makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = call("open_media", ["path": url.path])
        let r = call("get_timeline")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("track 0: V1 (video)"))
        XCTAssertTrue(r.text.contains("basis="), "every decision must show its basis")
        XCTAssertTrue(r.text.contains("editorial act"))
    }

    func testRemoveWordsWithoutATranscriptPointsAtGetTranscript() throws {
        let url = try Self.makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = call("open_media", ["path": url.path])
        let r = call("remove_words", ["words": [1, 2]])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("get_transcript"), "said: \(r.text)")
    }

    func testUndoRestoresThePreviousState() throws {
        let url = try Self.makeMovie(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = call("open_media", ["path": url.path])
        let before = session.document!.timeline.duration
        let commandsBefore = session.log!.commands.count
        let r = call("undo")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(session.log!.commands.count, commandsBefore - 1)
        XCTAssertNotEqual(session.document!.timeline.duration, before, "the last placement is gone")
    }

    func testVerifyRunsTheAssertionsAndSaysSo() throws {
        let url = try Self.makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = call("open_media", ["path": url.path])
        let r = call("verify")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("assertions"))
        XCTAssertTrue(r.text.contains("clear to render"))
    }

    func testRenderWithoutAnOutputPathRefuses() throws {
        let url = try Self.makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = call("open_media", ["path": url.path])
        let r = call("render", [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("out"))
    }

    func testRenderProducesAFile() throws {
        let url = try Self.makeMovie(seconds: 2)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-render-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out) }
        _ = call("open_media", ["path": url.path])
        let r = call("render", ["out": out.path])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(r.text.contains("rendered 60 frames"), "said: \(r.text)")
    }

    func testAskingAHumanIsLoggedAsADefectWithItsRetirementPath() {
        let r = call("ask_human", ["category": "taste", "question": "which of these four takes reads best?"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("style profile"), "the tool must name what would retire this question: \(r.text)")
        XCTAssertEqual(session.elicitations.open.count, 1)
    }

    func testTheResidueCategoryDoesNotPretendToCollapse() {
        let r = call("ask_human", ["category": "failure", "question": "no B-roll matches this claim — cut it or punch in?"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("residue class"), "said: \(r.text)")
    }

    func testAskHumanRefusesAnUnknownCategoryAndListsTheRealOnes() {
        let r = call("ask_human", ["category": "vibes", "question": "does this feel right?"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("taste"))
        XCTAssertTrue(r.text.contains("groundTruth"))
    }

    func testAutonomyReportReadsAsProgress() {
        _ = call("ask_human", ["category": "intent", "question": "is the tangent at 14:20 on topic?"])
        let r = call("autonomy_report")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("1 question"))
    }

    func testTightenPausesNeedsItsArgument() throws {
        let url = try Self.makeMovie(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = call("open_media", ["path": url.path])
        let r = call("tighten_pauses", [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("maxSeconds"))
    }
}
