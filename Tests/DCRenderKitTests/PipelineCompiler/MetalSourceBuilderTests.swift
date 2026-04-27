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

    /// Saturation pulls in the OKLab helper block (its sole helper
    /// dependency) and does NOT pull in the SRGBGamma helpers — the
    /// filter is hard-contracted to linear input via Swift-side
    /// `precondition`, so no gamma round-trip exists in the body.
    func testSaturationGeneratedSourcePullsOKLabHelpers() throws {
        let filter = SaturationFilter(saturation: 1.3)
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        XCTAssertTrue(result.source.contains("DCRLinearSRGBToOKLab"))
        XCTAssertTrue(result.source.contains("DCROKLChGamutClamp"))
        XCTAssertFalse(result.source.contains("inline float DCRSRGBLinearToGamma"),
                       "Saturation must NOT inject SRGBGamma helpers — body is linear-only")
        XCTAssertFalse(result.source.contains("inline float DCRSRGBGammaToLinear"),
                       "Saturation must NOT inject SRGBGamma helpers — body is linear-only")
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

    /// A `.neighborRead` Node whose body's signature shape is
    /// not `.neighborReadWithSource` is rejected — the builder
    /// surfaces `.unsupportedSignatureShape`. The fixture's
    /// `neighborReadNode` helper constructs bodies with the
    /// default `.pixelLocalOnly` shape, which is itself a
    /// graph-construction bug (the shape should match the kind)
    /// but is useful here to exercise the rejection path.
    func testNeighborReadNodeWithMismatchedShapeRejected() {
        let node = PipelineCompilerTestFixtures.neighborReadNode(
            id: 0,
            bodyName: "DCRSharpenBody",
            radius: 1,
            isFinal: true
        )
        XCTAssertThrowsError(try MetalSourceBuilder.build(for: node)) { error in
            guard case MetalSourceBuilder.BuildError.unsupportedSignatureShape = error else {
                XCTFail("Expected .unsupportedSignatureShape, got \(error)")
                return
            }
        }
    }

    /// LUT3D now compiles via the `.pixelLocalWithLUT3D` codegen
    /// path (Step 3c). Checks that build succeeds, source mentions
    /// the LUT texture binding, and the Metal library compiles.
    func testLUT3DShapeCompiles() throws {
        let identity2Cube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let cubeData = identity2Cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let filter = try LUT3DFilter(cubeData: cubeData, dimension: 2)
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        XCTAssertTrue(result.source.contains("texture3d<float, access::read> lut"))
        XCTAssertTrue(result.source.contains("DCRLUT3DBody(c.rgb, u0, gid, lut)"))
        XCTAssertEqual(result.bindings.auxiliaryTextureSlotCount, 1)

        let library = try device.makeLibrary(source: result.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: result.functionName))
    }

    /// NormalBlend compiles via the `.pixelLocalWithOverlay`
    /// codegen path. Requires a dummy overlay texture for filter
    /// construction.
    func testNormalBlendShapeCompiles() throws {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        let overlay = device.makeTexture(descriptor: desc)!
        let filter = NormalBlendFilter(overlay: overlay)
        let node = loweredSingleNode(for: .single(filter))

        let result = try MetalSourceBuilder.build(for: node)
        XCTAssertTrue(result.source.contains("texture2d<half, access::read>  overlay"))
        XCTAssertTrue(result.source.contains("DCRNormalBlendBody(c, u0, gid, overlay, uint2(outW, outH))"))
        XCTAssertTrue(result.source.contains("output.write(rgba, gid)"),
                      "NormalBlend returns rgba; uber kernel writes it directly")
        XCTAssertEqual(result.bindings.auxiliaryTextureSlotCount, 1)

        let library = try device.makeLibrary(source: result.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: result.functionName))
    }

    /// Sharpen / FilmGrain / CCD all use the
    /// `.neighborReadWithSource` shape: one body signature, no
    /// aux texture slot (the body receives the source itself as
    /// its `src` param).
    func testNeighborReadWithSourceFiltersCompile() throws {
        let filters: [any FilterProtocol] = [
            SharpenFilter(),
            FilmGrainFilter(),
            CCDFilter(),
        ]
        for filter in filters {
            let node = loweredSingleNode(for: .single(filter))
            let result = try MetalSourceBuilder.build(for: node)
            XCTAssertEqual(result.bindings.auxiliaryTextureSlotCount, 0,
                           "\(type(of: filter)): neighbourhood-style bodies read primary source; no aux slot expected")
            // Kernel signature must not introduce an extra texture
            // parameter at slot 2.
            XCTAssertFalse(result.source.contains("[[texture(2)]]"),
                           "\(type(of: filter)): unexpected extra texture slot in generated kernel")
            let library = try device.makeLibrary(source: result.source, options: nil)
            XCTAssertNotNil(library.makeFunction(name: result.functionName),
                            "\(type(of: filter)): uber kernel should resolve")
        }
    }

    // MARK: - Cluster: fused pixelLocalOnly

    /// A 3-filter pixelLocal chain lowers and optimises into a
    /// single `.fusedPixelLocalCluster`. The builder must generate
    /// an uber kernel that:
    ///   · declares 3 uniform buffer slots (buffer(0..2))
    ///   · includes each filter's uniform struct once
    ///   · includes each filter's body function once
    ///   · calls the bodies in cluster order
    ///   · compiles and resolves the uber kernel name
    func testThreeFilterClusterCompilesAndBinds() throws {
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.2)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(
            steps,
            source: TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        ))
        let optimised = Optimizer.optimize(lowered)
        XCTAssertEqual(optimised.nodes.count, 1, "Three pixelLocals should collapse into one cluster")

        let clusterNode = optimised.nodes[0]
        let result = try MetalSourceBuilder.build(for: clusterNode)

        // Binding plan: three uniform buffers, zero aux.
        XCTAssertEqual(result.bindings.uniformBufferCount, 3)
        XCTAssertEqual(result.bindings.auxiliaryTextureSlotCount, 0)

        // Source-shape checks.
        XCTAssertTrue(result.source.contains("struct ExposureUniforms"))
        XCTAssertTrue(result.source.contains("struct ContrastUniforms"))
        XCTAssertTrue(result.source.contains("struct SaturationUniforms"))
        XCTAssertTrue(result.source.contains("inline half3 DCRExposureBody"))
        XCTAssertTrue(result.source.contains("inline half3 DCRContrastBody"))
        XCTAssertTrue(result.source.contains("inline half3 DCRSaturationBody"))

        // Body call sequence: must appear in the order members
        // were lowered.
        let exposureCall = result.source.range(of: "rgb = DCRExposureBody(rgb, u0);")
        let contrastCall = result.source.range(of: "rgb = DCRContrastBody(rgb, u1);")
        let satCall = result.source.range(of: "rgb = DCRSaturationBody(rgb, u2);")
        XCTAssertNotNil(exposureCall)
        XCTAssertNotNil(contrastCall)
        XCTAssertNotNil(satCall)
        if let e = exposureCall, let c = contrastCall, let s = satCall {
            XCTAssertLessThan(e.lowerBound, c.lowerBound)
            XCTAssertLessThan(c.lowerBound, s.lowerBound)
        }

        // Buffer slot bindings: u0 at buffer(0), u1 at buffer(1), u2 at buffer(2).
        XCTAssertTrue(result.source.contains("u0 [[buffer(0)]]"))
        XCTAssertTrue(result.source.contains("u1 [[buffer(1)]]"))
        XCTAssertTrue(result.source.contains("u2 [[buffer(2)]]"))

        // Metal compilation: the whole thing must parse and the
        // uber kernel must resolve on the compiled library.
        let library = try device.makeLibrary(source: result.source, options: nil)
        XCTAssertNotNil(
            library.makeFunction(name: result.functionName),
            "Cluster uber kernel must resolve after compilation"
        )
    }

    /// Cluster naming is deterministic: building the same cluster
    /// shape twice (different uniform values, same member body
    /// sequence) returns the same function name so the PSO cache
    /// can share a compiled pipeline across slider positions.
    func testClusterNameIsDeterministicAcrossSliderValues() throws {
        func makeCluster(exposureValue: Float) throws -> Node {
            let steps: [AnyFilter] = [
                .single(ExposureFilter(exposure: exposureValue)),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            ]
            let lowered = try XCTUnwrap(Lowering.lower(
                steps,
                source: TextureInfo(width: 128, height: 128, pixelFormat: .rgba16Float)
            ))
            let optimised = Optimizer.optimize(lowered)
            return optimised.nodes[0]
        }

        let nameA = try MetalSourceBuilder.build(for: makeCluster(exposureValue: 10)).functionName
        let nameB = try MetalSourceBuilder.build(for: makeCluster(exposureValue: 80)).functionName
        XCTAssertEqual(nameA, nameB)
    }

    /// Clusters with different member ordering produce different
    /// uber-kernel names — the hash incorporates the ordered
    /// sequence of body function names.
    func testClusterNameDiffersWithMemberOrder() throws {
        func makeCluster(order: [AnyFilter]) throws -> Node {
            let lowered = try XCTUnwrap(Lowering.lower(
                order,
                source: TextureInfo(width: 128, height: 128, pixelFormat: .rgba16Float)
            ))
            let optimised = Optimizer.optimize(lowered)
            return optimised.nodes[0]
        }

        let forward = try makeCluster(order: [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
        ])
        let reversed = try makeCluster(order: [
            .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            .single(ExposureFilter(exposure: 10)),
        ])

        let nameForward = try MetalSourceBuilder.build(for: forward).functionName
        let nameReversed = try MetalSourceBuilder.build(for: reversed).functionName
        XCTAssertNotEqual(
            nameForward, nameReversed,
            "Order matters: Exposure→Contrast and Contrast→Exposure aren't the same kernel"
        )
    }

    // MARK: - Source-tap fusion (KernelInlining + TailSink)

    /// `KernelInlining` head fusion: the `.neighborRead` node carries
    /// `inlinedBodyBeforeSample`. The codegen must:
    ///   · emit a `DCRFusedTap_<P>` struct that pre-applies P to every
    ///     sample (so `tap.read(int2(gid))` for the centre and
    ///     `tap.read(pos + offset)` for neighbours both go through P)
    ///   · bind P's uniform at `buffer(1)` (head slot)
    ///   · keep N's uniform at `buffer(0)` and emit no aux textures
    func testKernelInliningHeadFusionGeneratesFusedTapAndCompiles() throws {
        let sharpen = SharpenFilter(amount: 1.0, stepPixels: 1)
        let exposure = ExposureFilter(exposure: 25)
        let sharpenNode = loweredSingleNode(for: .single(sharpen))
        let exposureNode = loweredSingleNode(for: .single(exposure))
        guard
            case let .neighborRead(nBody, _, _, _) = sharpenNode.kind,
            case let .pixelLocal(pBody, pUniforms, _, _) = exposureNode.kind
        else {
            return XCTFail("Lowering produced unexpected node kinds")
        }

        let inlined = FusedClusterMember(
            body: pBody,
            uniforms: pUniforms,
            debugLabel: "Exposure[inlined]",
            additionalRange: 0..<0
        )
        let fused = Node(
            id: sharpenNode.id,
            kind: sharpenNode.kind,
            inputs: sharpenNode.inputs,
            outputSpec: sharpenNode.outputSpec,
            isFinal: sharpenNode.isFinal,
            debugLabel: "Sharpen[inline:Exposure]",
            inlinedBodyBeforeSample: inlined
        )

        let result = try MetalSourceBuilder.build(for: fused)

        XCTAssertEqual(result.bindings.uniformBufferCount, 2,
                       "Head fusion adds one uniform slot for P")
        XCTAssertEqual(result.bindings.auxiliaryTextureSlotCount, 0)
        XCTAssertTrue(result.source.contains("struct DCRFusedTap_\(pBody.functionName)"),
                      "Head fusion must emit a fused tap struct named after P")
        XCTAssertTrue(result.source.contains("DCRFusedTap_\(pBody.functionName) tap{input, uHead};"),
                      "Kernel must construct the fused tap with input + uHead")
        XCTAssertTrue(result.source.contains("uHead [[buffer(1)]]"),
                      "P's uniform must bind at buffer(1)")
        XCTAssertTrue(result.source.contains("\(nBody.functionName)(c.rgb, u0, gid, tap)"),
                      "N's body must be called with the templated tap")

        let library = try device.makeLibrary(source: result.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: result.functionName))
    }

    /// `TailSink` tail fusion: the `.neighborRead` node carries
    /// `tailSinkedBody`. The codegen must:
    ///   · emit `pTailBody(rgb, uTail)` between N's body and the
    ///     `output.write`
    ///   · bind P's uniform at `buffer(1)` (tail slot, since no head)
    ///   · still use `DCRRawSourceTap` (no head fusion)
    func testTailSinkTailFusionAppendsBodyCallAndCompiles() throws {
        let sharpen = SharpenFilter(amount: 1.0, stepPixels: 1)
        let saturation = SaturationFilter(saturation: 1.2)
        let sharpenNode = loweredSingleNode(for: .single(sharpen))
        let satNode = loweredSingleNode(for: .single(saturation))
        guard
            case let .neighborRead(nBody, _, _, _) = sharpenNode.kind,
            case let .pixelLocal(pBody, pUniforms, _, _) = satNode.kind
        else {
            return XCTFail("Lowering produced unexpected node kinds")
        }

        let sunk = FusedClusterMember(
            body: pBody,
            uniforms: pUniforms,
            debugLabel: "Saturation[sunk]",
            additionalRange: 0..<0
        )
        let fused = Node(
            id: sharpenNode.id,
            kind: sharpenNode.kind,
            inputs: sharpenNode.inputs,
            outputSpec: sharpenNode.outputSpec,
            isFinal: sharpenNode.isFinal,
            debugLabel: "Sharpen+Saturation",
            tailSinkedBody: sunk
        )

        let result = try MetalSourceBuilder.build(for: fused)

        XCTAssertEqual(result.bindings.uniformBufferCount, 2,
                       "Tail fusion adds one uniform slot for P_tail")
        XCTAssertEqual(result.bindings.auxiliaryTextureSlotCount, 0)
        XCTAssertTrue(result.source.contains("DCRRawSourceTap tap{input};"),
                      "No head fusion → kernel uses the raw source tap")
        XCTAssertTrue(result.source.contains("uTail [[buffer(1)]]"),
                      "P_tail's uniform must bind at buffer(1) (no head occupies the slot)")
        XCTAssertTrue(result.source.contains("rgb = \(pBody.functionName)(rgb, uTail);"),
                      "Tail body call must appear between N's body and output.write")
        XCTAssertTrue(result.source.contains("\(nBody.functionName)(c.rgb, u0, gid, tap)"))

        let library = try device.makeLibrary(source: result.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: result.functionName))
    }

    /// Combined head + tail fusion. Slot ordering is fixed: head
    /// always lives at `buffer(1)` (so the binding logic in
    /// `ComputeBackend.bindUniforms` can rely on a stable layout)
    /// and tail moves to `buffer(2)` when both partners are present.
    func testHeadAndTailFusionAllocateDistinctSlotsAndCompile() throws {
        let sharpen = SharpenFilter(amount: 1.0, stepPixels: 1)
        let exposure = ExposureFilter(exposure: 25)
        let saturation = SaturationFilter(saturation: 1.2)
        let sharpenNode = loweredSingleNode(for: .single(sharpen))
        let exposureNode = loweredSingleNode(for: .single(exposure))
        let satNode = loweredSingleNode(for: .single(saturation))
        guard
            case let .pixelLocal(headBody, headUniforms, _, _) = exposureNode.kind,
            case let .pixelLocal(tailBody, tailUniforms, _, _) = satNode.kind
        else {
            return XCTFail("Lowering produced unexpected pixelLocal kinds")
        }

        let head = FusedClusterMember(
            body: headBody,
            uniforms: headUniforms,
            debugLabel: "Exposure[inlined]",
            additionalRange: 0..<0
        )
        let tail = FusedClusterMember(
            body: tailBody,
            uniforms: tailUniforms,
            debugLabel: "Saturation[sunk]",
            additionalRange: 0..<0
        )
        let fused = Node(
            id: sharpenNode.id,
            kind: sharpenNode.kind,
            inputs: sharpenNode.inputs,
            outputSpec: sharpenNode.outputSpec,
            isFinal: sharpenNode.isFinal,
            debugLabel: "Sharpen[inline:Exposure]+Saturation",
            inlinedBodyBeforeSample: head,
            tailSinkedBody: tail
        )

        let result = try MetalSourceBuilder.build(for: fused)

        XCTAssertEqual(result.bindings.uniformBufferCount, 3)
        XCTAssertTrue(result.source.contains("uHead [[buffer(1)]]"))
        XCTAssertTrue(result.source.contains("uTail [[buffer(2)]]"))
        XCTAssertTrue(result.source.contains("DCRFusedTap_\(headBody.functionName) tap{input, uHead};"))
        XCTAssertTrue(result.source.contains("rgb = \(tailBody.functionName)(rgb, uTail);"))

        let library = try device.makeLibrary(source: result.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: result.functionName))
    }

    /// Function-name hash must distinguish (a) un-fused, (b) head-only,
    /// (c) tail-only, (d) head+tail variants — otherwise the PSO cache
    /// would alias structurally-different kernels under one entry.
    func testHeadAndTailFusionFunctionNamesAreAllDistinct() throws {
        let sharpen = SharpenFilter(amount: 1.0, stepPixels: 1)
        let exposure = ExposureFilter(exposure: 25)
        let saturation = SaturationFilter(saturation: 1.2)
        let sharpenNode = loweredSingleNode(for: .single(sharpen))
        let exposureNode = loweredSingleNode(for: .single(exposure))
        let satNode = loweredSingleNode(for: .single(saturation))
        guard
            case let .pixelLocal(headBody, headUniforms, _, _) = exposureNode.kind,
            case let .pixelLocal(tailBody, tailUniforms, _, _) = satNode.kind
        else {
            return XCTFail("Lowering produced unexpected pixelLocal kinds")
        }

        let head = FusedClusterMember(
            body: headBody,
            uniforms: headUniforms,
            debugLabel: "Exposure",
            additionalRange: 0..<0
        )
        let tail = FusedClusterMember(
            body: tailBody,
            uniforms: tailUniforms,
            debugLabel: "Saturation",
            additionalRange: 0..<0
        )

        let plain = sharpenNode
        let withHead = Node(
            id: sharpenNode.id, kind: sharpenNode.kind,
            inputs: sharpenNode.inputs, outputSpec: sharpenNode.outputSpec,
            isFinal: sharpenNode.isFinal, debugLabel: "h",
            inlinedBodyBeforeSample: head
        )
        let withTail = Node(
            id: sharpenNode.id, kind: sharpenNode.kind,
            inputs: sharpenNode.inputs, outputSpec: sharpenNode.outputSpec,
            isFinal: sharpenNode.isFinal, debugLabel: "t",
            tailSinkedBody: tail
        )
        let withBoth = Node(
            id: sharpenNode.id, kind: sharpenNode.kind,
            inputs: sharpenNode.inputs, outputSpec: sharpenNode.outputSpec,
            isFinal: sharpenNode.isFinal, debugLabel: "ht",
            inlinedBodyBeforeSample: head, tailSinkedBody: tail
        )

        let names = [
            try MetalSourceBuilder.build(for: plain).functionName,
            try MetalSourceBuilder.build(for: withHead).functionName,
            try MetalSourceBuilder.build(for: withTail).functionName,
            try MetalSourceBuilder.build(for: withBoth).functionName,
        ]
        XCTAssertEqual(Set(names).count, 4,
                       "Each fusion arrangement must hash to a distinct kernel name")
    }

    // MARK: - Helpers

    private func loweredSingleNode(for step: AnyFilter) -> Node {
        let source = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        let graph = Lowering.lower([step], source: source)!
        XCTAssertEqual(graph.nodes.count, 1, "Test fixture expects single-node lowering")
        return graph.nodes[0]
    }
}
