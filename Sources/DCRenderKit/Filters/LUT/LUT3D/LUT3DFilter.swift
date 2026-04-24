//
//  LUT3DFilter.swift
//  DCRenderKit
//
//  3D LUT colour transform using a genuine `texture3d` Metal texture and
//  software trilinear sampling (chosen over hardware `filter::linear` to
//  sidestep normalized-coord float truncation on small LUTs). Accepts
//  standard `.cube` files produced by pro tools (DaVinci Resolve,
//  Lightroom, FilmLight Baselight) without intermediate conversion.
//

import Foundation
import Metal

/// 3D look-up table colour transform.
///
/// ## Model form justification
///
/// - Type: 3D colour transform (per-pixel colour lookup with 3D
///   interpolation)
/// - Algorithm: **software** trilinear interpolation over a 3D Metal
///   texture, plus per-pixel triangular dither before 8-bit quantization.
///   - Why software trilinear: on small LUTs (17³ or 25³) the hardware
///     `filter::linear` sampler's normalized-coord rounding introduces
///     visible step artefacts at the LUT corners. Software trilinear
///     with explicit integer indexing is bit-exact with the reference.
///   - Why dither: eliminates banding when the LUT output is written into
///     an 8-bit downstream buffer. Triangular-distributed noise (sum of
///     two uniform randoms) is the smallest dither amplitude that fully
///     decorrelates quantization noise from the signal.
///   - Reference: Reshetov et al., "High-Quality LUT-based Color
///     Correction" — dither + software interpolation is standard for
///     pro tools (Lightroom, DaVinci Resolve, FilmLight Baselight).
///
/// ## Spatial parameter
///
/// None. Colour transforms have no spatial extent.
///
/// ## Failure modes
///
/// - `.cube` parse failure → `PipelineError.filter(.missingRequiredInput)`
/// - 3D texture allocation failure → `PipelineError.texture(.textureCreationFailed)`
///
/// Identity at `intensity = 0` is exact (shader `mix(src, lut, 0) = src`).
///
/// ## Sendable note
///
/// The filter stores an `MTLTexture` (the 3D LUT), which is not itself
/// `Sendable`. We justify `@unchecked Sendable` because the texture is
/// allocated once at init, never mutated afterwards, and used only for
/// `shaderRead` — Metal textures with read-only usage are safe to share
/// across threads once the producer has finished writing to them.
@available(iOS 18.0, *)
public struct LUT3DFilter: FilterProtocol, @unchecked Sendable {

    /// Blend between source colour (`0`) and fully-LUT colour (`1`).
    public var intensity: Float

    /// Color space the pipeline is operating in. `.cube` files are defined
    /// in gamma (display) space — in `.linear` mode the shader un-linearizes
    /// the input before indexing the cube and re-linearizes the output
    /// before the intensity mix, so the cube's intended mapping is
    /// preserved regardless of pipeline color space.
    public var colorSpace: DCRColorSpace

    private let lutTexture: MTLTexture

    // MARK: - Init

    /// Create a LUT3D filter from a `.cube` file URL.
    public init(
        cubeURL: URL,
        intensity: Float = 1.0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace,
        device: Device = .shared
    ) throws {
        guard let parsed = CubeFileParser.parse(url: cubeURL) else {
            throw PipelineError.filter(
                .missingRequiredInput(name: "LUT3DFilter.cubeURL=\(cubeURL.lastPathComponent)")
            )
        }
        try self.init(
            cubeData: parsed.data,
            dimension: parsed.dimension,
            intensity: intensity,
            colorSpace: colorSpace,
            device: device
        )
    }

    /// Create a LUT3D filter from already-parsed cube data.
    ///
    /// `cubeData` must be a tightly-packed RGBA32Float buffer of exactly
    /// `dimension^3 * 16` bytes (the layout produced by `CubeFileParser`).
    public init(
        cubeData: Data,
        dimension: Int,
        intensity: Float = 1.0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace,
        device: Device = .shared
    ) throws {
        self.intensity = intensity
        self.colorSpace = colorSpace
        self.lutTexture = try Self.make3DTexture(
            data: cubeData,
            dimension: dimension,
            device: device
        )
    }

    // MARK: - FilterProtocol

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRLUT3DFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(LUT3DUniforms(
            intensity: intensity,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// 3D LUT texture bound to `texture(2)` in the compute kernel.
    /// See ``FilterProtocol/additionalInputs``.
    public var additionalInputs: [MTLTexture] {
        [lutTexture]
    }

    /// Declared fuse group (`nil` — LUT3D is a 3D lookup that cannot
    /// be fused with 1D per-pixel tone operators).
    /// See ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { nil }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRLUT3DBody` lands in `LUT3DFilter.metal` in Phase 3.
    ///
    /// Classified as `.pixelLocal` because the trilinear sample reads
    /// the LUT 3D texture only — the 8 LUT texel reads are not
    /// neighbourhood reads on the primary source and don't affect
    /// tile-boundary analysis for the TBDR backend.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRLUT3DBody",
            uniformStructName: "LUT3DUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceMetalFile: FusionBodyDescriptor.bundledSDKMetalURL("LUT3DFilter")
        )
    }

    // MARK: - Private

    private static func make3DTexture(
        data: Data,
        dimension: Int,
        device: Device
    ) throws -> MTLTexture {
        let expectedBytes = dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            throw PipelineError.texture(.textureCreationFailed(
                reason: "LUT data byte count \(data.count) does not match dimension^3 * 16 = \(expectedBytes)"
            ))
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = dimension
        descriptor.height = dimension
        descriptor.depth = dimension
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.metalDevice.makeTexture(descriptor: descriptor) else {
            throw PipelineError.texture(.textureCreationFailed(
                reason: "MTLDevice could not allocate \(dimension)^3 rgba32Float 3D texture"
            ))
        }

        let bytesPerPixel = 4 * MemoryLayout<Float>.size
        let bytesPerRow = dimension * bytesPerPixel
        let bytesPerImage = bytesPerRow * dimension

        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, dimension, dimension, dimension),
                mipmapLevel: 0,
                slice: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return texture
    }
}

/// Memory layout matches `constant LUT3DUniforms& u [[buffer(0)]]`.
struct LUT3DUniforms {
    /// `0 ... 1` blend between source and LUT-transformed colour.
    var intensity: Float
    /// 1 = linear input; 0 = gamma-encoded.
    var isLinearSpace: UInt32
}
