//
//  MultiPassFilter.swift
//  DCRenderKit
//
//  Declarative multi-pass filter API. Replaces Harbeth's imperative
//  `C7CombinationBase.prepareIntermediateTextures` pattern with a DAG
//  specification that the framework executes and optimizes automatically.
//
//  See `docs/harbeth-architecture-audit.md` §13.4 for design details.
//

import Metal

/// A filter composed of multiple GPU passes.
///
/// Declare the pass graph via `passes(input:)`; the framework handles:
/// - Intermediate texture allocation (pool-backed)
/// - Topological execution ordering
/// - Texture lifetime analysis and early release
/// - Debug visualization
///
/// ## Example — SoftGlow (dual Kawase bloom)
///
/// ```swift
/// struct SoftGlowFilter: MultiPassFilter {
///     var strength: Float
///     var threshold: Float
///     var bloomRadius: Float
///
///     static var fuseGroup: FuseGroup? { nil }
///
///     func passes(input: TextureInfo) -> [Pass] {
///         guard strength > 0.001 else { return [] }
///
///         // Adaptive pyramid depth targeting ~135px shortest side.
///         let shortSide = min(input.width, input.height)
///         let levels = max(3, Int(log2(Float(shortSide) / 135.0)))
///
///         var passes: [Pass] = []
///
///         passes.append(.compute(
///             name: "L1",
///             kernel: "bloom_bright_downsample",
///             inputs: [.source],
///             output: .scaled(factor: 0.5),
///             uniforms: .init(BrightUniforms(threshold: threshold))
///         ))
///
///         // ... more passes
///
///         return passes
///     }
/// }
/// ```
///
/// ## Return value semantics
///
/// - Non-empty array: framework executes passes in dependency order; the
///   output of the final pass becomes this filter's output.
/// - Empty array: filter is a no-op; the input texture is passed through
///   unchanged (useful for conditional filters with strength==0).
public protocol MultiPassFilter: Sendable {

    /// Declare the pass graph for the given input dimensions.
    ///
    /// - Parameter input: Dimensions and format of the source texture.
    /// - Returns: Ordered list of passes to execute. Empty means identity.
    func passes(input: TextureInfo) -> [Pass]

    /// External input textures the pass graph can reference via
    /// ``PassInput/additional(_:)``. Order matters: the index inside
    /// `PassInput.additional(i)` is looked up in this array.
    ///
    /// Used for filters that consume caller-supplied auxiliary textures
    /// (e.g. ``PortraitBlurFilter``'s subject mask). Default is empty —
    /// pipeline-internal multi-pass filters (SoftGlow, HighlightShadow,
    /// Clarity) don't need external textures.
    var additionalInputs: [MTLTexture] { get }

    /// Identifies whether this filter can be fused. Multi-pass filters are
    /// rarely fusable; default is `nil`.
    static var fuseGroup: FuseGroup? { get }
}

extension MultiPassFilter {
    public var additionalInputs: [MTLTexture] { [] }
    public static var fuseGroup: FuseGroup? { nil }
}

// MARK: - TextureInfo

/// Immutable descriptor of a texture's dimensions and format.
/// Passed to `passes(input:)` so the filter can size intermediate textures
/// proportionally.
public struct TextureInfo: Sendable, Hashable {

    public let width: Int
    public let height: Int
    public let pixelFormat: MTLPixelFormat

    public init(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    public init(texture: MTLTexture) {
        self.width = texture.width
        self.height = texture.height
        self.pixelFormat = texture.pixelFormat
    }

    /// Shorter of the two spatial dimensions. Commonly used as a reference
    /// length for radius-proportional parameters.
    public var shortSide: Int { min(width, height) }

    /// Longer of the two spatial dimensions.
    public var longSide: Int { max(width, height) }
}

// MARK: - Pass

/// A single GPU pass within a multi-pass filter.
///
/// The framework inspects `inputs` to build the DAG, allocates `output`
/// according to the given `TextureSpec`, and dispatches the kernel.
public struct Pass: Sendable {

    /// Unique name within this filter's pass graph. Referenced by other
    /// passes via `PassInput.named(_:)`.
    public let name: String

    /// Which backend to dispatch.
    public let modifier: ModifierEnum

    /// Input textures this pass reads from. Order matters: the first input
    /// becomes `texture(1)` in the shader (index 0 is reserved for output),
    /// the second becomes `texture(2)`, etc.
    public let inputs: [PassInput]

    /// Specification for the output texture. The framework allocates this
    /// from the texture pool.
    public let output: TextureSpec

