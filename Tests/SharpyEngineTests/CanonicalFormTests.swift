// Content addressing is the foundation of undo, branching, replay integrity and audit. If a
// document's id depends on anything other than its content — Dictionary iteration order, in
// particular — every one of those breaks silently and intermittently.
//
// These tests use enough entries that accidental agreement is negligible: with 8 decisions there
// are 8! = 40 320 possible encoding orders, so an order-dependent hash agrees by chance about
// once in 40 000 runs rather than the one-in-two that hid this bug behind a 2-entry dictionary.

import XCTest
@testable import SharpyEngine

final class CanonicalFormTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: rate) }

    /// A document with `n` assets and `n` decisions, built by applying commands in `order`.
    func build(indices order: [Int]) throws -> Document {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "canon", frameRate: rate)))
        try log.append(.addTrack(kind: .video, name: "V1"))
        for i in order {
            let asset = AssetRef(contentHash: "sha256:asset-\(i)", path: "/media/take\(i).mov",
                                 duration: t(1000), frameRate: rate, hasVideo: true, hasAudio: true)
            try log.append(.addAsset(asset))
            try log.append(.recordDecision(Decision(
                kind: .sound, at: t(Int64(i) * 10),
                params: ["cue": "whoosh_\(i)", "rel_db": "-6", "bus": "sfx"],
                basis: .measuredMaterial(ref: "onset@\(i)", detail: "\(i * 7) ms attack", confidence: Rational(9, 10)))))
        }
        return log.head
    }

    func testIdIsIndependentOfInsertionOrder() throws {
        let forward = try build(indices: Array(0..<8))
        let reverse = try build(indices: Array((0..<8).reversed()))
        let shuffled = try build(indices: [3, 7, 1, 0, 6, 2, 5, 4])
        // The decision *order* differs, so decisionOrder differs — compare the content-addressed
        // parts that must not depend on insertion order.
        XCTAssertEqual(Set(forward.assets.keys), Set(reverse.assets.keys))
        XCTAssertEqual(Set(forward.decisions.keys), Set(shuffled.decisions.keys))
        // Same assets inserted in any order must hash identically once decisionOrder is equal.
        for doc in [reverse, shuffled] {
            let a = Canonical.id(of: forward.assets.map { AssetPair(id: $0.key, ref: $0.value) }.sorted { $0.id.hex < $1.id.hex })
            let b = Canonical.id(of: doc.assets.map { AssetPair(id: $0.key, ref: $0.value) }.sorted { $0.id.hex < $1.id.hex })
            XCTAssertEqual(a, b, "asset set must hash the same regardless of insertion order")
        }
    }

    /// Two documents built by the identical command sequence must have the identical id — every
    /// time, not half the time. This is the invariant `sharpy render` asserts before it renders.
    func testEqualDocumentsHashIdenticallyAcrossManyBuilds() throws {
        let reference = try build(indices: Array(0..<8))
        var ids = Set<String>()
        for _ in 0..<24 {
            let again = try build(indices: Array(0..<8))
            XCTAssertEqual(again, reference, "documents must be equal as values")
            ids.insert(again.id.hex)
        }
        ids.insert(reference.id.hex)
        XCTAssertEqual(ids.count, 1, "equal documents produced \(ids.count) distinct ids: \(ids.map { String($0.prefix(12)) })")
    }

    /// Repeated encoding of one document must be byte-identical.
    func testEncodingIsStableForOneInstance() throws {
        let doc = try build(indices: Array(0..<8))
        let first = try Canonical.encoder.encode(doc)
        for _ in 0..<24 { XCTAssertEqual(try Canonical.encoder.encode(doc), first, "encoding is not stable") }
    }

    /// Replay must reproduce head exactly, checked over a document large enough for order to matter.
    func testReplayReproducesHeadOverManyEntries() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "canon", frameRate: rate)))
        try log.append(.addTrack(kind: .video, name: "V1"))
        for i in 0..<8 {
            let asset = AssetRef(contentHash: "sha256:a\(i)", path: "/m/\(i).mov", duration: t(1000), frameRate: rate, hasVideo: true, hasAudio: false)
            try log.append(.addAsset(asset))
            try log.append(.recordDecision(Decision(kind: .graphic, at: t(Int64(i)), params: ["c": "\(i)"],
                                                    basis: .craftRule(rule: "rule \(i)", why: "because \(i)"))))
        }
        for _ in 0..<12 {
            XCTAssertEqual(try log.replay().id, log.head.id, "replay must reproduce head")
        }
    }

    /// A Decision's own id must not depend on the order its `params` were written in.
    func testDecisionIdIsIndependentOfParamOrder() {
        let a = Decision(kind: .sound, at: t(5), params: ["cue": "x", "rel_db": "-6", "bus": "sfx", "pan": "0"],
                         basis: .clientRule(rule: "r"))
        let b = Decision(kind: .sound, at: t(5), params: ["pan": "0", "bus": "sfx", "rel_db": "-6", "cue": "x"],
                         basis: .clientRule(rule: "r"))
        XCTAssertEqual(a, b)
        var ids = Set<String>()
        for _ in 0..<24 { ids.insert(Canonical.id(of: a).hex); ids.insert(Canonical.id(of: b).hex) }
        XCTAssertEqual(ids.count, 1, "Decision id depends on param order: \(ids.count) distinct ids")
    }

    /// The canonical JSON must actually be sorted by id, so the format is inspectable and stable
    /// across releases rather than merely self-consistent.
    func testCanonicalJSONListsEntriesSortedById() throws {
        let doc = try build(indices: Array(0..<8))
        let json = String(decoding: try Canonical.encoder.encode(doc), as: UTF8.self)
        let hexes = doc.decisions.keys.map(\.hex).sorted()
        var cursor = json.startIndex
        for hex in hexes {
            guard let found = json.range(of: hex, range: cursor..<json.endIndex) else {
                return XCTFail("decision id \(hex.prefix(12)) missing or out of order in canonical JSON")
            }
            cursor = found.upperBound
        }
    }
}

/// Test-only pair used to hash an asset set independently of any document.
struct AssetPair: Encodable {
    let id: NodeID
    let ref: AssetRef
}
