//
//  PipelineError.swift
//  DCRenderKit
//
//  Unified error hierarchy for the rendering pipeline. All errors are grouped
//  by domain to allow callers to handle specific categories without enumerating
//  every possible failure case.
//

import Foundation

// MARK: - Top-level error

/// The unified error type for all DCRenderKit operations.
///
/// Errors are grouped into five domains so callers can `switch` on the top
/// level and handle broad categories without enumerating every leaf case.
///
/// ```swift
/// do {
///     let result = try await pipeline.output()
/// } catch PipelineError.device(let deviceError) {
///     // Handle device/Metal initialization failures
/// } catch PipelineError.texture(let textureError) {
///     // Handle texture loading / format issues
/// } catch {
///     // Handle other categories
/// }
/// ```
public enum PipelineError: Error, Sendable {

    /// Metal device, command queue, or command buffer related errors.
    case device(DeviceError)

    /// Texture creation, loading, format conversion, or dimension errors.
    case texture(TextureError)

    /// Pipeline state object (compute/render PSO) creation or lookup errors.
    case pipelineState(PipelineStateError)

    /// Filter configuration, execution, or parameter validation errors.
    case filter(FilterError)

    /// Resource management (texture pool, buffer pool, sampler cache) errors.
    case resource(ResourceError)
}

// MARK: - Device domain

/// Errors originating from Metal device initialization or command encoding.
public enum DeviceError: Error, Sendable {

    /// No Metal-capable device is available on this system.
    case noMetalDevice

    /// Failed to create a command queue.
    case commandQueueCreationFailed

    /// Failed to create a command buffer from the queue.
    case commandBufferCreationFailed

    /// Failed to create a command encoder of the requested kind.
    case commandEncoderCreationFailed(kind: EncoderKind)

    /// GPU execution failed with an error reported by Metal.
    case gpuExecutionFailed(underlying: Error)

    /// Command encoder kind for diagnostic context.
    public enum EncoderKind: String, Sendable {
        case compute
        case render
        case blit
    }
}

// MARK: - Texture domain

/// Errors related to texture creation, loading, and format handling.
public enum TextureError: Error, Sendable {

    /// Failed to load a texture from the given source.
    case loadFailed(source: String, underlying: Error?)

    /// Texture format does not match what the caller expected.
    case formatMismatch(expected: String, got: String)

    /// Texture dimensions are invalid (zero, negative, or exceed device limits).
    case dimensionsInvalid(width: Int, height: Int, reason: String)

    /// Failed to decode source image data (JPEG/HEIF/PNG).
    case imageDecodeFailed(format: String)

    /// Failed to create an `MTLTexture` from the supplied input.
    case textureCreationFailed(reason: String)

    /// Failed to copy `CVPixelBuffer` to `MTLTexture` via the texture cache.
    case pixelBufferConversionFailed(cvReturn: Int32)

    /// Requested pixel format is not supported on the current device.
    case pixelFormatUnsupported(format: String)
}

// MARK: - Pipeline state domain

/// Errors related to `MTLComputePipelineState` or `MTLRenderPipelineState` creation.
public enum PipelineStateError: Error, Sendable {

    /// Compute kernel compilation failed.
    case computeCompileFailed(kernel: String, underlying: Error)

    /// Render pipeline (vertex + fragment) compilation failed.
    case renderCompileFailed(vertex: String, fragment: String, underlying: Error)

    /// Named Metal function not found in any registered library.
    case functionNotFound(name: String)

    /// Metal library load failed.
    case libraryLoadFailed(reason: String)
}

// MARK: - Filter domain

/// Errors reported by individual filters during configuration or execution.
public enum FilterError: Error, Sendable {

    /// A required parameter is out of range.
    case parameterOutOfRange(name: String, value: Double, range: ClosedRange<Double>)

    /// A required input (texture, mask, sampler) was not provided.
    case missingRequiredInput(name: String)

    /// A filter's `passes(input:)` returned an empty array but the filter was non-identity.
    case emptyPassGraph(filterName: String)

    /// A filter's declared pass graph has a cycle or invalid dependency.
    case invalidPassGraph(filterName: String, reason: String)

