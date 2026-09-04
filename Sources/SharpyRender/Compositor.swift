// Single-pass Metal compositor. Every layer is sampled once per output pixel inside one compute
// dispatch; decoder output is wrapped as textures zero-copy through CVMetalTextureCache. This is
// the design that measured 135 fps at four 4K H.264 layers (bench/metal_composite_bench.swift),
// where Core Image collapsed to 8.9. Colour management (OCIO-emitted MSL) slots into `toRGB`.

import Metal
import CoreVideo
import simd

public struct LayerPlacement: Sendable, Equatable {
    /// Top-left of the layer in output pixels.
    public var offset: SIMD2<Float>
    /// Uniform scale relative to the layer's native size.
    public var scale: Float
    /// 0…1, straight alpha applied as "over".
    public var opacity: Float
    public init(offset: SIMD2<Float> = .zero, scale: Float = 1, opacity: Float = 1) {
        self.offset = offset; self.scale = scale; self.opacity = opacity
    }
    public static let full = LayerPlacement()
}

public struct CompositeLayer {
    public let pixelBuffer: CVPixelBuffer
    public let placement: LayerPlacement
    public init(pixelBuffer: CVPixelBuffer, placement: LayerPlacement = .full) { self.pixelBuffer = pixelBuffer; self.placement = placement }
}

public enum CompositorError: Error, CustomStringConvertible {
    case noDevice, shaderCompile(String), textureCache, unsupportedPixelFormat(OSType), tooManyLayers(Int)
    public var description: String {
        switch self {
        case .noDevice: return "no Metal device"
        case .shaderCompile(let s): return "shader: \(s)"
        case .textureCache: return "CVMetalTextureCache creation failed"
        case .unsupportedPixelFormat(let f): return "unsupported pixel format \(f)"
        case .tooManyLayers(let n): return "\(n) layers exceeds kernel maximum \(MetalCompositor.maxLayers)"
        }
    }
}

public final class MetalCompositor: @unchecked Sendable {
    public static let maxLayers = 8
    public let device: MTLDevice
    /// The colour pipeline compiled into this compositor's kernel. Changing it needs a new
    /// compositor: the transforms are specialised into the shader, not branched on per pixel.
    public let colorPipeline: ColorPipeline
    private let queue: MTLCommandQueue
    private let pso: MTLComputePipelineState
    /// The same kernel with ID emission switched on by a function constant, so the ordinary render
    /// path pays nothing for a feature it does not use — the branch is compiled out, not taken.
    private let psoWithIDs: MTLComputePipelineState
    private let cache: CVMetalTextureCache

