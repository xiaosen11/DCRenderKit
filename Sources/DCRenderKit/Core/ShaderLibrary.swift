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
@available(iOS 18.0, *)
public final class ShaderLibrary: @unchecked Sendable {

    /// The shared registry. Thread-safe.
    ///
    /// Most apps use this instance — the SDK's built-in shaders register
    /// themselves here on first lookup. If you run multiple `Pipeline`
    /// instances that need to register conflicting custom shaders (e.g.
    /// two renderers loading different `.metallib` files with overlapping
    /// function names), give each `Pipeline` its own `ShaderLibrary`
    /// instance via `Pipeline(shaderLibrary:)`.
    public static let shared = ShaderLibrary()

    private let lock = NSLock()
    private var libraries: [MTLLibrary] = []
    private var defaultLibraryAttempted = false

    /// Create a new, empty registry.
    ///
    /// Most callers should use ``shared`` instead. Construct a private
    /// instance only when you need shader-name isolation between
    /// concurrent `Pipeline`s — see `docs/multi-pipeline-cookbook.md`.
    public init() {}

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
    /// Two strategies are attempted in order:
    ///
    /// 1. Load a pre-compiled `default.metallib` from the bundle. This is the
    ///    fast path — it avoids runtime Metal-source compilation and is the
    ///    output of Xcode builds when the SDK is consumed as an xcframework.
    /// 2. Fall back to compiling every `.metal` source file in the bundle at
    ///    runtime. This path is required when the SDK is consumed via
    ///    `swift build` / SwiftPM from the command line, because SPM does
    ///    not run the Metal compiler on `.metal` resources; it only bundles
    ///    them as `.copy` files. Runtime compilation produces an identical
    ///    `MTLLibrary`, at the cost of ≈ 10–30 ms on first use (amortized
    ///    across the SDK's lifetime, cached by the registry).
    ///
    /// Failure is logged but not thrown; callers get a `functionNotFound`
    /// error at lookup time when they ask for a specific kernel.
    ///
    /// ## Bundle resolution
    ///
    /// When built by SwiftPM, `Bundle.module` points to the target's resource
    /// bundle. For alternate distributions (e.g. a hand-rolled xcframework
    /// that vendors the sources without `Bundle.module`), we fall back to
    /// `Bundle(for: ShaderLibrary.self)`.
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

        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ShaderLibrary.self)
        #endif

        // Fast path: pre-compiled metallib.
        if let library = loadPrecompiledMetallib(device: device, bundle: bundle) {
            lock.lock()
            libraries.insert(library, at: 0)
            lock.unlock()
            DCRLogging.logger.info(
                "Default shader library loaded (precompiled)",
                category: "ShaderLibrary",
                attributes: ["functionCount": "\(library.functionNames.count)"]
            )
            return
        }

        // Fallback path: compile `.metal` sources found in the bundle.
        let compiledCount = compileMetalSourcesFromBundle(device: device, bundle: bundle)
        if compiledCount > 0 {
            DCRLogging.logger.info(
                "Default shader library loaded (runtime-compiled)",
                category: "ShaderLibrary",
                attributes: ["fileCount": "\(compiledCount)"]
            )
            return
        }

        DCRLogging.logger.debug(
            "No shader library available; register libraries manually if needed",
            category: "ShaderLibrary"
        )
    }

    /// Attempt to load a pre-compiled `default.metallib` from the bundle.
    /// Returns nil when the metallib is missing (typical SwiftPM CLI build).
    private func loadPrecompiledMetallib(device: MTLDevice, bundle: Bundle) -> MTLLibrary? {
        do {
            return try device.makeDefaultLibrary(bundle: bundle)
        } catch {
            return nil
        }
    }

    /// Compile every `.metal` source file in the bundle to its own
    /// `MTLLibrary` and register each one. Returns the number of files
    /// that produced a usable library.
    ///
    /// Per-file compilation (vs. concatenating sources) guarantees that
    /// sibling files can each declare their own `constant` globals or
    /// helper structs without a cross-file symbol clash.
    private func compileMetalSourcesFromBundle(device: MTLDevice, bundle: Bundle) -> Int {
        guard let urls = bundle.urls(forResourcesWithExtension: "metal", subdirectory: nil),
              !urls.isEmpty else {
            return 0
        }

        var compiled = 0
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                DCRLogging.logger.warning(
                    "Failed to read Metal source",
                    category: "ShaderLibrary",
                    attributes: ["url": url.lastPathComponent]
                )
                continue
            }
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                lock.lock()
                libraries.insert(library, at: 0)
                lock.unlock()
                compiled += 1
            } catch {
                DCRLogging.logger.error(
                    "Runtime Metal compilation failed",
                    category: "ShaderLibrary",
                    attributes: [
                        "file": url.lastPathComponent,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
        return compiled
    }
}
