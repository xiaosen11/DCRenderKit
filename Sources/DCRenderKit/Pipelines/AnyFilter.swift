//
//  AnyFilter.swift
//  DCRenderKit
//
//  Type-erased wrapper allowing single-pass and multi-pass filters to
//  coexist in the same filter chain.
//

import Foundation

/// A type-erased filter step that can be either a single-pass
/// `FilterProtocol` or a multi-pass `MultiPassFilter`. Used by `Pipeline`
/// to accept heterogeneous filter chains.
///
/// ## Example
///
/// ```swift
/// let pipeline = Pipeline(input: .uiImage(img), steps: [
///     .single(ExposureFilter(exposure: 20)),
///     .single(ContrastFilter(contrast: 15)),
///     .multi(SoftGlowFilter(strength: 30)),   // multi-pass filter
///     .single(LUT3DFilter(preset: .jade)),
/// ])
/// ```
///
/// ## Why an enum and not a unified protocol?
///
/// `FilterProtocol` (single-pass) and `MultiPassFilter` (DAG of passes)
/// have fundamentally different execution models — single-pass filters
/// dispatch to a single compute/render kernel while multi-pass filters
/// declare `passes(input:)` and hand off to `MultiPassExecutor`. Trying
/// to unify them under one protocol would either leak DAG concepts into
/// single-pass filters or restrict multi-pass filters to the single-pass
/// execution contract. An `enum` keeps each contract clean and lets the
/// `Pipeline` dispatch on case pattern matching.
public enum AnyFilter: @unchecked Sendable {

    /// A single-pass filter (one compute kernel dispatch).
    case single(any FilterProtocol)

    /// A multi-pass filter (DAG of compute passes executed by
    /// `MultiPassExecutor`).
    case multi(any MultiPassFilter)
}
