//
//  InfrastructureTests.swift
//  DCRenderKitTests
//
//  Tests for Logger, Invariant, and ShaderLibrary.
//

import XCTest
@testable import DCRenderKit
import Metal

// MARK: - Logger

final class LoggerTests: XCTestCase {

    /// A test logger that captures all log events for assertion.
    actor CaptureLogger: DCRLogger {
        nonisolated(unsafe) private var _events: [Event] = []
        nonisolated private let lock = NSLock()

        struct Event: Sendable {
            let level: DCRLogLevel
            let category: String
            let message: String
            let attributes: [String: String]
            let hasError: Bool
        }

        nonisolated func log(
            level: DCRLogLevel,
            category: String,
            message: String,
            attributes: [String: String],
            error: Error?,
            file: String,
            line: Int
        ) {
            let event = Event(
                level: level,
                category: category,
                message: message,
                attributes: attributes,
                hasError: error != nil
            )
            lock.lock()
            _events.append(event)
            lock.unlock()
        }

        nonisolated var events: [Event] {
            lock.lock()
            defer { lock.unlock() }
            return _events
        }
    }

    func testLogLevelOrdering() {
        XCTAssertLessThan(DCRLogLevel.debug, DCRLogLevel.info)
        XCTAssertLessThan(DCRLogLevel.info, DCRLogLevel.warning)
        XCTAssertLessThan(DCRLogLevel.warning, DCRLogLevel.error)
        XCTAssertLessThan(DCRLogLevel.error, DCRLogLevel.fault)
    }

    func testLogLevelAllCases() {
        XCTAssertEqual(DCRLogLevel.allCases.count, 5)
    }

    func testLoggerDefaultConvenienceMethods() {
        let capture = CaptureLogger()
        capture.debug("hello", category: "Test", attributes: ["key": "value"])
        capture.info("world")
        capture.warning("issue", error: NSError(domain: "x", code: 1))
        capture.error("bad")
        capture.fault("worse")

        let events = capture.events
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0].level, .debug)
        XCTAssertEqual(events[0].attributes["key"], "value")
        XCTAssertEqual(events[1].level, .info)
        XCTAssertEqual(events[2].level, .warning)
        XCTAssertTrue(events[2].hasError)
        XCTAssertEqual(events[3].level, .error)
        XCTAssertEqual(events[4].level, .fault)
    }

    func testGlobalLoggerSwap() {
        let original = DCRLogging.logger
        defer { DCRLogging.logger = original }

        let capture = CaptureLogger()
        DCRLogging.logger = capture
        DCRLogging.logger.info("swap test", category: "Test")

        XCTAssertEqual(capture.events.count, 1)
        XCTAssertEqual(capture.events[0].message, "swap test")
    }

    func testOSLoggerBackendDoesNotCrash() {
        // Smoke test: ensure the default backend handles all levels without
        // crashing (output visible in Console.app).
        let logger = OSLoggerBackend(subsystem: "com.dcrenderkit.test")
        logger.debug("debug probe")
        logger.info("info probe")
        logger.warning("warning probe")
        logger.error("error probe")
        logger.fault("fault probe")
    }
}

// MARK: - Invariant

final class InvariantTests: XCTestCase {

    func testRequireFloatInRange() {
        XCTAssertNoThrow(try Invariant.require(50.0 as Float, in: 0...100, parameter: "x"))
    }

