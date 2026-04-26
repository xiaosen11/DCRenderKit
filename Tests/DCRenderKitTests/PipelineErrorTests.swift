//
//  PipelineErrorTests.swift
//  DCRenderKitTests
//
//  Systematic coverage of the `PipelineError` typed-enum hierarchy.
//  Up until this file landed, the error cases were covered
//  implicitly — each dispatcher / loader / filter test threw one
//  or two specific cases and asserted on them. That's thorough for
//  the cases exercised in production but leaves cold cases
//  (diagnostic strings, rarely-thrown branches) without regression
//  coverage.
//
//  This file provides the central catalogue:
//
//  - **Description tests** instantiate every case and assert its
//    `CustomStringConvertible` / `LocalizedError` text is non-empty
//    and includes the case's structured payload (so e.g.
//    `parameterOutOfRange` prints the parameter name and the range
//    bounds).
//  - **Pattern-match tests** confirm `switch` on the top-level
//    `PipelineError` selects the right domain for each case, which
//    is what consumer error-handling code depends on.
//  - **Trigger tests** drive `Invariant.require*` through
//    `PipelineError.filter` cases to prove the public helpers hit
//    the typed case, not a generic `NSError`.
//
//  Coverage is not "every case round-trips through the GPU" —
//  that's the dispatcher tests' job. Coverage here is "every case
//  is typed, printable, and reachable".
//

import XCTest
@testable import DCRenderKit

final class PipelineErrorTests: XCTestCase {

    // MARK: - Device domain

    func testDeviceErrorCasesHaveDescriptions() {
        let cases: [DeviceError] = [
            .noMetalDevice,
            .commandQueueCreationFailed,
            .commandBufferCreationFailed,
            .commandEncoderCreationFailed(kind: .compute),
            .commandEncoderCreationFailed(kind: .render),
            .commandEncoderCreationFailed(kind: .blit),
            .gpuExecutionFailed(underlying: SampleUnderlyingError(token: "dev-gpu")),
        ]
        for err in cases {
            XCTAssertFalse(err.description.isEmpty,
                           "DeviceError description should be non-empty for \(err)")
        }

        // encoder kind is surfaced in the description
        let rasterEnc = DeviceError.commandEncoderCreationFailed(kind: .render)
        XCTAssertTrue(rasterEnc.description.contains("render"))

        let blitEnc = DeviceError.commandEncoderCreationFailed(kind: .blit)
        XCTAssertTrue(blitEnc.description.contains("blit"))

        // underlying error message flows through
        let underlying = SampleUnderlyingError(token: "gpu-token-42")
        let gpuFail = DeviceError.gpuExecutionFailed(underlying: underlying)
        XCTAssertTrue(gpuFail.description.contains("gpu-token-42"))
    }

    // MARK: - Texture domain

    func testTextureErrorCasesHaveDescriptions() {
        let cases: [TextureError] = [
            .loadFailed(source: "CGImage", underlying: nil),
            .loadFailed(source: "UIImage",
                        underlying: SampleUnderlyingError(token: "load-fail")),
            .formatMismatch(expected: ".rgba16Float", got: ".bgra8Unorm"),
            .dimensionsInvalid(width: -3, height: 0, reason: "negative width"),
            .imageDecodeFailed(format: "HEIF"),
            .textureCreationFailed(reason: "allocation returned nil"),
            .pixelBufferConversionFailed(cvReturn: -6660),
            .pixelFormatUnsupported(format: "420YpCbCr8"),
        ]
        for err in cases {
            XCTAssertFalse(err.description.isEmpty,
                           "TextureError description should be non-empty for \(err)")
        }

        // format mismatch surfaces expected / got
        let mismatch = TextureError.formatMismatch(
            expected: "rgba16Float", got: "bgra8Unorm"
        )
        XCTAssertTrue(mismatch.description.contains("rgba16Float"))
        XCTAssertTrue(mismatch.description.contains("bgra8Unorm"))

        // dimensions include width and height
        let dims = TextureError.dimensionsInvalid(
            width: 256, height: -1, reason: "negative height"
        )
        XCTAssertTrue(dims.description.contains("256"))
        XCTAssertTrue(dims.description.contains("-1"))
        XCTAssertTrue(dims.description.contains("negative height"))

        // cv return flows through
        let cvFail = TextureError.pixelBufferConversionFailed(cvReturn: -6661)
        XCTAssertTrue(cvFail.description.contains("-6661"))
    }

    // MARK: - PipelineState domain