    /// A filter encountered an unrecoverable runtime error.
    case runtimeFailure(filterName: String, underlying: Error)

    /// Fused filter construction failed (used by `FilterGraphOptimizer`).
    case fusionFailed(group: String, reason: String)
}

// MARK: - Resource domain

/// Errors related to pool management (texture pool, buffer pool, sampler cache).
public enum ResourceError: Error, Sendable {

    /// Texture pool allocation failed (memory pressure or device limit).
    case texturePoolExhausted(requestedBytes: Int)

    /// Uniform buffer allocation failed.
    case uniformBufferAllocationFailed(requestedBytes: Int)

    /// Command buffer pool exhausted (too many in-flight operations).
    case commandBufferPoolExhausted(maxSize: Int)

    /// Sampler state cache failed to build the requested descriptor.
    case samplerCreationFailed(reason: String)
}

// MARK: - LocalizedError conformance

extension PipelineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .device(let err): return "Device error: \(err)"
        case .texture(let err): return "Texture error: \(err)"
        case .pipelineState(let err): return "Pipeline state error: \(err)"
        case .filter(let err): return "Filter error: \(err)"
        case .resource(let err): return "Resource error: \(err)"
        }
    }
}

extension DeviceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal-capable device found"
        case .commandQueueCreationFailed:
            return "Failed to create MTLCommandQueue"
        case .commandBufferCreationFailed:
            return "Failed to create MTLCommandBuffer"
        case .commandEncoderCreationFailed(let kind):
            return "Failed to create \(kind.rawValue) command encoder"
        case .gpuExecutionFailed(let underlying):
            return "GPU execution failed: \(underlying.localizedDescription)"
        }
    }
}

extension TextureError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .loadFailed(let source, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            return "Failed to load texture from \(source)\(detail)"
        case .formatMismatch(let expected, let got):
            return "Texture format mismatch — expected \(expected), got \(got)"
        case .dimensionsInvalid(let w, let h, let reason):
            return "Invalid texture dimensions \(w)×\(h): \(reason)"
        case .imageDecodeFailed(let format):
            return "Failed to decode \(format) image data"
        case .textureCreationFailed(let reason):
            return "Failed to create MTLTexture: \(reason)"
        case .pixelBufferConversionFailed(let cvReturn):
            return "CVPixelBuffer → MTLTexture conversion failed (CVReturn: \(cvReturn))"
        case .pixelFormatUnsupported(let format):
            return "Pixel format \(format) is not supported on this device"
        }
    }
}

extension PipelineStateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .computeCompileFailed(let kernel, let underlying):
            return "Compute kernel '\(kernel)' compilation failed: \(underlying.localizedDescription)"
        case .renderCompileFailed(let vertex, let fragment, let underlying):
            return "Render pipeline '\(vertex)'+'\(fragment)' compilation failed: \(underlying.localizedDescription)"
        case .functionNotFound(let name):
            return "Metal function '\(name)' not found in any registered library"
        case .libraryLoadFailed(let reason):
            return "Metal library load failed: \(reason)"
        }
    }
}

extension FilterError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .parameterOutOfRange(let name, let value, let range):
            return "Parameter '\(name)' value \(value) is out of range \(range)"
        case .missingRequiredInput(let name):
            return "Missing required input: \(name)"
        case .emptyPassGraph(let name):
            return "Filter '\(name)' declared an empty pass graph but is not identity"
        case .invalidPassGraph(let name, let reason):
            return "Filter '\(name)' has invalid pass graph: \(reason)"
        case .runtimeFailure(let name, let underlying):
            return "Filter '\(name)' runtime failure: \(underlying.localizedDescription)"
        case .fusionFailed(let group, let reason):
            return "Filter fusion failed for group '\(group)': \(reason)"
        }
    }
}

extension ResourceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .texturePoolExhausted(let bytes):
            return "Texture pool exhausted (requested \(bytes) bytes)"
        case .uniformBufferAllocationFailed(let bytes):
            return "Uniform buffer allocation failed (\(bytes) bytes)"
        case .commandBufferPoolExhausted(let max):
            return "Command buffer pool exhausted (max \(max) in-flight)"
        case .samplerCreationFailed(let reason):
            return "Sampler state creation failed: \(reason)"
        }
    }
}
