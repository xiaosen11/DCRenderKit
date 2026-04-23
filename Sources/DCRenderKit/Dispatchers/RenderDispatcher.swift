//
//  RenderDispatcher.swift
//  DCRenderKit
//
//  Encodes render pipeline dispatches (vertex + fragment). Supports
//  custom vertex buffers, blend modes, sampler state, load actions, and
//  batched multi-draw passes — the feature set real render workloads
//  (stickers, distortion meshes, lens correction) require.
//

import Foundation
import Metal

/// Encodes render (rasterization) pipeline dispatches with a fixed binding
/// convention shared across all DCRenderKit render shaders.
///
/// ## Why not a minimal full-screen-quad backend
///
/// A naive render backend hard-codes a full-screen quad, `bgra8Unorm`, a
/// `.clear` load action, and no blend or sampler state. That works for
/// post-effects that just re-run a fragment shader on a texture, but it
/// makes real render workloads impossible:
///
/// - **Stickers** need custom geometry (positioned quads with MVP transforms),
///   alpha blending, and the ability to draw multiple stickers into the
///   same target (load action `.load`, not `.clear`).
/// - **Lens correction / fisheye** need a tessellated mesh whose vertex
///   shader evaluates the lens model, not a fixed quad.
/// - **Light leaks / glows** need additive blending.
/// - **Incremental effects** need to read the existing destination, so
///   `.clear` would destroy prior contents.
///
/// `RenderDispatcher` exposes all of these as first-class parameters.
///
/// ## Binding convention
///
/// ```metal
/// // VERTEX SHADER
/// vertex VertexOut my_vertex(
///     uint                 vid      [[vertex_id]],
///     constant VertexData* vertices [[buffer(0)]],  // ← vertexBuffer
///     constant VertexU&    u        [[buffer(1)]]   // ← vertexUniforms
/// ) { ... }
///
/// // FRAGMENT SHADER
/// fragment half4 my_fragment(
///     VertexOut              in       [[stage_in]],
///     texture2d<half>        tex0     [[texture(0)]],     // ← fragmentTextures[0]
///     texture2d<half>        tex1     [[texture(1)]],     // ← fragmentTextures[1]
///     sampler                s0       [[sampler(0)]],     // ← samplers[0]
///     sampler                s1       [[sampler(1)]],     // ← samplers[1]
///     constant FragU&        u        [[buffer(0)]]       // ← fragmentUniforms
/// ) { ... }
/// ```
///
/// ## Dispatch modes
///
/// - `dispatch(...)` — single draw call. Most common case (render one quad).
/// - `dispatchBatch(...)` — multiple draw calls sharing one render encoder.
///   Used for sticker batches (N stickers in one pass) and any scenario
///   where you want to avoid encoder churn.
public struct RenderDispatcher {

    // MARK: - Single-draw API

    /// Encode a single draw call into `commandBuffer`.
    ///
    /// Creates a render pass, sets up bindings, draws the given primitives,
    /// and ends encoding. Caller commits the command buffer.
    ///
    /// - Parameters:
    ///   - descriptor: Pipeline configuration (shaders + pixel format + blend).
    ///   - vertexBuffer: The buffer holding vertex data at `buffer(0)`.
    ///   - vertexBufferOffset: Byte offset into `vertexBuffer` (default 0).
    ///   - vertexCount: Number of vertices to draw.
    ///   - primitiveType: Triangle strip, triangle list, etc.
    ///   - vertexUniforms: Uniforms for the vertex stage (`buffer(1)`).
    ///   - fragmentUniforms: Uniforms for the fragment stage (`buffer(0)`).
    ///   - fragmentTextures: Textures for the fragment stage (`texture(0+)`).
    ///   - samplers: Sampler configs for the fragment stage (`sampler(0+)`).
    ///   - destination: Target color attachment. Must have `.renderTarget` usage.
    ///   - loadAction: How to initialize the target (`.clear` / `.load` / `.dontCare`).
    ///   - clearColor: Background color when `loadAction == .clear`.
    ///   - commandBuffer: Buffer to encode into.
    ///   - psoCache: PSO cache (default shared).
    ///   - uniformPool: Uniform buffer pool (default shared).
    ///   - samplerCache: Sampler cache (default shared).
    public static func dispatch(
        descriptor: RenderPSODescriptor,
        vertexBuffer: MTLBuffer,
        vertexBufferOffset: Int = 0,
        vertexCount: Int,
        primitiveType: MTLPrimitiveType = .triangleStrip,
        vertexUniforms: FilterUniforms = .empty,
        fragmentUniforms: FilterUniforms = .empty,
        fragmentTextures: [MTLTexture] = [],
        samplers: [SamplerConfig] = [.linearClamp],
        destination: MTLTexture,
        loadAction: MTLLoadAction = .clear,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
        commandBuffer: MTLCommandBuffer,
        psoCache: PipelineStateCache = .shared,
        uniformPool: UniformBufferPool = .shared,
        samplerCache: SamplerCache = .shared
    ) throws {
        try dispatchBatch(
            descriptor: descriptor,
            draws: [
                DrawCall(
                    vertexBuffer: vertexBuffer,
                    vertexBufferOffset: vertexBufferOffset,
                    vertexCount: vertexCount,
                    primitiveType: primitiveType,
                    vertexUniforms: vertexUniforms,
                    fragmentUniforms: fragmentUniforms,
                    fragmentTextures: fragmentTextures,
                    samplers: samplers
                )
            ],
            destination: destination,
            loadAction: loadAction,
            clearColor: clearColor,
            commandBuffer: commandBuffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache
        )
    }

