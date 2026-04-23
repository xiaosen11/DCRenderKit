//
//  FilterProtocol.swift
//  DCRenderKit
//
//  The root protocol that every filter conforms to. Intentionally value-type
//  friendly: prefer `struct` unless managed state requires `class`.
//

import Metal

/// The root contract for all image filters in DCRenderKit.
///
/// ## Minimal implementation
///
/// A single-pass compute filter only needs to declare its modifier and optional
/// parameters:
///
/// ```swift
/// public struct ExposureFilter: FilterProtocol {
///     public var exposure: Float = 0
///
///     public var modifier: ModifierEnum {
///         .compute(kernel: "ExposureFilterKernel")
///     }
///
///     public var uniforms: FilterUniforms {
///         .init(exposure: exposure)
///     }
///
///     public static var fuseGroup: FuseGroup? { .toneAdjustment }
/// }
/// ```
///
/// ## Design philosophy
///
/// DCRenderKit uses a single typed `FilterUniforms` struct that maps to
/// a single `buffer(0)` in the shader, rather than a loose
/// `factors: [Float]` array with per-value buffer-index binding. The
/// single-struct approach eliminates per-frame `setBytes` overhead and
/// provides compile-time type safety against uniform-layout drift.
public protocol FilterProtocol: Sendable {

    /// Routes execution to the appropriate backend dispatcher.
    var modifier: ModifierEnum { get }

    /// Typed parameter struct. The dispatcher binds this as a single Metal
    /// buffer at index 0. Return `.empty` for parameterless filters.
    var uniforms: FilterUniforms { get }

    /// Additional input textures beyond the primary source.
    ///
    /// Examples: blend overlay texture, luma mask, LUT 3D texture.
    /// The dispatcher binds these starting at texture index 2 (index 0 = dest,
    /// index 1 = source).
    var additionalInputs: [MTLTexture] { get }

    /// Identifies whether this filter can be fused with adjacent filters of
    /// the same group by `FilterGraphOptimizer`. Return `nil` to disable fusion.
    static var fuseGroup: FuseGroup? { get }

    /// Called before the filter's main dispatch. Default implementation is
    /// a no-op. Override for filters that need setup work (e.g. mask caching).
    func combinationBegin(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture
    ) throws -> MTLTexture

    /// Called after the filter's main dispatch completes. Default implementation
    /// is a no-op. Override to release intermediate resources.
    func combinationAfter(commandBuffer: MTLCommandBuffer) throws
}

// MARK: - Default implementations

extension FilterProtocol {

    public var uniforms: FilterUniforms { .empty }

    public var additionalInputs: [MTLTexture] { [] }

    public static var fuseGroup: FuseGroup? { nil }

    public func combinationBegin(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture
    ) throws -> MTLTexture {
        return source
    }

    public func combinationAfter(commandBuffer: MTLCommandBuffer) throws {
        // No-op by default.
    }
}

// MARK: - FilterUniforms

/// Type-erased wrapper around a filter's parameter struct.
///
/// The pipeline binds this as `buffer(0)` in the shader. Filters provide their
/// parameters as a single POD (plain-old-data) struct that is memcpy-safe.
///
/// ## Usage
///
/// Define a typed struct matching your shader's uniform layout:
///
/// ```swift
/// // Matches `constant ExposureUniforms& u [[buffer(0)]]` in the shader.
/// struct ExposureUniforms {
///     var exposure: Float
///     var gainFloor: Float
///     var rolloff: Float
/// }
///
/// extension ExposureFilter {
///     var uniforms: FilterUniforms {
///         .init(ExposureUniforms(
///             exposure: exposure,
///             gainFloor: 0.1,
///             rolloff: 2.0
///         ))
///     }
/// }
/// ```
///
/// The `FilterUniforms` wrapper captures the byte size and provides access to
/// a contiguous memory region for Metal buffer binding.
public struct FilterUniforms: Sendable {

    /// Byte size of the underlying struct. Zero means no uniforms.
    public let byteCount: Int

    /// Copies the underlying bytes into the provided buffer.
    ///
    /// Called by the dispatcher to populate a `MTLBuffer`. The `buffer` is
    /// guaranteed to be at least `byteCount` bytes.
    public let copyBytes: @Sendable (UnsafeMutableRawPointer) -> Void

    /// Creates a typed uniforms wrapper from any POD struct.
    ///
    /// - Parameter value: A POD struct (no reference types, no ARC).
    ///   The struct's memory layout must match the shader's declaration
    ///   including alignment. Use `MemoryLayout<T>.stride` to reason about
    ///   layout.
    public init<T>(_ value: T) {
        self.byteCount = MemoryLayout<T>.stride
        // Capture value by copy; closure is @Sendable safe for POD types.
        let boxed = UnsafeUniformBox(value)
        self.copyBytes = { dest in
            boxed.copyTo(dest)
        }
    }

    /// Empty uniforms (no parameters to bind).
    public static let empty = FilterUniforms(byteCount: 0, copyBytes: { _ in })

    private init(byteCount: Int, copyBytes: @escaping @Sendable (UnsafeMutableRawPointer) -> Void) {
        self.byteCount = byteCount
        self.copyBytes = copyBytes
    }
}

/// Internal box that captures a POD value and provides Sendable-safe copy.
///
/// `@unchecked Sendable` is justified here because we only accept POD types
/// (documented contract in `FilterUniforms.init`). The stored bytes cannot
/// reference mutable state.
private struct UnsafeUniformBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
    func copyTo(_ dest: UnsafeMutableRawPointer) {
        withUnsafePointer(to: value) { src in
            dest.copyMemory(from: src, byteCount: MemoryLayout<T>.stride)
        }
    }
}
