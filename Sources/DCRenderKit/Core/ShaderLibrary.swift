//
//  ShaderLibrary.swift
//  DCRenderKit
//
//  Registry for Metal shader libraries. Supports multiple libraries so both
//  SDK built-in shaders and consumer-provided shaders can be resolved through
//  a unified `function(named:)` lookup.
//

import Foundation
import Metal

/// A registry of `MTLLibrary` instances used to resolve shader function names.
///
/// The `Pipeline` dispatchers call `ShaderLibrary.shared.function(named:)` to
/// look up compute and render functions by name. Registration order determines
/// lookup priority: libraries registered later take precedence over earlier
/// ones, allowing consumers to override built-in shaders if needed.
///
/// ## Usage by SDK consumers
///
/// Most consumers don't need to interact with `ShaderLibrary` directly — the
/// SDK's built-in library is registered automatically at first access.
///
/// To add your own shaders:
///
/// ```swift
/// let device = MTLCreateSystemDefaultDevice()!
/// let url = Bundle.main.url(forResource: "MyShaders", withExtension: "metallib")!
/// let library = try device.makeLibrary(URL: url)
/// ShaderLibrary.shared.register(library)
/// ```
///
/// Your shaders can now be referenced by name in `ModifierEnum.compute(kernel:)`
/// or `ModifierEnum.render(vertex:fragment:)`.
public final class ShaderLibrary: @unchecked Sendable {

    /// The shared registry. Thread-safe.
    public static let shared = ShaderLibrary()

    private let lock = NSLock()
    private var libraries: [MTLLibrary] = []
    private var defaultLibraryAttempted = false

    private init() {}

    // MARK: - Registration

    /// Register an `MTLLibrary` for shader function lookup.
    ///
    /// Libraries registered later take precedence when multiple libraries
    /// define the same function name.
    public func register(_ library: MTLLibrary) {
        lock.lock()
        defer { lock.unlock() }
        libraries.append(library)
    }

    /// Remove all registered libraries. Primarily for testing.
    public func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        libraries.removeAll()
        defaultLibraryAttempted = false
    }

    // MARK: - Lookup

    /// Resolve a Metal function by name, searching all registered libraries.
    ///
    /// - Parameter name: The function name as declared in the `.metal` source.
    /// - Returns: The resolved `MTLFunction`.
    /// - Throws: `PipelineError.pipelineState(.functionNotFound)` if no
    ///   registered library contains a function with this name.
    public func function(named name: String) throws -> MTLFunction {
        lock.lock()
        let currentLibraries = libraries
        let attempted = defaultLibraryAttempted
        lock.unlock()

        // Lazily attempt to load the SDK's default library on first lookup.
        if !attempted {
            tryLoadDefaultLibrary()
        }

        // Search most-recently-registered first (override semantics).
        // Re-read libraries in case default library was just added.
        lock.lock()
        let searchOrder = libraries.reversed()
        lock.unlock()

        for library in searchOrder {
            if let function = library.makeFunction(name: name) {
                return function
            }
        }

        // Fallback: try the original list (in case lazy load failed but we
        // want a consistent error).
        _ = currentLibraries

        throw PipelineError.pipelineState(.functionNotFound(name: name))
    }

    /// Check whether a function with the given name exists in any registered
    /// library without throwing.
    public func contains(functionNamed name: String) -> Bool {
        if !defaultLibraryAttempted {
            tryLoadDefaultLibrary()
        }
        lock.lock()
        defer { lock.unlock() }
        for library in libraries.reversed() where library.makeFunction(name: name) != nil {
            return true
        }
        return false
    }

    // MARK: - Diagnostics

    /// Returns a snapshot of function names across all registered libraries.
    /// Useful for logging/diagnostics. Not guaranteed to be cheap — intended
    /// for error paths and debug tools, not hot paths.
    public func allFunctionNames() -> [String] {
        if !defaultLibraryAttempted {
            tryLoadDefaultLibrary()
        }
        lock.lock()
        defer { lock.unlock() }
        return libraries.flatMap { $0.functionNames }
    }

    /// The number of currently registered libraries.
    public var registeredLibraryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return libraries.count
    }

    // MARK: - Private: default library loading

    /// Attempts to load the SDK's default library from the framework bundle.
    ///
    /// This is a no-op if:
    /// - No Metal device is available on this system.
    /// - The SDK has no `.metal` resources yet (e.g. during early Phase 1).
    /// - The resource bundle cannot be located.
    ///
    /// Failure is logged but not thrown; callers get a `functionNotFound`
    /// error at lookup time.
    ///
    /// ## Bundle resolution
    ///
    /// Uses `Bundle(for: ShaderLibrary.self)` rather than `Bundle.module` so
    /// this file can compile before shader resources are added in Round 4+.
    /// Once resources are declared in `Package.swift`, SPM will generate a
    /// framework bundle for the target and this lookup will find the
    /// compiled `.metallib` automatically.
    private func tryLoadDefaultLibrary() {
        lock.lock()
        guard !defaultLibraryAttempted else {
            lock.unlock()
            return
        }
        defaultLibraryAttempted = true
        lock.unlock()

        guard let device = MTLCreateSystemDefaultDevice() else {
            DCRLogging.logger.warning(
                "No Metal device available; default shader library not loaded",
                category: "ShaderLibrary"
            )
            return
        }

        let bundle = Bundle(for: ShaderLibrary.self)

        do {
            let library = try device.makeDefaultLibrary(bundle: bundle)
            lock.lock()
            libraries.insert(library, at: 0)  // Base layer; lowest priority.
            lock.unlock()
            DCRLogging.logger.info(
                "Default shader library loaded",
                category: "ShaderLibrary",
                attributes: ["functionCount": "\(library.functionNames.count)"]
            )
        } catch {
            // Expected during early Phase 1 (no .metal files yet). Consumers
            // can still register their own libraries via `register(_:)`.
            DCRLogging.logger.debug(
                "Default shader library not available; register libraries manually if needed",
                category: "ShaderLibrary",
                attributes: ["error": error.localizedDescription]
            )
        }
    }
}
