//
//  FusionBodyDescriptor.swift
//  DCRenderKit
//
//  Opt-in metadata by which a `FilterProtocol` conformer tells the
//  pipeline compiler "I expose a Metal body function that can be
//  concatenated into an uber kernel with neighbouring filters".
//
//  Introduced in the Phase 1 wave of the pipeline-compiler refactor
//  (see `docs/pipeline-compiler-design.md`). At this phase the
//  descriptor is declared on `FilterProtocol` with a default
//  `.unsupported` sentinel, so no existing filter is forced to adopt
//  it. The SDK's 16 built-in filters will adopt concrete descriptors in
//  later Phase 1 / Phase 3 steps as their shader bodies are
//  refactored to the body-function-only form (design doc §4).
//

import Foundation

/// Metadata describing a filter's participation in compiler-driven
/// fusion.
///
/// A filter either:
///
/// - **Provides a body function** (call the primary initialiser) — the
///   compiler extracts the named inline function from the filter's
///   `.metal` source and splices it into a runtime-generated uber
///   kernel alongside other filters in the same fusion cluster.
/// - **Opts out** (use ``unsupported``) — the compiler will either find
///   a consumer-registered custom Metal kernel via
///   ``ShaderLibrary/register(_:)`` or raise a clear error at
///   execution time. Opting out is the default for filters that
///   predate the compiler; they continue to work if they ship their
///   own standalone kernel.
///
/// See `docs/pipeline-compiler-design.md` §4 for the body-function
/// convention and §9 for the public-API rationale.
@available(iOS 18.0, *)
public struct FusionBodyDescriptor: Sendable {

    /// Internal payload. `nil` ⇒ this descriptor is the
    /// ``unsupported`` sentinel and the filter does not expose a body
    /// function.
    internal let body: FusionBody?

    /// Create a descriptor for a filter that exposes a Metal body
    /// function with the given metadata. Used by SDK-built-in filters
    /// and by third-party filters that adopt the compiler's fusion
    /// convention.
    ///
    /// - Parameters:
    ///   - functionName: The Metal function symbol to splice. Must
    ///     match a `// @dcr:body-begin <name>` marker in the
    ///     referenced `.metal` file.
    ///   - uniformStructName: Name of the Metal `struct` the body
    ///     function expects as its `constant` argument. The struct
    ///     must be declared in the same `.metal` file.
    ///   - kind: Whether the body reads only its own pixel or a
    ///     neighbourhood.
    ///   - wantsLinearInput: `true` if the body operates on linear
    ///     scene-light values, `false` if it operates on
    ///     gamma-encoded values. Drives the compiler's decision to
    ///     wrap the body with sRGB (de)linearisation when the
    ///     pipeline's color space differs.
    ///   - sourceMetalFile: URL of the `.metal` file carrying the
    ///     body function. Typically
    ///     `Bundle.module.url(forResource: "MyFilter", withExtension: "metal")`.
    public init(
        functionName: String,
        uniformStructName: String,
        kind: FusionNodeKind,
        wantsLinearInput: Bool,
        sourceMetalFile: URL,
        signatureShape: FusionBodySignatureShape = .pixelLocalOnly
    ) {
        self.body = FusionBody(
            functionName: functionName,
            uniformStructName: uniformStructName,
            kind: kind,
            wantsLinearInput: wantsLinearInput,
            sourceMetalFile: sourceMetalFile,
            signatureShape: signatureShape
        )
    }

    /// Sentinel for filters that do not participate in compiler-driven
    /// fusion. Such filters must ship a standalone Metal kernel
    /// matching ``FilterProtocol/modifier`` and register its library
    /// via ``ShaderLibrary/register(_:)`` if it is not in the SDK's
    /// default library. The pipeline raises a clear error at execution
    /// time if neither a body nor a registered kernel is available.
    public static let unsupported = FusionBodyDescriptor(body: nil)

    /// Private initialiser for the ``unsupported`` sentinel.
    private init(body: FusionBody?) {
        self.body = body
    }

    // MARK: - Internal helpers for SDK-built-in filters

    /// Resolves the `.metal` source URL for an SDK-built-in filter
    /// inside `Bundle.module`. This is the standard `sourceMetalFile`
    /// used by every built-in filter's `fusionBody`.
    ///
    /// The SDK's `Package.swift` ships every `.metal` file under
    /// `Shaders/` as a bundled resource (`.process("Shaders")`), so a
    /// missing URL here is an internal bundling error, not a runtime
    /// failure the consumer can recover from. The method logs a fault
    /// and returns a placeholder URL in Release, and traps in Debug
    /// via ``Invariant/unreachable(_:fallback:category:file:line:)``.
    /// Third-party filter authors should use their own
    /// `Bundle(for:)` / `Bundle.module` lookup and must not rely on
    /// this helper.
    ///
    /// - Parameter baseName: The `.metal` file name without its
    ///   extension, e.g. `"ExposureFilter"`.
    internal static func bundledSDKMetalURL(_ baseName: String) -> URL {
        guard let url = Bundle.module.url(
            forResource: baseName,
            withExtension: "metal"
        ) else {
            return Invariant.unreachable(
                "Bundle.module missing \(baseName).metal — SDK resource bundling broken",
                fallback: URL(fileURLWithPath: "/dev/null/\(baseName).metal")
            )
        }
        return url
    }
}

