//
//  MetalSourceBuilderTests.swift
//  DCRenderKitTests
//
//  Verifies the Phase-3 step 3a runtime code generator:
//
//    · source structure (shape of generated text)
//    · Metal compilability (`makeLibrary(source:)` succeeds and the
//      uber kernel is resolvable by name)
//    · name derivation stability (hash is deterministic)
//    · error surfaces for unsupported inputs
//
//  These tests do not yet dispatch the compiled PSOs — that lands
//  once ComputeBackend's dispatch path is wired in step 3b.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class MetalSourceBuilderTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        device = dev
    }

    // MARK: - Source structure

    /// The generated source for a single Exposure node contains
    /// the canonical SRGBGamma helpers, the `ExposureUniforms`
    /// struct, the `DCRExposureBody` function, and an uber kernel
    /// declaration that invokes the body.
    func testExposureGeneratedSourceContainsExpectedBlocks() throws {
        let filter = ExposureFilter(exposure: 20)
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        let src = result.source

        XCTAssertTrue(src.contains("#include <metal_stdlib>"))
        XCTAssertTrue(src.contains("inline float DCRSRGBLinearToGamma"),
                      "SRGBGamma helpers must be injected")
        XCTAssertTrue(src.contains("struct ExposureUniforms"),
                      "Uniform struct must be spliced in from the .metal source")
        XCTAssertTrue(src.contains("inline half3 DCRExposureBody"),
                      "Body function must be spliced in")
        XCTAssertTrue(src.contains("kernel void \(result.functionName)"),
                      "Uber kernel declaration must use the builder's derived name")
        XCTAssertTrue(src.contains("rgb = DCRExposureBody(rgb, u0);"),
                      "Uber kernel must call the body function")
    }

    /// Saturation pulls in the OKLab helper block instead of the
    /// SRGBGamma one (OKLab is Saturation's sole helper dependency).
    func testSaturationGeneratedSourcePullsOKLabHelpers() throws {
        let filter = SaturationFilter(saturation: 1.3)
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        XCTAssertTrue(result.source.contains("DCRLinearSRGBToOKLab"))
        XCTAssertTrue(result.source.contains("DCROKLChGamutClamp"))
        XCTAssertFalse(result.source.contains("inline float DCRSRGBLinearToGamma"),
                       "Saturation doesn't reference SRGBGamma directly; helper block must not be injected")
    }

    /// Vibrance pulls in OKLab + its own private helpers
    /// (constants + `DCRVibranceSkinHueGate`).
    func testVibranceGeneratedSourcePullsVibrancePrivateHelpers() throws {
        let filter = VibranceFilter(vibrance: 0.5)
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        XCTAssertTrue(result.source.contains("DCROKLChGamutClamp"),
                      "OKLab base helpers must be injected")
        XCTAssertTrue(result.source.contains("kDCRVibranceCLow"),
                      "Vibrance private constants must be injected")
        XCTAssertTrue(result.source.contains("DCRVibranceSkinHueGate"),
                      "Vibrance private functions must be injected")
    }

    /// WhiteBalance pulls in SRGBGamma + its own `dcr_whiteBalance
    /// Overlay` helper.
    func testWhiteBalancePullsOverlayHelper() throws {
        let filter = WhiteBalanceFilter()
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        XCTAssertTrue(result.source.contains("dcr_whiteBalanceOverlay"),
                      "WhiteBalance private Overlay helper must be injected")
        XCTAssertTrue(result.source.contains("DCRSRGBLinearToGamma"),
                      "WhiteBalance depends on SRGBGamma for gamma wrap")
    }

    // MARK: - Metal compilability

    /// Every pure-pixelLocal built-in filter's generated source
    /// must compile cleanly via `MTLDevice.makeLibrary(source:)`,
    /// and the uber kernel name must resolve as an `MTLFunction`.
    /// This is the central Step-3a correctness gate — if source
    /// generation produces a string Metal can't parse, every
    /// downstream step (PSO compile, dispatch, parity) breaks.
    func testEveryPurePixelLocalFilterCompiles() throws {
        let filters: [any FilterProtocol] = [
            ExposureFilter(exposure: 10),
            ContrastFilter(contrast: 5, lumaMean: 0.5),
            BlacksFilter(blacks: 5),
            WhitesFilter(whites: 5),
            SaturationFilter(saturation: 1.2),
            VibranceFilter(vibrance: 0.3),
            WhiteBalanceFilter(),
        ]

        for filter in filters {
            let node = loweredSingleNode(for: .single(filter))
            let result: MetalSourceBuilder.BuildResult
            do {
                result = try MetalSourceBuilder.build(for: node)
            } catch {
                XCTFail("\(type(of: filter)): build failed — \(error)")
                continue
            }

            do {
                let library = try device.makeLibrary(
                    source: result.source,
                    options: nil
                )
                XCTAssertNotNil(
                    library.makeFunction(name: result.functionName),
                    "\(type(of: filter)): function \(result.functionName) should resolve on the compiled library"
                )
            } catch {
                XCTFail(
                    "\(type(of: filter)): Metal compilation failed — \(error)\n" +
                    "Generated source:\n\(result.source)"
                )
            }
        }
    }

    // MARK: - Name derivation

    /// The uber-kernel name is stable across invocations: building
    /// the same Node twice must return identical function names.
    /// This is the PSO-cache hit precondition.
    func testUberKernelNameIsDeterministic() throws {
        let filterA = ExposureFilter(exposure: 10)
        let filterB = ExposureFilter(exposure: 90)   // different slider, same shape
        let nodeA = loweredSingleNode(for: .single(filterA))
        let nodeB = loweredSingleNode(for: .single(filterB))

        let nameA = try MetalSourceBuilder.build(for: nodeA).functionName
        let nameB = try MetalSourceBuilder.build(for: nodeB).functionName
        XCTAssertEqual(
            nameA, nameB,
            "Different slider values must share the same uber kernel (uniforms are bound at dispatch, not baked into source)"
        )
    }

    /// Different filters with the same signature shape (both
    /// `.pixelLocalOnly`) produce different uber-kernel names —
    /// the body function name contributes to the hash.
    func testDifferentFiltersHaveDifferentUberNames() throws {
        let exposureName = try MetalSourceBuilder.build(
            for: loweredSingleNode(for: .single(ExposureFilter()))
        ).functionName
        let contrastName = try MetalSourceBuilder.build(
            for: loweredSingleNode(for: .single(ContrastFilter()))
        ).functionName
        XCTAssertNotEqual(exposureName, contrastName)
    }

    // MARK: - Unsupported inputs

    /// A `.neighborRead` Node is not supported by Step 3a — the
    /// builder surfaces `.unsupportedNodeKind`.
    func testNeighborReadNodeRejected() {
        let node = PipelineCompilerTestFixtures.neighborReadNode(
            id: 0,
            bodyName: "DCRSharpenBody",
            radius: 1,
            isFinal: true
        )
        XCTAssertThrowsError(try MetalSourceBuilder.build(for: node)) { error in
            guard case MetalSourceBuilder.BuildError.unsupportedNodeKind = error else {
                XCTFail("Expected .unsupportedNodeKind, got \(error)")
                return
            }
        }
    }

    /// Pixel-local with a non-`.pixelLocalOnly` signature shape
    /// (e.g. LUT3D's `.pixelLocalWithLUT3D`) is also rejected by
    /// Step 3a — the builder surfaces `.unsupportedSignatureShape`.
    func testLUT3DSignatureShapeRejected() throws {
        let identity2Cube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let cubeData = identity2Cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let filter = try LUT3DFilter(cubeData: cubeData, dimension: 2)
        let node = loweredSingleNode(for: .single(filter))

        XCTAssertThrowsError(try MetalSourceBuilder.build(for: node)) { error in
            guard case MetalSourceBuilder.BuildError.unsupportedSignatureShape = error else {
                XCTFail("Expected .unsupportedSignatureShape, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func loweredSingleNode(for step: AnyFilter) -> Node {
        let source = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        let graph = Lowering.lower([step], source: source)!
        XCTAssertEqual(graph.nodes.count, 1, "Test fixture expects single-node lowering")
        return graph.nodes[0]
    }
}