    // MARK: - Batched-draw API

    /// Encode multiple draw calls sharing one render encoder.
    ///
    /// All draws write to the same destination with the same PSO descriptor.
    /// Use this for sticker batches, multi-instance effects, or any scenario
    /// where the setup cost of creating a new encoder would dominate.
    ///
    /// Each `DrawCall` can have its own vertex buffer, uniforms, and
    /// textures. The encoder re-binds between draws; no state leaks.
    public static func dispatchBatch(
        descriptor: RenderPSODescriptor,
        draws: [DrawCall],
        destination: MTLTexture,
        loadAction: MTLLoadAction = .clear,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
        commandBuffer: MTLCommandBuffer,
        psoCache: PipelineStateCache = .shared,
        uniformPool: UniformBufferPool = .shared,
        samplerCache: SamplerCache = .shared
    ) throws {
        // 1. Validate destination
        guard destination.usage.contains(.renderTarget) else {
            throw PipelineError.texture(.formatMismatch(
                expected: "destination with .renderTarget usage",
                got: "usage=\(destination.usage.rawValue)"
            ))
        }

        // The render pass descriptor's color format must match the
        // destination texture's pixel format.
        guard destination.pixelFormat == descriptor.colorPixelFormat else {
            throw PipelineError.texture(.formatMismatch(
                expected: "\(descriptor.colorPixelFormat)",
                got: "\(destination.pixelFormat)"
            ))
        }

        // 2. Resolve PSO (cached)
        let pso = try psoCache.renderPipelineState(for: descriptor)

        // 3. Build render pass descriptor
        let renderPass = MTLRenderPassDescriptor()
        guard let colorAttachment = renderPass.colorAttachments[0] else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .render))
        }
        colorAttachment.texture = destination
        colorAttachment.loadAction = loadAction
        colorAttachment.storeAction = .store
        colorAttachment.clearColor = clearColor

        // 4. Create render encoder
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .render))
        }
        encoder.label = "DCR.Render.\(descriptor.vertexFunction)+\(descriptor.fragmentFunction)"
        encoder.setRenderPipelineState(pso)

        // 5. Encode each draw call
        for draw in draws {
            try encodeDraw(
                draw,
                encoder: encoder,
                uniformPool: uniformPool,
                samplerCache: samplerCache,
                commandBuffer: commandBuffer
            )
        }

        // 6. Finalize
        encoder.endEncoding()
    }

    // MARK: - Private

    private static func encodeDraw(
        _ draw: DrawCall,
        encoder: MTLRenderCommandEncoder,
        uniformPool: UniformBufferPool,
        samplerCache: SamplerCache,
        commandBuffer: MTLCommandBuffer
    ) throws {
        // Vertex stage
        encoder.setVertexBuffer(
            draw.vertexBuffer,
            offset: draw.vertexBufferOffset,
            index: 0
        )
        try bindVertexUniforms(
            draw.vertexUniforms,
            encoder: encoder,
            pool: uniformPool,
            commandBuffer: commandBuffer
        )

        // Fragment stage — textures
        for (index, texture) in draw.fragmentTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }

        // Fragment stage — samplers
        for (index, config) in draw.samplers.enumerated() {
            let sampler = try samplerCache.sampler(for: config)
            encoder.setFragmentSamplerState(sampler, index: index)
        }

        // Fragment stage — uniforms
        try bindFragmentUniforms(
            draw.fragmentUniforms,
            encoder: encoder,
            pool: uniformPool,
            commandBuffer: commandBuffer
        )

        // Draw
        encoder.drawPrimitives(
            type: draw.primitiveType,
            vertexStart: 0,
            vertexCount: draw.vertexCount
        )
    }

    // MARK: - Private uniform binding helpers

    /// Bind vertex-stage uniforms. Uses `setVertexBytes` for small
    /// payloads (≤ 4 KB, the common case) and the command-buffer-fenced
    /// `UniformBufferPool` for larger ones.
    private static func bindVertexUniforms(
        _ uniforms: FilterUniforms,
        encoder: MTLRenderCommandEncoder,
        pool: UniformBufferPool,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard uniforms.byteCount > 0 else { return }
        if uniforms.byteCount <= 4096 {
            var scratch = [UInt8](repeating: 0, count: uniforms.byteCount)
            scratch.withUnsafeMutableBytes { raw in
                uniforms.copyBytes(raw.baseAddress!)
            }
            scratch.withUnsafeBytes { raw in
                encoder.setVertexBytes(
                    raw.baseAddress!,
                    length: uniforms.byteCount,
                    index: 1
                )
            }
        } else if let binding = try pool.nextBuffer(
            for: uniforms,
            commandBuffer: commandBuffer
        ) {
            encoder.setVertexBuffer(binding.buffer, offset: binding.offset, index: 1)
        }
    }

    /// Bind fragment-stage uniforms with the same small/large split.
    private static func bindFragmentUniforms(
        _ uniforms: FilterUniforms,
        encoder: MTLRenderCommandEncoder,
        pool: UniformBufferPool,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard uniforms.byteCount > 0 else { return }
        if uniforms.byteCount <= 4096 {
            var scratch = [UInt8](repeating: 0, count: uniforms.byteCount)
            scratch.withUnsafeMutableBytes { raw in
                uniforms.copyBytes(raw.baseAddress!)
            }
            scratch.withUnsafeBytes { raw in
                encoder.setFragmentBytes(
                    raw.baseAddress!,
                    length: uniforms.byteCount,
                    index: 0
                )
            }
        } else if let binding = try pool.nextBuffer(
            for: uniforms,
            commandBuffer: commandBuffer
        ) {
            encoder.setFragmentBuffer(binding.buffer, offset: binding.offset, index: 0)
        }
    }
}

