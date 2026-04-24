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
        sourceMetalFile: URL
    ) {
        self.body = FusionBody(
            functionName: functionName,
            uniformStructName: uniformStructName,
            kind: kind,
            wantsLinearInput: wantsLinearInput,
            sourceMetalFile: sourceMetalFile
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
