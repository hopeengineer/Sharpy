// Caching for the scene layer.
//
// The producer lives here because it links MLX; the cache and the type live in SharpyPerception so
// the store, the report and the MCP tools can serve a scene index without linking MLX. This
// extension is the seam between the two.

import Foundation
import SharpyEngine
import SharpyPerception

extension IndexStore {
    /// The scene index for an asset, produced once and cached.
    ///
    /// Vision is fetched first and passed in rather than made optional, because without it every
    /// claim is `unchecked` — an uncorroborated index is the thing this layer exists to avoid, and
    /// caching one would make the weakest possible result the permanent one.
    public func sceneIndex(for url: URL,
                           modelDirectory: URL,
                           options: SceneIndexOptions = SceneIndexOptions())
    async throws -> (SceneIndex, Bool) {
        let fingerprint = try MediaFingerprint(of: url)
        var record = load(fingerprint) ?? PerceptionRecord(fingerprint: fingerprint, path: url.path)
        let version = IndexStore.versions["scene"]
        if let existing = record.scene, record.producedBy["scene"] == version {
            return (existing, true)
        }
        let asset = NodeID(contentOf: url.path)
        // Sample Vision at the same rate, so every scene claim has a Vision observation to be
        // checked against rather than the nearest one from an unrelated instant.
        let vision = try vision(for: url,
                                indexer: VisionIndexer(options: VisionIndexOptions(
                                    samplesPerSecond: 1 / options.secondsPerSample))).0
        let produced = try await SceneIndexer(modelDirectory: modelDirectory, options: options)
            .index(url: url, asset: asset, vision: vision)
        record.scene = produced
        record.producedBy["scene"] = version
        record.path = url.path
        try save(record)
        return (produced, false)
    }
}
