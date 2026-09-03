// The perception cache. Its correctness question is not "is it fast" but "does it ever return a
// result for material or a method that no longer matches" — a stale transcript is worse than a
// slow one, because every downstream decision inherits it silently.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class IndexStoreTests: XCTestCase {
    var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-store-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    /// Write a file with known content and return its URL.
    func makeFile(_ contents: String) throws -> URL {
        let url = root.appendingPathComponent("m-\(UUID().uuidString).bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testFingerprintChangesWithContent() throws {
        let a = try makeFile(String(repeating: "a", count: 4096))
        let b = try makeFile(String(repeating: "b", count: 4096))
        XCTAssertNotEqual(try MediaFingerprint(of: a), try MediaFingerprint(of: b))
        XCTAssertEqual(try MediaFingerprint(of: a), try MediaFingerprint(of: a), "stable for unchanged content")
    }

    func testFingerprintChangesWhenAFileIsRewrittenInPlace() throws {
        let url = try makeFile(String(repeating: "x", count: 4096))
        let before = try MediaFingerprint(of: url)
        // Same length, different bytes, and a new mtime — the re-encode case.
        Thread.sleep(forTimeInterval: 0.01)
        try Data(String(repeating: "y", count: 4096).utf8).write(to: url)
        XCTAssertNotEqual(before, try MediaFingerprint(of: url), "a re-encode must invalidate the cache")
    }

    func testRoundTripsARecord() throws {
        let store = try IndexStore(root: root)
        let url = try makeFile("hello")
        let fp = try MediaFingerprint(of: url)
        let t = Transcript(asset: NodeID(contentOf: url.path),
                           words: [Word(index: 0, text: "hello", range: TimeRange(start: .zero, duration: TimeValue(seconds: Rational(1))), confidence: Rational(9, 10))],
                           engines: ["test"])
        try store.save(PerceptionRecord(fingerprint: fp, path: url.path, transcript: t, producedBy: ["transcript": "test/1"]))
        let loaded = store.load(fp)
        XCTAssertEqual(loaded?.transcript?.words.first?.text, "hello")
        XCTAssertEqual(loaded?.producedBy["transcript"], "test/1")
        XCTAssertEqual(store.count, 1)
    }

    func testProducesOnceThenServesFromCache() throws {
        let store = try IndexStore(root: root)
        let url = try makeFile("content")
        var calls = 0
        func run() throws -> (value: VisionIndex, wasCached: Bool) {
            try store.value("vision", for: url,
                            get: { $0.vision }, set: { $0.vision = $1 },
                            produce: {
                                calls += 1
                                return VisionIndex(asset: NodeID(contentOf: url.path), frames: [], width: 1, height: 1)
                            })
        }
        let first = try run()
        XCTAssertFalse(first.wasCached); XCTAssertEqual(calls, 1)
        let second = try run()
        XCTAssertTrue(second.wasCached); XCTAssertEqual(calls, 1, "the producer must not run again")
    }

    /// The subtle one: a changed analyser must invalidate its own layer and leave the others alone.
    func testAVersionBumpInvalidatesOnlyThatLayer() throws {
        let store = try IndexStore(root: root)
        let url = try makeFile("content")
        let fp = try MediaFingerprint(of: url)
        let t = Transcript(asset: NodeID(contentOf: url.path), words: [], engines: ["speech"])
        try store.save(PerceptionRecord(fingerprint: fp, path: url.path, transcript: t,
                                        vision: VisionIndex(asset: NodeID(contentOf: url.path), frames: [], width: 9, height: 9),
                                        producedBy: ["transcript": IndexStore.versions["transcript"]!,
                                                     "vision": "apple-vision/OLD"]))
        var visionCalls = 0
        let (v, cached) = try store.value("vision", for: url,
                                          get: { $0.vision }, set: { $0.vision = $1 },
                                          produce: {
                                              visionCalls += 1
                                              return VisionIndex(asset: NodeID(contentOf: url.path), frames: [], width: 42, height: 42)
                                          })
        XCTAssertFalse(cached, "a stale version must not be served")
        XCTAssertEqual(visionCalls, 1)
        XCTAssertEqual(v.width, 42)
        // The transcript layer, whose version still matches, survives untouched.
        XCTAssertNotNil(store.load(fp)?.transcript)
        XCTAssertEqual(store.load(fp)?.producedBy["transcript"], IndexStore.versions["transcript"])
    }

    func testClearRemovesEverything() throws {
        let store = try IndexStore(root: root)
        for i in 0..<3 {
            let url = try makeFile("f\(i)")
            try store.save(PerceptionRecord(fingerprint: try MediaFingerprint(of: url), path: url.path))
        }
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(try store.clear(), 3)
        XCTAssertEqual(store.count, 0)
    }
}
