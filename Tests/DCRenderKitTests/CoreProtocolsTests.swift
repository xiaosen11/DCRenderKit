//
//  CoreProtocolsTests.swift
//  DCRenderKitTests
//
//  Smoke tests for core protocols. These verify the protocol contracts
//  compile and that basic semantic behavior holds (default implementations,
//  resolution logic, uniform copying).
//

import XCTest
@testable import DCRenderKit
import Metal

final class CoreProtocolsTests: XCTestCase {

    // MARK: - ModifierEnum

    func testModifierEnumDescription() {
        XCTAssertEqual(
            ModifierEnum.compute(kernel: "foo").description,
            "compute(foo)"
        )
        XCTAssertEqual(
            ModifierEnum.render(vertex: "v", fragment: "f").description,
            "render(v,f)"
        )
        XCTAssertEqual(ModifierEnum.blit.description, "blit")
        XCTAssertEqual(
            ModifierEnum.mps(kernelName: "gaussian").description,
            "mps(gaussian)"
        )
    }

    // MARK: - FuseGroup

    func testFuseGroupCases() {
        XCTAssertEqual(FuseGroup.allCases.count, 2)
        XCTAssertTrue(FuseGroup.allCases.contains(.toneAdjustment))
        XCTAssertTrue(FuseGroup.allCases.contains(.colorGrading))
    }

    // MARK: - FilterProtocol defaults

    func testFilterProtocolDefaults() {
        struct MinimalFilter: FilterProtocol {
            var modifier: ModifierEnum { .compute(kernel: "noop") }
        }

        let filter = MinimalFilter()
        XCTAssertEqual(filter.uniforms.byteCount, 0)
        XCTAssertTrue(filter.additionalInputs.isEmpty)
        XCTAssertNil(MinimalFilter.fuseGroup)
    }

    // MARK: - FilterUniforms

    func testFilterUniformsEmpty() {
        let empty = FilterUniforms.empty
        XCTAssertEqual(empty.byteCount, 0)
    }

