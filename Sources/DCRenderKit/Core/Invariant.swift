//
//  Invariant.swift
//  DCRenderKit
//
//  Assertion-style helpers for defensive programming. Distinguishes between
//  input validation (runtime errors that must propagate) and internal
//  invariants (programmer errors that assert in Debug and log in Release).
//

import Foundation

/// Defensive programming helpers.
///
/// Three kinds of checks:
///
/// - `require` — validates external inputs (caller error). Throws a typed
///   `PipelineError` which the caller is expected to handle.
/// - `check` — validates internal invariants (programmer error). Asserts in
///   Debug; logs at `.fault` level in Release but does not crash.
/// - `unreachable` — marks code paths that should never execute. Asserts in
///   Debug; returns a caller-provided fallback in Release.
///
/// ## Example
///
/// ```swift
/// public func apply(radius: Float, input: MTLTexture?) throws {
///     try Invariant.require(radius, in: 0...100, parameter: "radius")
///     let source = try Invariant.requireNonNil(input, "input")
///
///     // Internal invariant: the texture pool should always provide a
///     // texture matching the requested spec.
///     let dest = pool.dequeue(width: source.width, height: source.height)
///     Invariant.check(dest != nil, "TexturePool returned nil for valid request")
///
///     // ...
/// }
/// ```
public enum Invariant {

    // MARK: - require: input validation

    /// Throws `FilterError.parameterOutOfRange` if `value` is outside `range`.
    public static func require(
        _ value: Float,
        in range: ClosedRange<Float>,
        parameter: String
    ) throws {
        guard range.contains(value) else {
            throw PipelineError.filter(.parameterOutOfRange(
                name: parameter,
                value: Double(value),
                range: Double(range.lowerBound)...Double(range.upperBound)
            ))
        }
    }

    /// Throws `FilterError.parameterOutOfRange` if `value` is outside `range`.
    public static func require(
        _ value: Double,
        in range: ClosedRange<Double>,
        parameter: String
    ) throws {
        guard range.contains(value) else {
            throw PipelineError.filter(.parameterOutOfRange(
                name: parameter,
                value: value,
                range: range
            ))
        }
    }

    /// Throws `FilterError.missingRequiredInput` if `value` is `nil`; otherwise
    /// returns the unwrapped value.
    public static func requireNonNil<T>(
        _ value: T?,
        _ name: String
    ) throws -> T {
        guard let unwrapped = value else {
            throw PipelineError.filter(.missingRequiredInput(name: name))
        }
        return unwrapped
    }

    /// Throws `FilterError.runtimeFailure` with a custom error if `condition`
    /// is false.
    public static func require(
        _ condition: @autoclosure () -> Bool,
        filterName: String,
        _ message: @autoclosure () -> String
    ) throws {
        guard condition() else {
            let err = InvariantFailureError(message: message())
            throw PipelineError.filter(.runtimeFailure(filterName: filterName, underlying: err))
        }
    }

    // MARK: - check: internal invariants

    /// Validates an internal invariant. Asserts in Debug; logs at `.fault`
    /// level in Release without crashing.
    ///
    /// Use this for conditions that should always hold by program construction
    /// and whose violation indicates a bug in DCRenderKit itself.
    public static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        category: String = "Invariant",
        file: String = #fileID,
        line: Int = #line
    ) {
        if condition() { return }

        let fullMessage = "Invariant violated: \(message())"
        DCRLogging.logger.fault(
            fullMessage,
            category: category,
            attributes: [:],
            file: file,
            line: line
        )

        #if DEBUG
        assertionFailure(fullMessage)
        #endif
    }

    // MARK: - unreachable: impossible paths

    /// Marks a code path that should be unreachable by construction.
    ///
    /// Asserts in Debug; in Release logs a fault and returns the fallback
    /// value provided by the caller.
    ///
    /// Use this in switch statements over closed enums or as the last line
    /// of a function whose control flow should never reach it.
    public static func unreachable<T>(
        _ message: @autoclosure () -> String,
        fallback: T,
        category: String = "Invariant",
        file: String = #fileID,
        line: Int = #line
    ) -> T {
        let fullMessage = "Unreachable code reached: \(message())"
        DCRLogging.logger.fault(
            fullMessage,
            category: category,
            attributes: [:],
            file: file,
            line: line
        )

        #if DEBUG
        assertionFailure(fullMessage)
        #endif

        return fallback
    }
}

// MARK: - Private error type for check/require(condition:)

struct InvariantFailureError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    var localizedDescription: String { message }
}