    /// Optional typed uniform buffer bound at `buffer(0)`.
    public let uniforms: FilterUniforms

    /// Whether this pass's output is the filter's final output. Exactly one
    /// pass in a graph must have `isFinal = true`; typically the last one.
    public let isFinal: Bool

    private init(
        name: String,
        modifier: ModifierEnum,
        inputs: [PassInput],
        output: TextureSpec,
        uniforms: FilterUniforms,
        isFinal: Bool
    ) {
        self.name = name
        self.modifier = modifier
        self.inputs = inputs
        self.output = output
        self.uniforms = uniforms
        self.isFinal = isFinal
    }

    // MARK: - Factory helpers

    /// Create a compute pass.
    ///
    /// Multi-pass DAG executors only support compute passes. The render
    /// backend is reserved for single-pass filters (stickers, distortion)
    /// where the vertex/fragment pair plus vertex buffer forms its own
    /// complete pipeline, not a stage in a DAG.
    public static func compute(
        name: String,
        kernel: String,
        inputs: [PassInput],
        output: TextureSpec,
        uniforms: FilterUniforms = .empty,
        isFinal: Bool = false
    ) -> Pass {
        Pass(
            name: name,
            modifier: .compute(kernel: kernel),
            inputs: inputs,
            output: output,
            uniforms: uniforms,
            isFinal: isFinal
        )
    }

    /// Convenience for declaring the final pass of a graph (isFinal=true).
    /// The final pass's output becomes the filter's output.
    public static func final(
        name: String = "final",
        kernel: String,
        inputs: [PassInput],
        output: TextureSpec = .sameAsSource,
        uniforms: FilterUniforms = .empty
    ) -> Pass {
        Pass(
            name: name,
            modifier: .compute(kernel: kernel),
            inputs: inputs,
            output: output,
            uniforms: uniforms,
            isFinal: true
        )
    }
}

// MARK: - PassInput

/// Reference to a texture consumed by a `Pass`. Either the original
/// source, the output of a previously named pass, or one of the
/// filter's caller-supplied auxiliary textures.
public enum PassInput: Sendable, Hashable {

    /// The source texture supplied to the filter (the chain input).
    case source

    /// The named output of an earlier pass within this filter's graph.
    case named(String)

    /// Index into the filter's ``MultiPassFilter/additionalInputs``
    /// array. Used for caller-supplied auxiliary textures such as
    /// subject masks, LUTs, or blend overlays that the pass graph
    /// consumes repeatedly across multiple passes.
    case additional(Int)
}

// MARK: - TextureSpec

/// Specification for an intermediate or output texture's dimensions.
///
/// The framework resolves this against the filter's input `TextureInfo` to
/// determine actual allocation size. The texture pool then provides a matching
/// texture or allocates a new one.
public enum TextureSpec: Sendable, Hashable {

    /// Same dimensions as the filter's source input.
    case sameAsSource

    /// Scaled by a factor of the source (e.g. 0.5 = half width/height).
    case scaled(factor: Float)

    /// Explicit width and height.
    case explicit(width: Int, height: Int)

    /// Scale so the shortest side equals the given length, preserving
    /// aspect ratio. Useful for pyramid base layers with a resolution-
    /// independent target.
    case matchShortSide(Int)

    /// Same dimensions as another named pass's output.
    case matching(passName: String)

    /// Resolves this spec to concrete dimensions given the source input size
    /// and any already-resolved peer passes.
    public func resolve(
        source: TextureInfo,
        resolvedPeers: [String: TextureInfo]
    ) -> TextureInfo? {
        switch self {
        case .sameAsSource:
            return source

        case .scaled(let factor):
            guard factor > 0 else { return nil }
            let w = max(1, Int((Float(source.width) * factor).rounded()))
            let h = max(1, Int((Float(source.height) * factor).rounded()))
            return TextureInfo(width: w, height: h, pixelFormat: source.pixelFormat)

        case .explicit(let w, let h):
            guard w > 0, h > 0 else { return nil }
            return TextureInfo(width: w, height: h, pixelFormat: source.pixelFormat)

        case .matchShortSide(let target):
            guard target > 0, source.width > 0, source.height > 0 else { return nil }
            let scale = Float(target) / Float(source.shortSide)
            let w = max(1, Int((Float(source.width) * scale).rounded()))
            let h = max(1, Int((Float(source.height) * scale).rounded()))
            return TextureInfo(width: w, height: h, pixelFormat: source.pixelFormat)

        case .matching(let name):
            return resolvedPeers[name]
        }
    }
}
