//
//  FuseGroup.swift
//  DCRenderKit
//
//  Discriminator used by `FilterGraphOptimizer` to identify filters that can
//  be merged into a single uber-kernel.
//

import Foundation

/// A group of filters that can be mathematically fused into a single compute
/// kernel by `FilterGraphOptimizer`.
///
/// Filters declaring the same `fuseGroup` and appearing consecutively in the
/// pipeline are candidates for fusion. Non-fusable filters declare `nil`.
///
/// ## Example
///
/// ```swift
/// struct ExposureFilter: FilterProtocol {
///     static var fuseGroup: FuseGroup? { .toneAdjustment }
/// }
/// ```
///
/// When the pipeline is built, `[ExposureFilter, ContrastFilter, WhitesFilter,
/// BlacksFilter]` can be fused into a single `ToneFilter` uber-kernel,
/// eliminating 3 intermediate 8-bit quantization steps.
///
/// See `docs/harbeth-architecture-audit.md` §13.2 for design details.
@available(iOS 18.0, *)
public enum FuseGroup: String, Hashable, Sendable, CaseIterable {

    /// Tone curve adjustments (exposure, contrast, whites, blacks).
    /// All per-pixel luminance operations in linear space.
    case toneAdjustment

    /// Color grading (white balance, vibrance, saturation).
    /// All per-pixel color operations in RGB/YIQ space.
    case colorGrading

    // Additional groups can be added as new fuse templates are implemented.
    // Reserved for future: `.sharpening`, `.noise`, `.lutChain`
}
