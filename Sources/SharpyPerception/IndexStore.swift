// A content-addressed cache for perception results.
//
// The agent re-reads the same footage on every turn. Transcription is cheap enough to redo (1.4 s
// for 88 s of audio), but the VLM pass measured ~19 minutes per hour of footage, so re-deriving it
// per question is not a slow path — it is an unusable one. Everything perceived is therefore keyed
// by *what was analysed* and *how*, and never recomputed unless one of those changes.
//
// The key deliberately does not hash the whole file. A 3 GB ProRes master would take longer to
// hash than to transcribe. Size + modification time + the first and last megabyte catches
// re-encodes, truncations and edits in place, which is every way media actually changes on disk;
// it would miss a change to the exact middle of a file that preserved its size and mtime, which is
// not a thing that happens outside a deliberate attempt to defeat it.

import Foundation
import CryptoKit
import SharpyEngine

public struct MediaFingerprint: Sendable, Equatable, Codable, CustomStringConvertible {
    public let hex: String
    public var description: String { String(hex.prefix(12)) }

    public init(of url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        var hasher = SHA256()
        hasher.update(data: Data("\(size)|\(modified)".utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let edge = 1_048_576
        if let head = try handle.read(upToCount: edge) { hasher.update(data: head) }
        if size > Int64(edge) * 2 {
            try handle.seek(toOffset: UInt64(size - Int64(edge)))
            if let tail = try handle.readToEnd() { hasher.update(data: tail) }
        }
        hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything perceived about one asset. Layers are optional because they are filled in by
/// different passes at different costs — a report can be produced from whichever exist.
public struct PerceptionRecord: Sendable, Codable {
    public var fingerprint: MediaFingerprint
    public var path: String
    public var transcript: Transcript?
    public var vision: VisionIndex?
    public var shots: ShotIndex?
    /// The two-engine transcript: WhisperKit's words, Apple's vote, per-word agreement.
    public var votedTranscript: Transcript?
    public var speakers: SpeakerIndex?
    /// Analyser versions, so a changed algorithm invalidates its own layer and nothing else.
    public var producedBy: [String: String]

    public init(fingerprint: MediaFingerprint, path: String, transcript: Transcript? = nil,
                vision: VisionIndex? = nil, shots: ShotIndex? = nil, votedTranscript: Transcript? = nil,
                speakers: SpeakerIndex? = nil, producedBy: [String: String] = [:]) {
        self.fingerprint = fingerprint; self.path = path
        self.transcript = transcript; self.vision = vision; self.shots = shots
        self.votedTranscript = votedTranscript; self.speakers = speakers
        self.producedBy = producedBy
    }
}

public final class IndexStore {
    public let root: URL

    /// Bump a layer's version when its algorithm changes; the cache then re-derives just that layer.
    public static let versions: [String: String] = [
        "transcript": "apple-speechanalyzer/1",
        "vision": "apple-vision/1",
        "shots": "histogram-content/1",
        "votedTranscript": "whisperkit-large-v3-turbo+parakeet-tdt-v3/2",
        "speakers": "speakerkit-pyannote/1",
    ]

    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Sharpy/index", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    private func url(for fingerprint: MediaFingerprint) -> URL {
        // Two-level fan-out keeps any one directory small.
        let a = String(fingerprint.hex.prefix(2))
        return root.appendingPathComponent(a, isDirectory: true)
            .appendingPathComponent("\(fingerprint.hex).json")
    }

    public func load(_ fingerprint: MediaFingerprint) -> PerceptionRecord? {
        guard let data = try? Data(contentsOf: url(for: fingerprint)) else { return nil }
        return try? JSONDecoder().decode(PerceptionRecord.self, from: data)
    }

    public func save(_ record: PerceptionRecord) throws {
        let target = url(for: record.fingerprint)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: target, options: .atomic)
    }

    /// Fetch a cached layer, or produce and store it. `layer` names the version key.
    public func value<T>(_ layer: String, for url: URL,
                         get: (PerceptionRecord) -> T?,
                         set: (inout PerceptionRecord, T) -> Void,
                         produce: () throws -> T) throws -> (value: T, wasCached: Bool) {
        let fingerprint = try MediaFingerprint(of: url)
        var record = load(fingerprint) ?? PerceptionRecord(fingerprint: fingerprint, path: url.path)
        let currentVersion = IndexStore.versions[layer]
        if let existing = get(record), record.producedBy[layer] == currentVersion {
            return (existing, true)
        }
        let produced = try produce()
        set(&record, produced)
        record.producedBy[layer] = currentVersion
        record.path = url.path
        try save(record)
        return (produced, false)
    }

    /// Remove every cached record. Returns how many files went.
    @discardableResult
    public func clear() throws -> Int {
        let fm = FileManager.default
        var removed = 0
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        for case let f as URL in e where f.pathExtension == "json" {
            try? fm.removeItem(at: f); removed += 1
        }
        return removed
    }

    public var count: Int {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for case let f as URL in e where f.pathExtension == "json" { n += 1 }
        return n
    }
}

// MARK: - Convenience

extension IndexStore {
    @available(macOS 26.0, *)
    public func transcript(for url: URL, indexer: SpeechIndexer = SpeechIndexer()) async throws -> (Transcript, Bool) {
        let fingerprint = try MediaFingerprint(of: url)
        var record = load(fingerprint) ?? PerceptionRecord(fingerprint: fingerprint, path: url.path)
        if let existing = record.transcript, record.producedBy["transcript"] == IndexStore.versions["transcript"] {
            return (existing, true)
        }
        let produced = try await indexer.transcribe(url: url, asset: NodeID(contentOf: url.path))
        record.transcript = produced
        record.producedBy["transcript"] = IndexStore.versions["transcript"]
        record.path = url.path
        try save(record)
        return (produced, false)
    }

    public func shots(for url: URL, detector: ShotDetector = ShotDetector()) throws -> (ShotIndex, Bool) {
        try value("shots", for: url,
                  get: { $0.shots }, set: { $0.shots = $1 },
                  produce: { try detector.detect(url: url, asset: NodeID(contentOf: url.path)) })
    }

    public func vision(for url: URL, indexer: VisionIndexer = VisionIndexer()) throws -> (VisionIndex, Bool) {
        try value("vision", for: url,
                  get: { $0.vision }, set: { $0.vision = $1 },
                  produce: { try indexer.index(url: url, asset: NodeID(contentOf: url.path)) })
    }
}