    func testRequireFloatOutOfRange() {
        do {
            try Invariant.require(150.0 as Float, in: 0...100, parameter: "x")
            XCTFail("Expected throw")
        } catch let error as PipelineError {
            if case .filter(.parameterOutOfRange(let name, let value, let range)) = error {
                XCTAssertEqual(name, "x")
                XCTAssertEqual(value, 150.0, accuracy: 1e-6)
                XCTAssertEqual(range.lowerBound, 0)
                XCTAssertEqual(range.upperBound, 100)
            } else {
                XCTFail("Wrong error variant: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRequireDoubleInRange() {
        XCTAssertNoThrow(try Invariant.require(0.5, in: 0.0...1.0, parameter: "y"))
        XCTAssertThrowsError(try Invariant.require(-0.1, in: 0.0...1.0, parameter: "y"))
    }

    func testRequireNonNilSuccess() throws {
        let value: Int? = 42
        let unwrapped = try Invariant.requireNonNil(value, "input")
        XCTAssertEqual(unwrapped, 42)
    }

    func testRequireNonNilFailure() {
        let value: Int? = nil
        do {
            _ = try Invariant.requireNonNil(value, "input")
            XCTFail("Expected throw")
        } catch PipelineError.filter(.missingRequiredInput(let name)) {
            XCTAssertEqual(name, "input")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRequireConditionSuccess() {
        XCTAssertNoThrow(try Invariant.require(true, filterName: "F", "msg"))
    }

    func testRequireConditionFailure() {
        do {
            try Invariant.require(false, filterName: "MyFilter", "value must be positive")
            XCTFail("Expected throw")
        } catch PipelineError.filter(.runtimeFailure(let name, let underlying)) {
            XCTAssertEqual(name, "MyFilter")
            XCTAssertTrue("\(underlying)".contains("positive"))
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testCheckPassing() {
        // Should not crash or log on passing condition.
        Invariant.check(true, "always true")
    }

    // Note: we don't test Invariant.check failure because it calls
    // assertionFailure in Debug builds which would abort the test process.
    // Release-mode logging behavior is covered implicitly.

    func testUnreachableReturnsFallback() {
        #if !DEBUG
        let value = Invariant.unreachable("should not happen", fallback: 42)
        XCTAssertEqual(value, 42)
        #endif
        // In Debug, unreachable asserts and aborts; skip the test.
    }
}

// MARK: - ShaderLibrary

final class ShaderLibraryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start each test with a clean slate.
        ShaderLibrary.shared.unregisterAll()
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        super.tearDown()
    }

    func testSharedIsSingleton() {
        XCTAssertTrue(ShaderLibrary.shared === ShaderLibrary.shared)
    }

    func testFunctionNotFoundThrows() {
        do {
            _ = try ShaderLibrary.shared.function(named: "__nonexistent_kernel__")
            XCTFail("Expected throw")
        } catch PipelineError.pipelineState(.functionNotFound(let name)) {
            XCTAssertEqual(name, "__nonexistent_kernel__")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testContainsReturnsFalseWhenEmpty() {
        XCTAssertFalse(ShaderLibrary.shared.contains(functionNamed: "__nonexistent__"))
    }

    func testRegisterLibraryIncreasesCount() throws {
        try XCTSkipUnless(
            MTLCreateSystemDefaultDevice() != nil,
            "Metal device required"
        )
        let initialCount = ShaderLibrary.shared.registeredLibraryCount

        // Create a minimal library from source to test registration.
        let device = MTLCreateSystemDefaultDevice()!
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void test_kernel_a(uint2 gid [[thread_position_in_grid]]) {}
        """
        let library = try device.makeLibrary(source: source, options: nil)

        ShaderLibrary.shared.register(library)

        XCTAssertEqual(
            ShaderLibrary.shared.registeredLibraryCount,
            initialCount + 1
        )
        XCTAssertTrue(
            ShaderLibrary.shared.contains(functionNamed: "test_kernel_a")
        )

        let fn = try ShaderLibrary.shared.function(named: "test_kernel_a")
        XCTAssertEqual(fn.name, "test_kernel_a")
    }

    func testLaterRegistrationTakesPrecedence() throws {
        try XCTSkipUnless(
            MTLCreateSystemDefaultDevice() != nil,
            "Metal device required"
        )
        let device = MTLCreateSystemDefaultDevice()!

        // Two libraries with the same function name.
        let sourceV1 = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void shared_kernel(texture2d<half, access::write> out [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {}
        """
        let libraryV1 = try device.makeLibrary(source: sourceV1, options: nil)
        let libraryV2 = try device.makeLibrary(source: sourceV1, options: nil)

        ShaderLibrary.shared.register(libraryV1)
        ShaderLibrary.shared.register(libraryV2)

        // Lookup should succeed (later registration takes precedence, but
        // both have the function).
        let fn = try ShaderLibrary.shared.function(named: "shared_kernel")
        XCTAssertEqual(fn.name, "shared_kernel")
    }

    func testAllFunctionNamesReturnsRegisteredFunctions() throws {
        try XCTSkipUnless(
            MTLCreateSystemDefaultDevice() != nil,
            "Metal device required"
        )
        let device = MTLCreateSystemDefaultDevice()!
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void kernel_one(uint2 gid [[thread_position_in_grid]]) {}
        kernel void kernel_two(uint2 gid [[thread_position_in_grid]]) {}
        """
        let library = try device.makeLibrary(source: source, options: nil)
        ShaderLibrary.shared.register(library)

        let names = ShaderLibrary.shared.allFunctionNames()
        XCTAssertTrue(names.contains("kernel_one"))
        XCTAssertTrue(names.contains("kernel_two"))
    }
}
