//
//  PipelineInput.swift
//  DCRenderKit
//
//  Unified input type accepted by `Pipeline`. Wraps the four supported
//  source types so callers don't need to pre-convert to `MTLTexture`.
//

import Foundation
import Metal
import CoreVideo

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Any of the four input types `Pipeline` can consume.
///
/// Each case corresponds to a path in `TextureLoader`. The pipeline calls
/// the loader once at the start of processing to obtain a concrete
/// `MTLTexture` and does not re-resolve between filters.
///
/// ## Usage
///
/// ```swift
/// // From a UIImage:
/// let p = Pipeline(input: .uiImage(myImage), steps: [...])
///
/// // From a Core Video pixel buffer (camera frame):
/// let p = Pipeline(input: .pixelBuffer(buffer), steps: [...])
/// ```
public enum PipelineInput: @unchecked Sendable {

    /// A Metal texture ready for use. Zero-cost path.
    case texture(MTLTexture)

    /// A Core Graphics image. Decoded via `MTKTextureLoader`.
    case cgImage(CGImage)

    /// A Core Video pixel buffer (BGRA). Zero-copy via
    /// `CVMetalTextureCache`.
    case pixelBuffer(CVPixelBuffer)

    #if canImport(UIKit)
    /// A UIImage (iOS). Extracts the backing CGImage.
    case uiImage(UIImage)
    #elseif canImport(AppKit)
    /// An NSImage (macOS). Extracts the backing CGImage.
    case nsImage(NSImage)
    #endif
}

extension PipelineInput {

    /// Resolve this input into an `MTLTexture` using the given loader.
    ///
    /// - Throws: Any `PipelineError.texture` variant from the underlying
    ///   loader call.
    public func resolve(using loader: TextureLoader) throws -> MTLTexture {
        switch self {
        case .texture(let texture):
            return loader.makeTexture(from: texture)
        case .cgImage(let image):
            return try loader.makeTexture(from: image)
        case .pixelBuffer(let buffer):
            return try loader.makeTexture(from: buffer)
        #if canImport(UIKit)
        case .uiImage(let image):
            return try loader.makeTexture(from: image)
        #elseif canImport(AppKit)
        case .nsImage(let image):
            return try loader.makeTexture(from: image)
        #endif
        }
    }
}
