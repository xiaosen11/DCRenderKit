//
//  ComputeBackend.swift
//  DCRenderKit
//
//  Phase-3 runtime executor for uber kernels. Wires together
//  `MetalSourceBuilder`, `UberKernelCache`, and the existing
//  uniform / texture binding conventions to dispatch a single
//  `PipelineGraph.Node` through its generated uber kernel.
//
//  Callable from tests today; Phase 5 wires it into `Pipeline`
//  execution path so production code paths go through here.
//

import Foundation
import Metal

/// Dispatch wrapper around the Phase-3 codegen path. Given a
/// `Node`, it:
///
///   1. asks `MetalSourceBuilder` to produce uber-kernel source;
///   2. gets or compiles the PSO via `UberKernelCache`;
///   3. creates a compute encoder, binds textures and uniforms,
///      dispatches threads, and ends encoding.
///
/// Does not own the command buffer — the caller commits / waits
/// on it. Intended lifecycle: `Pipeline.executeStep(...)` calls
/// `ComputeBackend.execute(...)` for Nodes whose kind the backend
/// supports; falls back to the legacy `ComputeDispatcher` for
/// others.
@available(iOS 18.0, *)
internal enum ComputeBackend {

    // MARK: - Entry point

    /// Execute `node` on the given command buffer, reading from
    /// `source` and writing to `destination`.
    ///
    /// - Parameters:
    ///   - node: Lowered / optimised pipeline graph node. Supported
    ///     shapes today: `.pixelLocalOnly`, `.pixelLocalWithLUT3D`,
    ///     `.pixelLocalWithOverlay`, `.neighborReadWithSource`, and
    ///     `.fusedPixelLocalCluster` with `.pixelLocalOnly` members.
    ///   - source: Primary input texture; bound at texture slot 1.
    ///   - destination: Output texture; must have `.shaderWrite`;
    ///     bound at texture slot 0.
    ///   - additionalInputs: Auxiliary textures the node's body
    ///     references via `NodeRef.additional(i)`. Each
    ///     `.additional(i)` entry in `Node.additionalNodeInputs`
    ///     binds `additionalInputs[i]` at texture slot `2 + k`,
    ///     where `k` is the aux entry's position in the Node's
    ///     additional list. Ignored for shapes that don't read
    ///     auxiliaries (`.pixelLocalOnly`, `.neighborReadWithSource`).
    ///   - commandBuffer: Command buffer to encode into. Caller
    ///     commits / waits.
    ///   - uberCache: Library + PSO cache. Defaults to the shared
    ///     instance so repeated dispatches amortise compilation.
    ///   - uniformPool: Pool for large uniform payloads (> 4 KB).
    ///     Defaults to shared. DCR's built-in filter uniforms are
    ///     all < 64 B so this path is cold in practice.
    /// - Throws: `MetalSourceBuilder.BuildError` on codegen failure,
    ///   `PipelineError.pipelineState(...)` on compile failure,
    ///   `PipelineError.device(.commandEncoderCreationFailed)` if
    ///   the encoder cannot be created,
    ///   `PipelineError.texture(.formatMismatch)` if the
    ///   destination lacks write usage.
    static func execute(
        node: Node,
        source: MTLTexture,
        destination: MTLTexture,
        additionalInputs: [MTLTexture] = [],
        commandBuffer: MTLCommandBuffer,
        uberCache: UberKernelCache = .shared,
        uniformPool: UniformBufferPool = .shared
    ) throws {
        try validateDestination(destination)

        let built = try MetalSourceBuilder.build(for: node)
        let pso = try uberCache.pipelineState(
            source: built.source,
            functionName: built.functionName
        )

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .compute))
        }
        encoder.label = "DCR.Fusion.\(built.functionName)"
        encoder.setComputePipelineState(pso)

        // Texture slots 0, 1 are output and source; aux textures
        // start at slot 2.
        encoder.setTexture(destination, index: 0)
        encoder.setTexture(source, index: 1)
        try bindAuxiliaryTextures(
            node: node,
            additionalInputs: additionalInputs,
            encoder: encoder
        )

        // Bind uniforms — one buffer slot per cluster member, or a
        // single slot for a standalone pixelLocal / neighborRead node.
        try bindUniforms(
            node: node,
            encoder: encoder,
            commandBuffer: commandBuffer,
            uniformPool: uniformPool
        )

        let threadgroup = threadgroupSize(for: pso)
        let grid = MTLSize(
            width: destination.width,
            height: destination.height,
            depth: 1
        )
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threadgroup)

        encoder.endEncoding()
    }

    /// Bind any `NodeRef.additional(i)` references in the node to
    /// concrete textures from `additionalInputs`. The first such
    /// aux ref lands at texture slot 2, the next at slot 3, and
    /// so on. `NodeRef.source` / `.node(_)` entries are ignored
    /// here — they're bound upstream (source) or resolved by the
    /// Pipeline executor (inter-node node refs — not a concern for
    /// the single-node execution path yet).
    private static func bindAuxiliaryTextures(
        node: Node,
        additionalInputs: [MTLTexture],
        encoder: MTLComputeCommandEncoder
    ) throws {
        let auxRefs: [NodeRef]
        switch node.kind {
        case let .pixelLocal(_, _, _, aux):             auxRefs = aux
        case let .neighborRead(_, _, _, aux):           auxRefs = aux
        case let .fusedPixelLocalCluster(_, _, aux):    auxRefs = aux
        default:                                        auxRefs = []
        }

        var slot = 2
        for ref in auxRefs {
            switch ref {
            case .additional(let index):
                guard index >= 0, index < additionalInputs.count else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: String(describing: node.kind),
                        reason: ".additional(\(index)) out of range of additionalInputs (count \(additionalInputs.count))"
                    ))
                }
                encoder.setTexture(additionalInputs[index], index: slot)
                slot += 1
            case .source:
                encoder.setTexture(nil, index: slot)   // will be set by primary binding
                slot += 1
            case .node:
                // Single-node execution path: inter-node node refs
                // aren't resolved here (the Pipeline executor
                // will thread intermediate outputs as inputs in
                // follow-up steps). Leave the slot empty so the
                // uber kernel fails cleanly if it ever reads a
                // non-supplied slot.
                slot += 1
            }
        }
    }

    // MARK: - Uniform binding

    /// Thread uniform payloads into `buffer(0..N-1)` slots
    /// according to the node's kind:
    ///
    ///   · `.pixelLocal`: one uniform buffer at `buffer(0)`.
    ///   · `.fusedPixelLocalCluster`: `members[i].uniforms` at
    ///     `buffer(i)` for every member, so each body call in the
    ///     generated kernel gets its own slider payload.
    ///
    /// Payloads ≤ 4 KB go through `setBytes` (Metal's transient
    /// storage). Larger payloads reserve a pool buffer. Every
    /// built-in filter's uniform struct is a handful of floats so
    /// the `setBytes` path is the one production actually uses.
    private static func bindUniforms(
        node: Node,
        encoder: MTLComputeCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        uniformPool: UniformBufferPool
    ) throws {
        switch node.kind {
        case let .pixelLocal(_, uniforms, _, _):
            try bindOneUniform(
                uniforms,
                at: 0,
                encoder: encoder,
                commandBuffer: commandBuffer,
                uniformPool: uniformPool
            )

        case let .neighborRead(_, uniforms, _, _):
            try bindOneUniform(
                uniforms,
                at: 0,
                encoder: encoder,
                commandBuffer: commandBuffer,
                uniformPool: uniformPool
            )

        case let .fusedPixelLocalCluster(members, _, _):
            for (index, member) in members.enumerated() {
                try bindOneUniform(
                    member.uniforms,
                    at: index,
                    encoder: encoder,
                    commandBuffer: commandBuffer,
                    uniformPool: uniformPool
                )
            }

        default:
            // MetalSourceBuilder.build(_:) should have rejected
            // this node already; surface the invariant violation
            // here for defence in depth.
            Invariant.check(
                false,
                "ComputeBackend reached an unsupported node kind past source builder"
            )
        }
    }

    private static func bindOneUniform(
        _ uniforms: FilterUniforms,
        at index: Int,
        encoder: MTLComputeCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        uniformPool: UniformBufferPool
    ) throws {
        guard uniforms.byteCount > 0 else { return }
        if uniforms.byteCount <= 4096 {
            var scratch = [UInt8](repeating: 0, count: uniforms.byteCount)
            scratch.withUnsafeMutableBytes { raw in
                uniforms.copyBytes(raw.baseAddress!)
            }
            scratch.withUnsafeBytes { raw in
                encoder.setBytes(
                    raw.baseAddress!,
                    length: uniforms.byteCount,
                    index: index
                )
            }
        } else if let binding = try uniformPool.nextBuffer(
            for: uniforms,
            commandBuffer: commandBuffer
        ) {
            encoder.setBuffer(binding.buffer, offset: binding.offset, index: index)
        }
    }

    // MARK: - Private helpers

    private static func validateDestination(_ texture: MTLTexture) throws {
        guard texture.usage.contains(.shaderWrite) else {
            throw PipelineError.texture(.formatMismatch(
                expected: "destination with .shaderWrite usage",
                got: "usage=\(texture.usage.rawValue)"
            ))
        }
    }

    /// Choose a threadgroup size in the same `width = threadExecution
    /// Width`, `height = 8` shape `ComputeDispatcher` uses. Keeps
    /// occupancy predictable across Apple GPU generations.
    private static func threadgroupSize(
        for pso: MTLComputePipelineState
    ) -> MTLSize {
        let w = pso.threadExecutionWidth
        let maxTotal = pso.maxTotalThreadsPerThreadgroup
        let target = 8
        let h = min(target, maxTotal / max(w, 1))
        return MTLSize(width: w, height: max(h, 1), depth: 1)
    }
}