    func testPipelineStateErrorCasesHaveDescriptions() {
        let underlying = SampleUnderlyingError(token: "kernel-compile-X")
        let cases: [PipelineStateError] = [
            .computeCompileFailed(kernel: "DCRGhostFilter", underlying: underlying),
            .renderCompileFailed(vertex: "vsA", fragment: "fsB", underlying: underlying),
            .functionNotFound(name: "DCRMissingKernel"),
            .libraryLoadFailed(reason: "metallib not found in bundle"),
        ]
        for err in cases {
            XCTAssertFalse(err.description.isEmpty,
                           "PipelineStateError description non-empty for \(err)")
        }

        let compile = PipelineStateError.computeCompileFailed(
            kernel: "DCRGhostFilter", underlying: underlying
        )
        XCTAssertTrue(compile.description.contains("DCRGhostFilter"))
        XCTAssertTrue(compile.description.contains("kernel-compile-X"))

        let missing = PipelineStateError.functionNotFound(name: "DCRMissingKernel")
        XCTAssertTrue(missing.description.contains("DCRMissingKernel"))
    }

    // MARK: - Filter domain

    func testFilterErrorCasesHaveDescriptions() {
        let underlying = SampleUnderlyingError(token: "filter-runtime")
        let cases: [FilterError] = [
            .parameterOutOfRange(name: "exposure", value: 500, range: -100...100),
            .missingRequiredInput(name: "overlay"),
            .emptyPassGraph(filterName: "GhostFilter"),
            .invalidPassGraph(filterName: "GhostFilter", reason: "cycle detected"),
            .runtimeFailure(filterName: "GhostFilter", underlying: underlying),
        ]
        for err in cases {
            XCTAssertFalse(err.description.isEmpty,
                           "FilterError description non-empty for \(err)")
        }

        let oor = FilterError.parameterOutOfRange(
            name: "exposure", value: 500, range: -100...100
        )
        XCTAssertTrue(oor.description.contains("exposure"))
        XCTAssertTrue(oor.description.contains("500"))

        let invalid = FilterError.invalidPassGraph(
            filterName: "GhostFilter", reason: "cycle detected"
        )
        XCTAssertTrue(invalid.description.contains("GhostFilter"))
        XCTAssertTrue(invalid.description.contains("cycle detected"))
    }

    // MARK: - Resource domain

    func testResourceErrorCasesHaveDescriptions() {
        let cases: [ResourceError] = [
            .texturePoolExhausted(requestedBytes: 128 * 1024 * 1024),
            .uniformBufferAllocationFailed(requestedBytes: 65_536),
            .commandBufferPoolExhausted(maxSize: 4),
            .samplerCreationFailed(reason: "invalid addressMode"),
        ]
        for err in cases {
            XCTAssertFalse(err.description.isEmpty,
                           "ResourceError description non-empty for \(err)")
        }

        let exhausted = ResourceError.texturePoolExhausted(requestedBytes: 777_000)
        XCTAssertTrue(exhausted.description.contains("777000"))

        let cbCap = ResourceError.commandBufferPoolExhausted(maxSize: 9)
        XCTAssertTrue(cbCap.description.contains("9"))

        let sampler = ResourceError.samplerCreationFailed(reason: "bad addressMode")
        XCTAssertTrue(sampler.description.contains("bad addressMode"))
    }

    // MARK: - PipelineError (top level)

    func testPipelineErrorLocalizedErrorWrapsDomain() {
        let top: [PipelineError] = [
            .device(.noMetalDevice),
            .texture(.loadFailed(source: "CGImage", underlying: nil)),
            .pipelineState(.functionNotFound(name: "foo")),
            .filter(.missingRequiredInput(name: "mask")),
            .resource(.commandBufferPoolExhausted(maxSize: 4)),
        ]
        for err in top {
            XCTAssertNotNil(err.errorDescription,
                            "top-level errorDescription should exist for \(err)")
            XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
        }

        // Each top-level case prefixes with its domain label.
        XCTAssertTrue(top[0].errorDescription?.lowercased().contains("device") ?? false)
        XCTAssertTrue(top[1].errorDescription?.lowercased().contains("texture") ?? false)
        XCTAssertTrue(top[2].errorDescription?.lowercased().contains("pipeline") ?? false)
        XCTAssertTrue(top[3].errorDescription?.lowercased().contains("filter") ?? false)
        XCTAssertTrue(top[4].errorDescription?.lowercased().contains("resource") ?? false)
    }