    func testFilterUniformsTypedCopy() {
        struct MyUniforms {
            var exposure: Float
            var contrast: Float
        }
        let u = FilterUniforms(MyUniforms(exposure: 0.5, contrast: 1.5))
        XCTAssertEqual(u.byteCount, MemoryLayout<MyUniforms>.stride)

        // Allocate matching buffer, copy, verify bytes.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: u.byteCount,
            alignment: MemoryLayout<MyUniforms>.alignment
        )
        defer { buffer.deallocate() }
        u.copyBytes(buffer)
        let readBack = buffer.assumingMemoryBound(to: MyUniforms.self).pointee
        XCTAssertEqual(readBack.exposure, 0.5, accuracy: 1e-6)
        XCTAssertEqual(readBack.contrast, 1.5, accuracy: 1e-6)
    }

    // MARK: - TextureInfo

    func testTextureInfoShortSide() {
        let info = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba8Unorm)
        XCTAssertEqual(info.shortSide, 1080)
        XCTAssertEqual(info.longSide, 1920)
    }

    // MARK: - TextureSpec.resolve

    func testTextureSpecSameAsSource() {
        let source = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba8Unorm)
        let resolved = TextureSpec.sameAsSource.resolve(source: source, resolvedPeers: [:])
        XCTAssertEqual(resolved, source)
    }

    func testTextureSpecScaled() {
        let source = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba8Unorm)
        let half = TextureSpec.scaled(factor: 0.5).resolve(source: source, resolvedPeers: [:])
        XCTAssertEqual(half?.width, 960)
        XCTAssertEqual(half?.height, 540)
        XCTAssertEqual(half?.pixelFormat, .rgba8Unorm)
    }

    func testTextureSpecScaledEdgeCases() {
        let source = TextureInfo(width: 3, height: 3, pixelFormat: .rgba8Unorm)
        // Rounds to at least 1 pixel.
        let tiny = TextureSpec.scaled(factor: 0.1).resolve(source: source, resolvedPeers: [:])
        XCTAssertEqual(tiny?.width, 1)
        XCTAssertEqual(tiny?.height, 1)

        // Zero or negative factor is invalid.
        let invalid = TextureSpec.scaled(factor: 0).resolve(source: source, resolvedPeers: [:])
        XCTAssertNil(invalid)
    }

    func testTextureSpecExplicit() {
        let source = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba8Unorm)
        let spec = TextureSpec.explicit(width: 512, height: 256)
        let resolved = spec.resolve(source: source, resolvedPeers: [:])
        XCTAssertEqual(resolved?.width, 512)
        XCTAssertEqual(resolved?.height, 256)
        // Pixel format inherits from source.
        XCTAssertEqual(resolved?.pixelFormat, .rgba8Unorm)

        let invalid = TextureSpec.explicit(width: 0, height: 0).resolve(source: source, resolvedPeers: [:])
        XCTAssertNil(invalid)
    }

    func testTextureSpecMatchShortSide() {
        let landscape = TextureInfo(width: 4000, height: 3000, pixelFormat: .rgba16Float)
        let target = TextureSpec.matchShortSide(1000)
        let resolved = target.resolve(source: landscape, resolvedPeers: [:])
        // shortSide 3000 → 1000; scale = 1/3; width 4000*1/3 ≈ 1333
        XCTAssertEqual(resolved?.height, 1000)
        XCTAssertEqual(resolved?.width, 1333)
    }

    func testTextureSpecMatchingPeer() {
        let source = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba8Unorm)
        let peer = TextureInfo(width: 480, height: 270, pixelFormat: .rgba16Float)
        let spec = TextureSpec.matching(passName: "Q")
        let resolved = spec.resolve(source: source, resolvedPeers: ["Q": peer])
        XCTAssertEqual(resolved, peer)

        // Missing peer returns nil.
        let missing = spec.resolve(source: source, resolvedPeers: [:])
        XCTAssertNil(missing)
    }

    // MARK: - Pass factories

    func testPassComputeFactory() {
        let p = Pass.compute(
            name: "L1",
            kernel: "down2",
            inputs: [.source],
            output: .scaled(factor: 0.5)
        )
        XCTAssertEqual(p.name, "L1")
        XCTAssertEqual(p.modifier.description, "compute(down2)")
        XCTAssertEqual(p.inputs.count, 1)
        XCTAssertFalse(p.isFinal)
    }

    func testPassFinalFactory() {
        let p = Pass.final(
            kernel: "compose",
            inputs: [.source, .named("L1")]
        )
        XCTAssertTrue(p.isFinal)
        XCTAssertEqual(p.inputs.count, 2)
    }

    // MARK: - MultiPassFilter declarative graph

    func testMultiPassFilterEmptyPassGraph() {
        struct NoopFilter: MultiPassFilter {
            func passes(input: TextureInfo) -> [Pass] { [] }
        }
        let filter = NoopFilter()
        let info = TextureInfo(width: 100, height: 100, pixelFormat: .rgba8Unorm)
        XCTAssertTrue(filter.passes(input: info).isEmpty)
    }

    func testMultiPassFilterAdaptivePassCount() {
        // Simulates SoftGlow-style adaptive level selection.
        struct AdaptiveFilter: MultiPassFilter {
            func passes(input: TextureInfo) -> [Pass] {
                let shortSide = input.shortSide
                let levels = max(3, Int(log2(Float(shortSide) / 135.0)))
                return (0..<levels).map {
                    Pass.compute(
                        name: "L\($0)",
                        kernel: "down",
                        inputs: [.source],
                        output: .scaled(factor: Float(pow(0.5, Double($0))))
                    )
                }
            }
        }
        let filter = AdaptiveFilter()
        let hd = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba16Float)
        XCTAssertEqual(filter.passes(input: hd).count, 3)  // log2(1080/135)=3.0

        let uhd = TextureInfo(width: 3840, height: 2160, pixelFormat: .rgba16Float)
        XCTAssertEqual(filter.passes(input: uhd).count, 4)  // log2(2160/135)=4.0
    }

    // MARK: - PipelineError

    func testPipelineErrorDomainGrouping() {
        let err: PipelineError = .device(.noMetalDevice)
        XCTAssertNotNil(err.errorDescription)

        switch err {
        case .device(let d):
            XCTAssertEqual("\(d)", "No Metal-capable device found")
        default:
            XCTFail("Expected .device error")
        }
    }

    func testPipelineErrorDescriptions() {
        // Verify each domain has a meaningful description.
        let cases: [PipelineError] = [
            .device(.noMetalDevice),
            .texture(.dimensionsInvalid(width: 0, height: 100, reason: "zero width")),
            .pipelineState(.functionNotFound(name: "foo")),
            .filter(.missingRequiredInput(name: "mask")),
            .resource(.texturePoolExhausted(requestedBytes: 1024)),
        ]
        for err in cases {
            XCTAssertNotNil(err.errorDescription)
            XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
        }
    }

    func testFilterErrorParameterOutOfRange() {
        let err = FilterError.parameterOutOfRange(name: "exposure", value: 500, range: -100...100)
        XCTAssertTrue("\(err)".contains("exposure"))
        XCTAssertTrue("\(err)".contains("500"))
    }
}