/// Internal value type carrying the actual body-function metadata.
/// Kept out of the public surface so the compiler's implementation can
/// evolve without breaking API.
@available(iOS 18.0, *)
internal struct FusionBody: Sendable, Hashable {
    let functionName: String
    let uniformStructName: String
    let kind: FusionNodeKind
    let wantsLinearInput: Bool
    let sourceMetalFile: URL
    let signatureShape: FusionBodySignatureShape
}

// MARK: - FusionNodeKind

/// How a body function depends on surrounding pixels. Drives the
/// compiler's choice between vertical fusion (safe for `.pixelLocal`)
/// and head-inlining / independent dispatch (required for
/// `.neighborRead`).
@available(iOS 18.0, *)
public enum FusionNodeKind: Sendable, Hashable {

    /// The body reads only the pixel at the thread's own grid
    /// position. Eligible for vertical fusion with any adjacent
    /// `.pixelLocal` body.
    case pixelLocal

    /// The body samples a small neighbourhood around the thread's grid
    /// position. Not vertically-fusable with other bodies but can
    /// absorb a preceding `.pixelLocal` body via the optimiser's
    /// kernel-inlining pass.
    ///
    /// - Parameter radius: Largest axis-aligned sample offset (in
    ///   pixels) the body uses. The compiler uses this to reason about
    ///   tile boundaries when targeting the TBDR backend.
    case neighborRead(radius: Int)
}

// MARK: - FusionBodySignatureShape

/// Declares the Metal signature a `FusionBodyDescriptor` body
/// function is expected to have. Codegen reads this to generate
/// the correct call-site — which parameters to pass, which texture
/// slots to bind, whether `uint2 gid` is needed, etc.
///
/// Every body ultimately returns `half3` (the modified pixel) and
/// takes `(half3 rgbIn, constant <StructName>& u, …)` in some form;
/// the shape enumerates which extra parameters come after those two
/// leading args. Seven of the SDK's twelve built-in filters (the
/// pure tone / colour operators) use `.pixelLocalOnly`; the other
/// five carry extras.
///
/// The five built-in variants cover every SDK-shipped filter. Third-
/// party filters that don't match any of these shapes opt out of
/// fusion via `FusionBodyDescriptor.unsupported` and ship their own
/// standalone kernel (see `ShaderLibrary.register(_:)`).
@available(iOS 18.0, *)
public enum FusionBodySignatureShape: Sendable, Hashable {

    /// `inline half3 body(half3 rgbIn, constant X& u)`
    ///
    /// The canonical pure pixel-local shape: the body reads only
    /// its own pixel and the filter's uniform struct. Used by
    /// Exposure / Contrast / Blacks / Whites / Saturation /
    /// Vibrance / WhiteBalance.
    case pixelLocalOnly

    /// `inline half3 body(half3 rgbIn, constant X& u, uint2 gid)`
    ///
    /// Body uses the thread's grid position for deterministic
    /// per-pixel effects (typically hash-based noise) without
    /// sampling the source texture. Reserved for future filters
    /// that need gid but no source-neighborhood reads.
    case pixelLocalWithGid

    /// `inline half3 body(half3 rgbIn, constant X& u,
    ///                    texture3d<float, access::read> lut)`
    ///
    /// Body samples a 3D lookup texture indexed by the input
    /// colour (LUT3D). Does not use `gid` — every pixel indexes
    /// the LUT by its own `rgbIn`.
    case pixelLocalWithLUT3D

    /// `inline half3 body(half3 rgbIn, constant X& u, uint2 gid,
    ///                    texture2d<half, access::read> overlay,
    ///                    uint2 outputSize)`
    ///
    /// Body composites a 2D overlay texture onto the primary
    /// input. `outputSize` is needed because the overlay-to-output
    /// coordinate mapping depends on both dimensions (see
    /// `NormalBlendFilter.metal`). Used by NormalBlend.
    case pixelLocalWithOverlay

    /// `inline half3 body(half3 rgbIn, constant X& u, uint2 gid,
    ///                    texture2d<half, access::read> src)`
    ///
    /// Body reads a neighbourhood of `src` around `gid`. Used by
    /// Sharpen (Laplacian 5-tap), CCD (CA offset + grain block +
    /// sharp), and FilmGrain (block-centre luma read). The kernel
    /// binds `src` to the same slot as the primary source texture
    /// so the body can sample arbitrary offsets.
    case neighborReadWithSource
}
