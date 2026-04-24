//
//  NormalBlendFilter.swift
//  DCRenderKit
//
//  "Normal" (source-over) blend between the pipeline input and a
//  consumer-supplied overlay texture, with an intensity mix. Only
//  blend mode currently shipped. Other blend modes (multiply, screen,
//  overlay, etc.) will be added on demand rather than shipping
//  untested stubs.
//

import Foundation
import Metal

/// Source-over blend with an overlay texture.
///
/// ## Algorithm
///
/// Porter-Duff "source over" alpha compositing of `overlay` on top of
/// the pipeline input:
///   `rgb = overlay.rgb + input.rgb · input.a · (1 - overlay.a)`
///   `a   = overlay.a   + input.a               · (1 - overlay.a)`
/// then mix back toward the original by `1 - intensity` for slider-
/// driven partial overlays.
///
/// Bilinear resampling is done inline so the overlay texture can be any
/// resolution — the consumer isn't required to pre-resize.
///
/// ## Alpha convention
///
/// The overlay is treated as **premultiplied alpha** (RGB already
/// scaled by alpha). This matches the output of `CGContext` drawing on
/// a clear background and the default `TextureLoader` import path, so
/// consumers who get their overlay from Core Graphics or a file load
/// won't need to pre-multiply themselves. If you build overlay textures
/// by hand, make sure transparent pixels have RGB = 0 — straight-alpha
/// transparent pixels with nonzero RGB will bleed through visibly.
///
/// ## Usage
///
/// ```swift
/// guard let overlay = try? TextureLoader.shared.load(from: watermarkImage)
/// else { return }
///
/// let blend = NormalBlendFilter(overlay: overlay, intensity: 1.0)
/// let pipeline = Pipeline(input: .texture(source), steps: [.single(blend)])
/// ```
///
/// ## Sendable note
///
/// Stores an `MTLTexture` overlay. Justified `@unchecked Sendable`
/// because the overlay is immutable after init and used only for
/// `shaderRead`; Metal textures with read-only usage are thread-safe
/// once the producer has written to them.
@available(iOS 18.0, *)
public struct NormalBlendFilter: FilterProtocol, @unchecked Sendable {

    /// Mix weight `0 ... 1`. `0` returns the pipeline input unchanged;
    /// `1` applies full source-over compositing.
    public var intensity: Float

    private let overlay: MTLTexture

    /// Create a ``NormalBlendFilter`` with the given overlay texture
    /// and source-over mix intensity.
    public init(overlay: MTLTexture, intensity: Float = 1.0) {
        self.overlay = overlay
        self.intensity = intensity
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRBlendNormalFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(NormalBlendUniforms(intensity: intensity))
    }

    /// Overlay texture bound to `texture(2)` in the compute kernel.
    /// See ``FilterProtocol/additionalInputs``.
    public var additionalInputs: [MTLTexture] {
        [overlay]
    }

    /// Declared fuse group (`nil` — blends are not fusable).
    /// See ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { nil }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRNormalBlendBody` lands in `NormalBlendFilter.metal` in Phase 3.
    ///
    /// Classified as `.pixelLocal`: the shader reads the source at
    /// the thread's own gid and the overlay at the mapped pixel
    /// centre — neither is a neighbourhood read on the primary input,
    /// so no tile-boundary guard is needed.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRNormalBlendBody",
            uniformStructName: "NormalBlendUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceMetalFile: FusionBodyDescriptor.bundledSDKMetalURL("NormalBlendFilter")
        )
    }
}

/// Memory layout matches `constant NormalBlendUniforms& u [[buffer(0)]]`.
struct NormalBlendUniforms {
    /// Mix weight `0 ... 1`. Shader clamps.
    var intensity: Float
}
