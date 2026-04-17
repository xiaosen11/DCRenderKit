//
//  Logger.swift
//  DCRenderKit
//
//  Structured logging with protocol-based injection. Defaults to Apple's
//  unified logging system (`os.Logger`) but consumers can plug in their own
//  logger (e.g. for routing to Sentry, Datadog, or an internal platform).
//

import Foundation
import os

// MARK: - Log level

/// Severity levels for structured logging.
///
/// These map 1:1 to `os.Logger` / `os_log`'s log types.
public enum DCRLogLevel: String, Sendable, Comparable, CaseIterable {

    /// Verbose diagnostic messages. Typically stripped in Release builds by
    /// the underlying `os.Logger`.
    case debug

    /// Normal operational messages ("pipeline built with 3 filters").
    case info

    /// Recoverable issues that warrant attention ("falling back to CPU path").
    case warning

    /// Errors that affect functionality but don't crash.
    case error

    /// Serious failures that typically indicate a bug. Persisted by os.Logger.
    case fault

    private var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .fault: return 4
        }
    }

    public static func < (lhs: DCRLogLevel, rhs: DCRLogLevel) -> Bool {
        lhs.order < rhs.order
    }
}

// MARK: - Logger protocol

/// The injection point for routing DCRenderKit log output.
///
/// All DCRenderKit code logs through `DCRLogging.logger`. Consumers can
/// replace the default with any conforming implementation to route logs to
/// their own infrastructure.
///
/// ## Example
///
/// ```swift
/// struct MyLogger: DCRLogger {
///     func log(level: DCRLogLevel, category: String, message: String,
///              attributes: [String: String], error: Error?,
///              file: String, line: Int) {
///         myAnalytics.track(event: message, metadata: attributes)
///     }
/// }
/// DCRLogging.logger = MyLogger()
/// ```
public protocol DCRLogger: Sendable {

    /// Record a log event.
    ///
    /// - Parameters:
    ///   - level: Severity classification.
    ///   - category: Logical subsystem the event belongs to (e.g. "Pipeline",
    ///     "TexturePool", "RenderDispatcher"). Used by filter UIs in tools
    ///     like Console.app.
    ///   - message: Human-readable description. Should be static-ish rather
    ///     than interpolating PII or large data.
    ///   - attributes: Structured key-value metadata for filtering/searching.
    ///     Values must be `String`; convert numerics at the call site.
    ///   - error: Optional error object associated with the event.
    ///   - file: Source file (filled in by `#file`).
    ///   - line: Source line (filled in by `#line`).
    func log(
        level: DCRLogLevel,
        category: String,
        message: String,
        attributes: [String: String],
        error: Error?,
        file: String,
        line: Int
    )
}

// MARK: - Convenience helpers

extension DCRLogger {

    public func debug(
        _ message: String,
        category: String = "Default",
        attributes: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line
    ) {
        log(level: .debug, category: category, message: message,
            attributes: attributes, error: nil, file: file, line: line)
    }

    public func info(
        _ message: String,
        category: String = "Default",
        attributes: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line
    ) {
        log(level: .info, category: category, message: message,
            attributes: attributes, error: nil, file: file, line: line)
    }

    public func warning(
        _ message: String,
        category: String = "Default",
        attributes: [String: String] = [:],
        error: Error? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(level: .warning, category: category, message: message,
            attributes: attributes, error: error, file: file, line: line)
    }

    public func error(
        _ message: String,
        category: String = "Default",
        attributes: [String: String] = [:],
        error: Error? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(level: .error, category: category, message: message,
            attributes: attributes, error: error, file: file, line: line)
    }

    public func fault(
        _ message: String,
        category: String = "Default",
        attributes: [String: String] = [:],
        error: Error? = nil,
        file: String = #fileID,
        line: Int = #line
    ) {
        log(level: .fault, category: category, message: message,
            attributes: attributes, error: error, file: file, line: line)
    }
}

// MARK: - Default implementation (os.Logger)

/// Default logger implementation backed by Apple's unified logging system.
///
/// Uses `os.Logger` for efficient, privacy-respecting, Console.app-visible
/// logging. Log messages are routed to the `com.dcrenderkit` subsystem.
public struct OSLoggerBackend: DCRLogger {

    private let subsystem: String

    public init(subsystem: String = "com.dcrenderkit") {
        self.subsystem = subsystem
    }

    public func log(
        level: DCRLogLevel,
        category: String,
        message: String,
        attributes: [String: String],
        error: Error?,
        file: String,
        line: Int
    ) {
        let logger = os.Logger(subsystem: subsystem, category: category)
        let attrString = attributes.isEmpty
            ? ""
            : " " + attributes.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let errString = error.map { " error=\($0.localizedDescription)" } ?? ""
        let fullMessage = "\(message)\(attrString)\(errString) [\(file):\(line)]"

        switch level {
        case .debug:
            logger.debug("\(fullMessage, privacy: .public)")
        case .info:
            logger.info("\(fullMessage, privacy: .public)")
        case .warning:
            logger.warning("\(fullMessage, privacy: .public)")
        case .error:
            logger.error("\(fullMessage, privacy: .public)")
        case .fault:
            logger.fault("\(fullMessage, privacy: .public)")
        }
    }
}

// MARK: - Global logger accessor

/// The globally configured logger instance used by all DCRenderKit components.
///
/// Thread-safe: reading returns the current logger; writing atomically
/// replaces it. Consumers typically set this once at app startup.
public enum DCRLogging {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _logger: DCRLogger = OSLoggerBackend()

    /// The current logger. Replace to route DCRenderKit logs to your own system.
    public static var logger: DCRLogger {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _logger
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _logger = newValue
        }
    }
}
