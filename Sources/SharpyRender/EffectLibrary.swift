// Effects the agent writes itself.
//
// This is the self-evolving part, and it is possible because of something that was already true:
// `MetalCompositor` builds its kernel from a Metal SOURCE STRING at runtime, and the colour
// pipeline already injects generated shader code into it. So an agent that meets an edit it cannot
// perform can write the missing effect, have it compiled, measured and registered, and use it in
// the same session — and the next video starts with it already there.
//
// The boundary is the design, not a restriction on it:
//
//   AN EFFECT IS DATA, never code. It is a Metal expression over a colour and some named numbers,
//   injected into a function with a fixed signature. It receives a pixel and its parameters and
//   returns a pixel. It cannot reach a texture, a file, the network, or the document — not because
//   it is policed, but because none of those are in scope where it runs.
//
//   IT MUST BE MEASURED BEFORE IT IS USABLE. Compiling proves it is valid Metal, which is not the
//   same as proving it does anything. A new effect is run over known inputs and rejected if it
//   produces NaN, or black, or leaves the picture untouched — an effect that silently does nothing
//   is worse than a missing one, because the agent will believe the edit was applied.
//
//   ITS BASIS IS `structuralInference`. The agent's own invention is not a measured fact and must
//   never outrank one. A look somebody wrote in the moment cannot overrule a safety constraint.
//
// What it deliberately cannot do is add a new KIND of thing — a new transport, a new codec, a new
// assertion. Those need real code and real review. It can add new looks, grades and pixel effects,
// which is where the long tail of "can you make it feel like X" actually lives.

import Foundation
import Metal
import SharpyEngine

public struct EffectParameter: Sendable, Codable, Equatable {
    public let name: String
    public let value: Float
    public let minimum: Float
    public let maximum: Float
    /// What the number means, in the agent's own words, so a person can change it knowingly.
    public let meaning: String

    public init(name: String, value: Float, minimum: Float, maximum: Float, meaning: String = "") {
        self.name = name; self.value = value
        self.minimum = minimum; self.maximum = maximum; self.meaning = meaning
    }
    public var clamped: Float { min(max(value, minimum), maximum) }
}

public struct EffectSpec: Sendable, Codable, Equatable {
    public let name: String
    /// What the agent says this does. Kept verbatim: an effect nobody can read is an effect nobody
    /// can refuse.
    public let summary: String
    public let parameters: [EffectParameter]
    /// Metal statements over `float3 c` and the named parameters, ending in a `return`.
    public let body: String
    public let authoredAt: Date

    public init(name: String, summary: String, parameters: [EffectParameter],
                body: String, authoredAt: Date = Date()) {
        self.name = name; self.summary = summary
        self.parameters = parameters; self.body = body; self.authoredAt = authoredAt
    }

