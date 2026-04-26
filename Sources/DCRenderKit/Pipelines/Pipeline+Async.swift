//
//  Pipeline+Async.swift
//  DCRenderKit
//
//  Swift Concurrency (async/await) extension for Pipeline. Bridges
//  Metal's completion-handler API into an `async throws` function so
//  business code can use structured concurrency.
//

import Foundation
import Metal

extension Pipeline {

    /// Execute `steps` against `input` and await GPU completion.
    ///
    /// The work is encoded synchronously (Metal encoding itself is cheap
    /// and synchronous), then `addCompletedHandler` bridges GPU completion
    /// into the continuation. The calling task is suspended — not
    /// blocked — until the GPU finishes.
    ///
    /// Use this from SwiftUI / async controllers / UIKit async handlers.
    /// Sync callers should use ``processSync(input:steps:)`` instead.
    public func process(
        input: PipelineInput,
        steps: [AnyFilter]
    ) async throws -> MTLTexture {
        // Encode synchronously on the current thread — Metal encoding is
        // thread-safe and fast; only the wait is asynchronous.
        let (commandBuffer, finalTexture) = try encodeAll(input: input, steps: steps)

        // Box the texture so we can capture it Sendable-safely.
        let textureBox = TextureBox(finalTexture)

        return try await withCheckedThrowingContinuation { continuation in
            // `addCompletedHandler` is invoked on an unspecified queue after
            // the GPU finishes. Exactly-once guarantees are provided by
            // Metal; `withCheckedThrowingContinuation` enforces exactly-once
            // resume on our side too.
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: PipelineError.device(
                        .gpuExecutionFailed(underlying: error)
                    ))
                } else {
                    continuation.resume(returning: textureBox.texture)
                }
            }
            commandBuffer.commit()
        }
    }
}

// MARK: - Sendable box

/// Holds an `MTLTexture` reference in a way the compiler can prove is
/// `Sendable` without requiring `MTLTexture` itself to be `Sendable`.
/// The texture has completed all writes by the time it's read (after
/// `waitUntilCompleted` / `addCompletedHandler`), so the cross-actor hand-
/// off is safe.
private struct TextureBox: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) {
        self.texture = texture
    }
}
