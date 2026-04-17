//
//  ModifierEnum.swift
//  DCRenderKit
//
//  Backend dispatch discriminator used by `FilterProtocol.modifier`.
//

import Foundation

/// Identifies which backend should execute a filter.
///
/// The pipeline dispatcher examines this value to route execution to the
/// appropriate dispatcher (`ComputeDispatcher`, `RenderDispatcher`, etc).
///
/// Unlike Harbeth, DCRenderKit supports only four backends that we actively
/// need. Core Image is intentionally excluded to avoid GPU-CPU synchronization
/// overhead and Apple-specific dependencies.
public enum ModifierEnum: Sendable {

    /// Metal compute kernel. Primary backend for per-pixel, neighborhood, and
    /// reduction operations. Full cross-platform portability (GLSL, WGSL).
    ///
    /// - Parameter kernel: Name of the compute kernel function to dispatch.
    case compute(kernel: String)

    /// Metal render pipeline (vertex + fragment). Used for geometric operations
    /// such as sticker rendering, lens distortion, and fisheye projection.
    ///
    /// - Parameters:
    ///   - vertex: Name of the vertex shader function.
    ///   - fragment: Name of the fragment shader function.
    case render(vertex: String, fragment: String)

    /// Metal blit encoder. Used for texture-to-texture copies, format
    /// conversions, crops, and mipmap generation.
    case blit

    /// Metal Performance Shaders (Apple-only). Used as an optional hardware
    /// acceleration layer with a compute-backend fallback for cross-platform.
    ///
    /// - Parameter kernelName: Symbolic name of the MPS kernel for logging.
    case mps(kernelName: String)
}

extension ModifierEnum: CustomStringConvertible {
    public var description: String {
        switch self {
        case .compute(let k): return "compute(\(k))"
        case .render(let v, let f): return "render(\(v),\(f))"
        case .blit: return "blit"
        case .mps(let n): return "mps(\(n))"
        }
    }
}