// MARK: - DrawCall

/// A single draw invocation within a batched render pass.
///
/// Marked `@unchecked Sendable` because `MTLBuffer` and `MTLTexture` are not
/// formally `Sendable` but are safe to hand between threads when the producer
/// has committed all writes (which is the standard Metal resource lifecycle —
/// resources are created on the CPU, handed to the GPU via encoders, and
/// retrieved after completion). Callers should not mutate a `DrawCall` after
/// enqueuing it.
public struct DrawCall: @unchecked Sendable {

    /// Vertex data buffer (bound at `buffer(0)` in the vertex shader).
    public let vertexBuffer: MTLBuffer

    /// Byte offset into `vertexBuffer`. Useful for sub-allocating a shared
    /// buffer across draws.
    public let vertexBufferOffset: Int

    /// Number of vertices to draw.
    public let vertexCount: Int

    /// Primitive topology.
    public let primitiveType: MTLPrimitiveType

    /// Vertex stage uniforms (bound at `buffer(1)` in the vertex shader).
    public let vertexUniforms: FilterUniforms

    /// Fragment stage uniforms (bound at `buffer(0)` in the fragment shader).
    public let fragmentUniforms: FilterUniforms

    /// Textures bound to the fragment stage at `texture(0)`, `texture(1)`, ...
    public let fragmentTextures: [MTLTexture]

    /// Sampler configs bound to the fragment stage at `sampler(0)`, ...
    /// Samplers are resolved through `SamplerCache` so identical configs
    /// share a single `MTLSamplerState`.
    public let samplers: [SamplerConfig]

    public init(
        vertexBuffer: MTLBuffer,
        vertexBufferOffset: Int = 0,
        vertexCount: Int,
        primitiveType: MTLPrimitiveType = .triangleStrip,
        vertexUniforms: FilterUniforms = .empty,
        fragmentUniforms: FilterUniforms = .empty,
        fragmentTextures: [MTLTexture] = [],
        samplers: [SamplerConfig] = [.linearClamp]
    ) {
        self.vertexBuffer = vertexBuffer
        self.vertexBufferOffset = vertexBufferOffset
        self.vertexCount = vertexCount
        self.primitiveType = primitiveType
        self.vertexUniforms = vertexUniforms
        self.fragmentUniforms = fragmentUniforms
        self.fragmentTextures = fragmentTextures
        self.samplers = samplers
    }
}
