//
//  NodeSignature.swift
//  DCRenderKit
//
//  Hashable summary of a `Node`'s computation-relevant fields. Two
//  nodes with the same signature produce the same output given the
//  same inputs, so the CSE pass can fold duplicates. `isFinal`,
//  `debugLabel`, and `id` are **not** part of the signature —
//  folding collapses computation, not identity.
//
//  Computing a signature materialises the node's uniform bytes into
//  a `[UInt8]` via `FilterUniforms.copyBytes`. This is the only
//  place outside codegen that peeks at uniform payloads; the cost
//  is bounded by the filter's struct size (≤ 64 bytes across the
//  SDK's built-in filters).
//

import Foundation

/// Computation fingerprint used by CSE. Equality implies the two
/// source nodes compute the same output pixel-for-pixel (to
/// Float16 margin). Inequality is safe — CSE may miss a
/// deduplication opportunity but never fold two non-equivalent
/// nodes.
@available(iOS 18.0, *)
internal struct NodeSignature: Hashable {
    let discriminator: String
    let primaryName: String
    let uniformBytes: [UInt8]
    let wantsLinear: Bool
    let radius: Int
    let inputs: [NodeRef]
    let additional: [NodeRef]
    let outputSpec: TextureSpec
    let auxiliary: String
}

@available(iOS 18.0, *)
extension Node {

    /// Build the signature for this node. Returns `nil` for
    /// kinds that CSE intentionally does not fold — currently just
    /// `.fusedPixelLocalCluster`, because clusters are already a
    /// fusion product and re-folding them would require element-
    /// wise member equality that CSE doesn't model.
    internal var signature: NodeSignature? {
        switch kind {
        case .pixelLocal(let body, let uniforms, let linear, let aux):
            return NodeSignature(
                discriminator: "pixelLocal",
                primaryName: body.functionName,
                uniformBytes: uniformBytesOf(uniforms),
                wantsLinear: linear,
                radius: 0,
                inputs: inputs,
                additional: aux,
                outputSpec: outputSpec,
                auxiliary: ""
            )

        case .neighborRead(let body, let uniforms, let radius, let aux):
            return NodeSignature(
                discriminator: "neighborRead",
                primaryName: body.functionName,
                uniformBytes: uniformBytesOf(uniforms),
                wantsLinear: false,
                radius: radius,
                inputs: inputs,
                additional: aux,
                outputSpec: outputSpec,
                auxiliary: ""
            )

        case .nativeCompute(let kernelName, let uniforms, let aux):
            return NodeSignature(
                discriminator: "nativeCompute",
                primaryName: kernelName,
                uniformBytes: uniformBytesOf(uniforms),
                wantsLinear: false,
                radius: 0,
                inputs: inputs,
                additional: aux,
                outputSpec: outputSpec,
                auxiliary: ""
            )

        case .downsample(let factor, let kind):
            return NodeSignature(
                discriminator: "downsample",
                primaryName: "\(factor)",
                uniformBytes: [],
                wantsLinear: false,
                radius: 0,
                inputs: inputs,
                additional: [],
                outputSpec: outputSpec,
                auxiliary: String(describing: kind)
            )

        case .upsample(let factor, let kind):
            return NodeSignature(
                discriminator: "upsample",
                primaryName: "\(factor)",
                uniformBytes: [],
                wantsLinear: false,
                radius: 0,
                inputs: inputs,
                additional: [],
                outputSpec: outputSpec,
                auxiliary: String(describing: kind)
            )

        case .reduce(let op):
            return NodeSignature(
                discriminator: "reduce",
                primaryName: String(describing: op),
                uniformBytes: [],
                wantsLinear: false,
                radius: 0,
                inputs: inputs,
                additional: [],
                outputSpec: outputSpec,
                auxiliary: ""
            )

        case .blend(let op, let aux):
            return NodeSignature(
                discriminator: "blend",
                primaryName: String(describing: op),
                uniformBytes: [],
                wantsLinear: false,
                radius: 0,
                inputs: inputs,
                additional: [aux],
                outputSpec: outputSpec,
                auxiliary: ""
            )

        case .fusedPixelLocalCluster:
            return nil
        }
    }
}

/// Materialise a `FilterUniforms` payload into a `[UInt8]` for
/// byte-level equality. Safe on zero-byte payloads.
@available(iOS 18.0, *)
private func uniformBytesOf(_ uniforms: FilterUniforms) -> [UInt8] {
    guard uniforms.byteCount > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: uniforms.byteCount)
    buf.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress {
            uniforms.copyBytes(base)
        }
    }
    return buf
}