    private struct LayerUniform {
        var offset: SIMD2<Float>; var scale: Float; var opacity: Float
        var srcSize: SIMD2<Float>; var isBGRA: UInt32; var matrix: UInt32 = 0
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                colorPipeline: ColorPipeline = .passthrough) throws {
        guard let device else { throw CompositorError.noDevice }
        self.device = device
        self.colorPipeline = colorPipeline
        guard let q = device.makeCommandQueue() else { throw CompositorError.noDevice }
        queue = q
        let source = MetalCompositor.shaderSource(colorPipeline)
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: source, options: nil) }
        catch { throw CompositorError.shaderCompile(String(describing: error)) }
        // Both variants must be specialised explicitly: a function with an unresolved constant
        // cannot build a pipeline state at all, even for the branch that ignores it.
        func specialised(emitIDs: Bool) throws -> MTLFunction {
            let constants = MTLFunctionConstantValues()
            var flag = emitIDs
            constants.setConstantValue(&flag, type: .bool, index: 0)
            do { return try lib.makeFunction(name: "composite", constantValues: constants) }
            catch { throw CompositorError.shaderCompile("composite(emitIDs: \(emitIDs)): \(error)") }
        }
        pso = try device.makeComputePipelineState(function: specialised(emitIDs: false))
        psoWithIDs = try device.makeComputePipelineState(function: specialised(emitIDs: true))
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c) == kCVReturnSuccess, let c else { throw CompositorError.textureCache }
        cache = c
    }

    public func makeOutputTexture(width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    /// A texture for the ID + coverage pass, sized to the output.
    ///
    /// `.shared` because it exists to be read back on the CPU and asserted against. On Apple
    /// silicon that costs nothing — the GPU writes into the same memory the assertions read.
    public func makeIDTexture(width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Uint, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    /// Wrap an IOSurface-backed BGRA pixel buffer as the output texture (zero-copy into an encoder).
    public func outputTexture(for pixelBuffer: CVPixelBuffer) throws -> (MTLTexture, CVMetalTexture) {
        var t: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &t)
        guard let t, let tex = CVMetalTextureGetTexture(t) else { throw CompositorError.textureCache }
        return (tex, t)
    }

    /// Composite `layers` (bottom first) into `output`. Returns the command buffer; the caller
    /// commits it and may chain further work. Source textures stay alive until completion.
    @discardableResult
    public func encode(layers: [CompositeLayer], into output: MTLTexture,
                       ids: MTLTexture? = nil) throws -> MTLCommandBuffer {
        guard layers.count <= MetalCompositor.maxLayers else { throw CompositorError.tooManyLayers(layers.count) }
        var keep: [CVMetalTexture] = []
        var plane0: [MTLTexture?] = Array(repeating: nil, count: MetalCompositor.maxLayers)
        var plane1: [MTLTexture?] = Array(repeating: nil, count: MetalCompositor.maxLayers)
        var uniforms: [LayerUniform] = []
        for (i, layer) in layers.enumerated() {
            let pb = layer.pixelBuffer
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            var t0: CVMetalTexture?, t1: CVMetalTexture?
            switch fmt {
            case kCVPixelFormatType_32BGRA:
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &t0)
                guard let t0 else { throw CompositorError.textureCache }
                keep.append(t0); plane0[i] = CVMetalTextureGetTexture(t0); plane1[i] = plane0[i]
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .r8Unorm, w, h, 0, &t0)
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .rg8Unorm, w / 2, h / 2, 1, &t1)
                guard let t0, let t1 else { throw CompositorError.textureCache }
                keep.append(t0); keep.append(t1)
                plane0[i] = CVMetalTextureGetTexture(t0); plane1[i] = CVMetalTextureGetTexture(t1)
            default:
                throw CompositorError.unsupportedPixelFormat(fmt)
            }
            let tag = ColorTag.of(pb)
            uniforms.append(LayerUniform(offset: layer.placement.offset, scale: layer.placement.scale, opacity: layer.placement.opacity,
                                         srcSize: SIMD2(Float(w), Float(h)), isBGRA: fmt == kCVPixelFormatType_32BGRA ? 1 : (tag.fullRange ? 2 : 0),
                                         matrix: tag.matrix.rawValue))
        }
        for i in layers.count..<MetalCompositor.maxLayers { plane0[i] = plane0[0] ?? output; plane1[i] = plane1[0] ?? output }
        while uniforms.count < MetalCompositor.maxLayers { uniforms.append(LayerUniform(offset: .zero, scale: 1, opacity: 0, srcSize: .one, isBGRA: 1, matrix: 0)) }

        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw CompositorError.noDevice }
        let held = keep
        cb.addCompletedHandler { _ in _ = held.count }
        enc.setComputePipelineState(ids == nil ? pso : psoWithIDs)
        enc.setTexture(output, index: 0)
        if let ids { enc.setTexture(ids, index: 1 + 2 * MetalCompositor.maxLayers) }
        enc.setTextures(plane0, range: 1..<(1 + MetalCompositor.maxLayers))
        enc.setTextures(plane1, range: (1 + MetalCompositor.maxLayers)..<(1 + 2 * MetalCompositor.maxLayers))
        var n = UInt32(layers.count)
        enc.setBytes(&uniforms, length: MemoryLayout<LayerUniform>.stride * MetalCompositor.maxLayers, index: 0)
        enc.setBytes(&n, length: 4, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (output.width + 15) / 16, height: (output.height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        return cb
    }

    /// The kernel, with OCIO's generated transforms specialised in.
    static func shaderSource(_ pipeline: ColorPipeline) -> String { header + pipeline.mslPrelude + body }

    static let header = """
    #include <metal_stdlib>
    using namespace metal;

    """

    static let body = """
    struct Layer { float2 offset; float scale; float opacity; float2 srcSize; uint isBGRA; uint matrix; };
    // Off by default. With it off the ID texture is never bound and every line guarded by it is
    // compiled away, so the ordinary render path is byte-for-byte the kernel that measured 83.4 fps
    // at four 4K layers.
    constant bool kEmitIDs [[function_constant(0)]];
    // YCbCr -> RGB by the buffer's own matrix tag (0 = BT.709, 1 = BT.601, 2 = BT.2020), video or
    // full range. Colour management (OCIO-emitted MSL) replaces this stage; the tag stays the input.
    static inline float3 toRGB(float y, float2 cbcr, uint fullRange, uint matrix) {
        if (fullRange == 0) { y = (y - 16.0/255.0) * (255.0/219.0); cbcr = (cbcr - 0.5) * (255.0/224.0); }
        else { cbcr = cbcr - 0.5; }
        float kr = 0.2126, kb = 0.0722;                       // 709
        if (matrix == 1) { kr = 0.299; kb = 0.114; }          // 601
        else if (matrix == 2) { kr = 0.2627; kb = 0.0593; }   // 2020
        float kg = 1.0 - kr - kb;
        float r = y + 2.0 * (1.0 - kr) * cbcr.y;
        float b = y + 2.0 * (1.0 - kb) * cbcr.x;
        float g = y - (2.0 * kb * (1.0 - kb) * cbcr.x + 2.0 * kr * (1.0 - kr) * cbcr.y) / kg;
        return float3(r, g, b);
    }
    kernel void composite(texture2d<float, access::write> out [[texture(0)]],
                          array<texture2d<float, access::sample>, 8> p0 [[texture(1)]],
                          array<texture2d<float, access::sample>, 8> p1 [[texture(9)]],
                          texture2d<uint, access::write> ids [[texture(17), function_constant(kEmitIDs)]],
                          constant Layer* layers [[buffer(0)]],
                          constant uint& n [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 rgb = float3(0.0);
        float a = 0.0;
        // Cryptomatte-style identity, adapted to a bounded layer count.
        //   present : bit i set if layer i landed inside this pixel with any opacity at all.
        //   owner   : the TOPMOST layer still visible here after everything above it composited,
        //             which is the layer a viewer would say this pixel belongs to.
        // Both are exact on the renderer's side: they are what the compositor did, not an estimate
        // of it. That is the whole point — a spatial assertion stops sampling and starts proving.
        uint present = 0u;
        uint owner = 0xFFFFFFFFu;
        float ownerWeight = 0.0;
        for (uint i = 0; i < n; i++) {
            Layer L = layers[i];
            float2 p = (float2(gid) + 0.5 - L.offset) / L.scale;     // source pixel coords
            if (p.x < 0.0 || p.y < 0.0 || p.x >= L.srcSize.x || p.y >= L.srcSize.y) continue;
            float2 uv = p / L.srcSize;
            float3 c = (L.isBGRA == 1) ? p0[i].sample(s, uv).rgb : toRGB(p0[i].sample(s, uv).r, p1[i].sample(s, uv).rg, L.isBGRA == 2 ? 1u : 0u, L.matrix);
            // Into the linear working space before blending: light adds, display code values do not.
            c = SharpyInputTransform(float4(c, 1.0)).rgb;
            float la = L.opacity;
            if (kEmitIDs && la > 0.0) {
                present |= (1u << i);
                // Every layer already composited is attenuated by this one. Tracking the survivor
                // rather than "the last layer drawn" is what makes a transparent layer stop
                // claiming pixels it does not actually own.
                ownerWeight *= (1.0 - la);
                if (la >= ownerWeight) { owner = i; ownerWeight = la; }
            }
            rgb = c * la + rgb * (1.0 - la);
            a = la + a * (1.0 - la);
        }
        // One display transform on the composited result.
        rgb = SharpyOutputTransform(float4(rgb, 1.0)).rgb;
        out.write(float4(saturate(rgb), a), gid);
        if (kEmitIDs) { ids.write(uint4(present, owner, 0u, 0u), gid); }
    }
    """
}