    /// The function the compositor will call, with parameters bound as local constants so the body
    /// reads like arithmetic rather than array indexing.
    public var msl: String {
        var lines = ["static inline float3 SharpyLook(float3 c) {"]
        for p in parameters {
            lines.append("    const float \(p.name) = \(p.clamped);")
        }
        lines.append(body.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

public struct EffectValidation: Sendable {
    public let compiles: Bool
    public let compileError: String?
    /// Sample outputs for known inputs, so "it did something sensible" is a fact and not a hope.
    public let samples: [(input: SIMD3<Float>, output: SIMD3<Float>)]
    /// NaN *or* infinity. Checking only NaN was a real hole: `c / (c - c)` — the most likely way an
    /// author divides by zero — produces `inf`, which sailed through a NaN-only check and renders
    /// as garbage exactly the same way.
    public let producedNaN: Bool
    public let crushedToBlack: Bool
    public let changedNothing: Bool

    public var usable: Bool {
        compiles && !producedNaN && !crushedToBlack && !changedNothing
    }

    public var summary: String {
        guard compiles else { return "effect rejected — it does not compile:\n\(compileError ?? "")" }
        var faults: [String] = []
        if producedNaN { faults.append("produces NaN or infinity on ordinary input — it would render as garbage") }
        if crushedToBlack { faults.append("crushes everything to black") }
        if changedNothing { faults.append("leaves the picture untouched — an effect that silently does nothing is worse than a missing one, because the edit will be believed") }
        guard faults.isEmpty else { return "effect rejected — " + faults.joined(separator: "; ") }
        let shown = samples.prefix(3).map {
            String(format: "(%.2f %.2f %.2f) → (%.2f %.2f %.2f)",
                   $0.input.x, $0.input.y, $0.input.z, $0.output.x, $0.output.y, $0.output.z)
        }.joined(separator: ", ")
        return "effect accepted — \(shown)"
    }
}

public enum EffectError: Error, CustomStringConvertible {
    case unsafeSource(String)
    case noDevice
    case rejected(String)
    public var description: String {
        switch self {
        case .unsafeSource(let s): return "effect source rejected: \(s)"
        case .noDevice: return "no Metal device"
        case .rejected(let s): return s
        }
    }
}

public final class EffectLibrary {
    public let url: URL
    private var effects: [EffectSpec]

    public init(url: URL? = nil) throws {
        if let url {
            self.url = url
        } else {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sharpy", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.url = root.appendingPathComponent("effects.json")
        }
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([EffectSpec].self, from: data) {
            effects = decoded
        } else {
            effects = []
        }
    }

    public func all() -> [EffectSpec] { effects }
    public func named(_ name: String) -> EffectSpec? { effects.first { $0.name == name } }

    /// Tokens that would let a body escape its function. Metal cannot open a file or a socket, so
    /// the danger is not what a shader does to the machine — it is a body that closes its own
    /// function and redefines something the compositor relies on. That is a structural check, and
    /// structural checks are the kind worth having: it is exact, not a guess about intent.
    static let forbidden = ["#include", "#import", "kernel ", "[[", "texture", "device ",
                            "threadgroup", "constant ", "sampler", "extern", "__asm"]

    static func checkSafe(_ body: String) throws {
        for token in forbidden where body.contains(token) {
            throw EffectError.unsafeSource("contains \"\(token.trimmingCharacters(in: .whitespaces))\", which only makes sense outside a function body")
        }
        var depth = 0
        for character in body {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth < 0 { throw EffectError.unsafeSource("closes a brace it did not open") }
        }
        guard depth == 0 else { throw EffectError.unsafeSource("leaves \(depth) brace(s) open") }
        guard body.contains("return") else {
            throw EffectError.unsafeSource("never returns a colour")
        }
    }

    /// Compile the effect and run it over known inputs. Compiling proves it is valid Metal; this
    /// proves it does something, which is a different claim.
    public func validate(_ spec: EffectSpec, device: MTLDevice? = MTLCreateSystemDefaultDevice())
    throws -> EffectValidation {
        try EffectLibrary.checkSafe(spec.body)
        guard let device else { throw EffectError.noDevice }

        let probe = """
        #include <metal_stdlib>
        using namespace metal;
        \(spec.msl)
        kernel void probe(device const float3* input [[buffer(0)]],
                          device float3* output [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
            output[i] = SharpyLook(input[i]);
        }
        """
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: probe, options: nil) }
        catch {
            return EffectValidation(compiles: false, compileError: String(describing: error),
                                    samples: [], producedNaN: false, crushedToBlack: false,
                                    changedNothing: false)
        }
        guard let function = library.makeFunction(name: "probe"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue() else {
            return EffectValidation(compiles: false, compileError: "could not build a pipeline",
                                    samples: [], producedNaN: false, crushedToBlack: false,
                                    changedNothing: false)
        }

        // A spread that covers shadow, midtone, highlight and each primary — an effect that only
        // misbehaves in the shadows is exactly the one a single mid-grey probe would miss.
        let inputs: [SIMD3<Float>] = [
            SIMD3(0.02, 0.02, 0.02), SIMD3(0.18, 0.18, 0.18), SIMD3(0.5, 0.5, 0.5),
            SIMD3(0.9, 0.9, 0.9), SIMD3(0.8, 0.2, 0.2), SIMD3(0.2, 0.6, 0.3),
        ]
        let stride = MemoryLayout<SIMD3<Float>>.stride
        guard let inBuffer = device.makeBuffer(bytes: inputs, length: stride * inputs.count),
              let outBuffer = device.makeBuffer(length: stride * inputs.count),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else {
            throw EffectError.noDevice
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: inputs.count, height: 1, depth: 1))
        encoder.endEncoding(); commands.commit(); commands.waitUntilCompleted()

        let outputs = UnsafeBufferPointer(start: outBuffer.contents().assumingMemoryBound(to: SIMD3<Float>.self),
                                          count: inputs.count)
        var samples: [(SIMD3<Float>, SIMD3<Float>)] = []
        var sawNaN = false, allBlack = true, identical = true
        for (i, o) in zip(inputs, outputs) {
            samples.append((i, o))
            if !o.x.isFinite || !o.y.isFinite || !o.z.isFinite { sawNaN = true }
            if o.x > 0.001 || o.y > 0.001 || o.z > 0.001 { allBlack = false }
            if abs(o.x - i.x) > 0.002 || abs(o.y - i.y) > 0.002 || abs(o.z - i.z) > 0.002 { identical = false }
        }
        return EffectValidation(compiles: true, compileError: nil, samples: samples,
                                producedNaN: sawNaN, crushedToBlack: allBlack,
                                changedNothing: identical)
    }

    /// Validate, then keep. Only effects that passed are written, so the library is by construction
    /// a set of things that work — a library holding a broken effect is a trap for the next session.
    @discardableResult
    public func register(_ spec: EffectSpec) throws -> EffectValidation {
        let validation = try validate(spec)
        guard validation.usable else { throw EffectError.rejected(validation.summary) }
        effects.removeAll { $0.name == spec.name }
        effects.append(spec)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(effects).write(to: url, options: .atomic)
        return validation
    }
}