    func testPipelineErrorSwitchSelectsCorrectDomain() {
        let samples: [(PipelineError, String)] = [
            (.device(.noMetalDevice), "device"),
            (.texture(.imageDecodeFailed(format: "PNG")), "texture"),
            (.pipelineState(.libraryLoadFailed(reason: "no library")), "pipelineState"),
            (.filter(.emptyPassGraph(filterName: "X")), "filter"),
            (.resource(.texturePoolExhausted(requestedBytes: 1)), "resource"),
        ]

        for (err, expected) in samples {
            let matched: String
            switch err {
            case .device:        matched = "device"
            case .texture:       matched = "texture"
            case .pipelineState: matched = "pipelineState"
            case .filter:        matched = "filter"
            case .resource:      matched = "resource"
            }
            XCTAssertEqual(matched, expected,
                           "switch over \(err) matched \(matched), expected \(expected)")
        }
    }

    // MARK: - Trigger tests (Invariant → FilterError)

    func testInvariantRequireInRangeThrowsParameterOutOfRange() {
        do {
            try Invariant.require(Float(500), in: 0...100, parameter: "strength")
            XCTFail("Expected .parameterOutOfRange but no throw")
        } catch PipelineError.filter(.parameterOutOfRange(let name, let value, let range)) {
            XCTAssertEqual(name, "strength")
            XCTAssertEqual(value, 500, accuracy: 0.0001)
            XCTAssertEqual(range.lowerBound, 0)
            XCTAssertEqual(range.upperBound, 100)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testInvariantRequireInRangeDoubleThrowsParameterOutOfRange() {
        do {
            try Invariant.require(Double(-5), in: 0...10, parameter: "tolerance")
            XCTFail("Expected .parameterOutOfRange but no throw")
        } catch PipelineError.filter(.parameterOutOfRange(let name, let value, _)) {
            XCTAssertEqual(name, "tolerance")
            XCTAssertEqual(value, -5, accuracy: 0.0001)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testInvariantRequireNonNilThrowsMissingRequiredInput() {
        let source: String? = nil
        do {
            _ = try Invariant.requireNonNil(source, "input")
            XCTFail("Expected .missingRequiredInput but no throw")
        } catch PipelineError.filter(.missingRequiredInput(let name)) {
            XCTAssertEqual(name, "input")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testInvariantRequireNonNilReturnsValueWhenPresent() throws {
        let source: String? = "hello"
        let unwrapped = try Invariant.requireNonNil(source, "greeting")
        XCTAssertEqual(unwrapped, "hello")
    }

    func testInvariantRequireConditionThrowsRuntimeFailure() {
        do {
            try Invariant.require(
                false,
                filterName: "GhostFilter",
                "invariant violated in test"
            )
            XCTFail("Expected .runtimeFailure but no throw")
        } catch PipelineError.filter(.runtimeFailure(let filterName, let underlying)) {
            XCTAssertEqual(filterName, "GhostFilter")
            XCTAssertTrue("\(underlying)".contains("invariant violated"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testInvariantRequireConditionDoesNotThrowWhenTrue() throws {
        try Invariant.require(
            true,
            filterName: "GhostFilter",
            "this message should not surface"
        )
    }

    // MARK: - Trigger tests (CubeFileParser → TextureError)

    func testLUT3DFilterFromMissingCubeThrowsMissingRequiredInput() {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/definitely-not-a-real-cube.cube")
        XCTAssertThrowsError(
            try LUT3DFilter(cubeURL: nonExistentURL)
        ) { err in
            guard case PipelineError.filter(.missingRequiredInput(let name)) = err else {
                XCTFail("Expected .missingRequiredInput, got \(err)")
                return
            }
            XCTAssertTrue(name.contains("LUT3DFilter"))
        }
    }

    func testLUT3DFilterFromMalformedDataThrowsTextureCreationFailed() throws {
        // dimension=3 requires 3³·16 = 432 bytes of float data. Hand in
        // 5 bytes so the parser / factory rejects it.
        let undersized = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertThrowsError(
            try LUT3DFilter(cubeData: undersized, dimension: 3)
        ) { err in
            guard case PipelineError.texture(.textureCreationFailed) = err else {
                XCTFail("Expected .textureCreationFailed, got \(err)")
                return
            }
        }
    }
}

// MARK: - Private helper

/// Minimal `Error` + `CustomStringConvertible` stand-in so tests
/// can thread a known-token underlying error through
/// `DeviceError.gpuExecutionFailed` / `PipelineStateError.*` and
/// assert the token surfaces in the wrapping error's description.
private struct SampleUnderlyingError: Error, CustomStringConvertible,
                                      LocalizedError {
    let token: String
    var description: String { "SampleUnderlyingError(token: \(token))" }
    var errorDescription: String? { description }
}
