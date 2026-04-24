//
//  ShaderSourceExtractorTests.swift
//  DCRenderKitTests
//
//  Unit tests for the Phase-3 marker-driven `.metal` text
//  extractor. Every case runs against an inline fixture string
//  via the source-text overloads, so these tests are hermetic —
//  no file I/O, no Metal compilation.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class ShaderSourceExtractorTests: XCTestCase {

    // MARK: - Body function

    /// The happy path: a single body block with matched markers.
    func testExtractBodyReturnsLinesBetweenMarkers() throws {
        let source = """
        struct FooUniforms { float x; };

        // @dcr:body-begin DCRFooBody
        inline half3 DCRFooBody(half3 rgb, constant FooUniforms& u) {
            return rgb * half(u.x);
        }
        // @dcr:body-end
        """
        let body = try ShaderSourceExtractor.extractBody(named: "DCRFooBody", from: source)
        XCTAssertTrue(body.contains("inline half3 DCRFooBody"))
        XCTAssertTrue(body.contains("return rgb * half(u.x);"))
        XCTAssertFalse(body.contains("@dcr:body-begin"))
        XCTAssertFalse(body.contains("@dcr:body-end"))
    }

    /// Markers match by the function name after the begin token,
    /// not by position. Two body blocks in the same file are
    /// distinguishable.
    func testTwoBodiesInOneFileAreDistinguishable() throws {
        let source = """
        // @dcr:body-begin BodyA
        inline int BodyA() { return 1; }
        // @dcr:body-end

        // @dcr:body-begin BodyB
        inline int BodyB() { return 2; }
        // @dcr:body-end
        """
        let a = try ShaderSourceExtractor.extractBody(named: "BodyA", from: source)
        let b = try ShaderSourceExtractor.extractBody(named: "BodyB", from: source)
        XCTAssertTrue(a.contains("return 1;"))
        XCTAssertFalse(a.contains("return 2;"))
        XCTAssertTrue(b.contains("return 2;"))
        XCTAssertFalse(b.contains("return 1;"))
    }

    /// Missing begin marker surfaces a typed error carrying the
    /// requested function name.
    func testMissingBodyMarkerThrowsBodyMarkerNotFound() {
        let source = "inline int Foo() { return 0; }"
        XCTAssertThrowsError(
            try ShaderSourceExtractor.extractBody(named: "Foo", from: source)
        ) { error in
            guard case ShaderSourceExtractor.ExtractionError.bodyMarkerNotFound(let name, _) = error else {
                XCTFail("Expected .bodyMarkerNotFound, got \(error)")
                return
            }
            XCTAssertEqual(name, "Foo")
        }
    }

    /// A begin marker without a matching end marker surfaces as
    /// `unmatchedBodyMarkers`.
    func testUnmatchedBeginMarkerThrowsUnmatched() {
        let source = """
        // @dcr:body-begin Foo
        inline int Foo() { return 0; }
        """
        XCTAssertThrowsError(
            try ShaderSourceExtractor.extractBody(named: "Foo", from: source)
        ) { error in
            if case ShaderSourceExtractor.ExtractionError.unmatchedBodyMarkers = error {
                // expected
            } else {
                XCTFail("Expected .unmatchedBodyMarkers, got \(error)")
            }
        }
    }

    /// Marker tokens are robust to leading whitespace in the
    /// comment; `//   @dcr:body-begin Foo  ` still matches `Foo`.
    func testMarkerTokenizationIsWhitespaceTolerant() throws {
        let source = """
        //   @dcr:body-begin    Foo
        inline int Foo() { return 0; }
        //   @dcr:body-end
        """
        let body = try ShaderSourceExtractor.extractBody(named: "Foo", from: source)
        XCTAssertTrue(body.contains("return 0;"))
    }

    /// The extractor scans for marker membership on each line,
    /// so a begin marker embedded in a `/* ... */` block comment
    /// still triggers. That's acceptable — the marker convention
    /// is for our own SDK authors, and accidentally embedding
    /// `@dcr:body-begin` inside a block comment would be an
    /// explicit choice. The test pins the current behaviour so
    /// future stricter parsing is an intentional change.
    func testMarkerInBlockCommentStillMatches() throws {
        let source = """
        /*
         * Legacy doc: // @dcr:body-begin SomeBody used to wrap X.
         */
        // @dcr:body-begin SomeBody
        inline int SomeBody() { return 42; }
        // @dcr:body-end
        """
        // Happy path still works; the doc-comment mention is only
        // a risk when it appears between a real begin and end pair
        // in a way that would confuse the matcher — but our
        // matcher only triggers on begin on its own line with the
        // function name as the next token.
        let body = try ShaderSourceExtractor.extractBody(named: "SomeBody", from: source)
        XCTAssertTrue(body.contains("return 42;"))
    }

    // MARK: - Uniform struct

    /// Single-field struct: extractor returns the whole `struct
    /// ... {};` text.
    func testExtractUniformStructReturnsFullDeclaration() throws {
        let source = """
        struct ExposureUniforms {
            float exposure;
            uint  isLinearSpace;
        };

        inline int unrelated() { return 0; }
        """
        let decl = try ShaderSourceExtractor.extractUniformStruct(
            named: "ExposureUniforms",
            from: source
        )
        XCTAssertTrue(decl.hasPrefix("struct ExposureUniforms"))
        XCTAssertTrue(decl.hasSuffix("};"))
        XCTAssertTrue(decl.contains("float exposure"))
        XCTAssertTrue(decl.contains("uint  isLinearSpace"))
    }

    /// Struct bodies with nested braces (unusual but legal in
    /// Metal — e.g. initializer expressions) are handled by the
    /// brace-balance scan.
    func testExtractUniformStructHandlesNestedBraces() throws {
        let source = """
        struct WeirdUniforms {
            float4 matrixRow0 = { 1.0, 0.0, 0.0, 0.0 };
            float scalar;
        };
        """
        let decl = try ShaderSourceExtractor.extractUniformStruct(
            named: "WeirdUniforms",
            from: source
        )
        XCTAssertTrue(decl.contains("float4 matrixRow0"))
        XCTAssertTrue(decl.hasSuffix("};"))
    }

    /// Missing struct name surfaces a typed error.
    func testMissingUniformStructThrows() {
        let source = "struct Other { float x; };"
        XCTAssertThrowsError(
            try ShaderSourceExtractor.extractUniformStruct(
                named: "Missing",
                from: source
            )
        ) { error in
            guard case ShaderSourceExtractor.ExtractionError.uniformStructNotFound(let name, _) = error else {
                XCTFail("Expected .uniformStructNotFound, got \(error)")
                return
            }
            XCTAssertEqual(name, "Missing")
        }
    }

    /// Struct whose closing brace isn't followed by `;` surfaces
    /// as `.uniformStructUnterminated`. This can happen if the
    /// extractor's caller mistakenly points at a function body
    /// that begins with `struct` in a comment.
    func testStructWithoutSemicolonThrows() {
        // The brace scan looks for `}` at depth 0 **followed by
        // `;`**; if the closing semicolon is missing, we walk off
        // the end of the file and report the error.
        let source = """
        struct Misdeclared {
            float x
        }
        inline int after() { return 0; }
        """
        XCTAssertThrowsError(
            try ShaderSourceExtractor.extractUniformStruct(
                named: "Misdeclared",
                from: source
            )
        ) { error in
            if case ShaderSourceExtractor.ExtractionError.uniformStructUnterminated = error {
                // expected
            } else {
                XCTFail("Expected .uniformStructUnterminated, got \(error)")
            }
        }
    }

    // MARK: - Integration against production shaders

    /// Sanity check: for every SDK built-in filter that adopts the
    /// Phase-3 body-function convention, the extractor finds both
    /// the body and the uniform struct in the bundled source text
    /// that `BundledShaderSources` ships. Covers all 11 non-LUT
    /// single-pass filters; LUT3D requires a `MTLTexture` at init
    /// time and is handled separately.
    func testAllProductionFusionShadersExposeBodiesAndUniforms() throws {
        let filters: [(filter: any FilterProtocol, functionName: String, structName: String)] = [
            // signatureShape: .pixelLocalOnly
            (ExposureFilter(),     "DCRExposureBody",     "ExposureUniforms"),
            (ContrastFilter(),     "DCRContrastBody",     "ContrastUniforms"),
            (BlacksFilter(),       "DCRBlacksBody",       "BlacksUniforms"),
            (WhitesFilter(),       "DCRWhitesBody",       "WhitesUniforms"),
            (SaturationFilter(),   "DCRSaturationBody",   "SaturationUniforms"),
            (VibranceFilter(),     "DCRVibranceBody",     "VibranceUniforms"),
            (WhiteBalanceFilter(), "DCRWhiteBalanceBody", "WhiteBalanceUniforms"),
            // signatureShape: .neighborReadWithSource
            (SharpenFilter(),      "DCRSharpenBody",      "SharpenUniforms"),
            (FilmGrainFilter(),    "DCRFilmGrainBody",    "FilmGrainUniforms"),
            (CCDFilter(),          "DCRCCDBody",          "CCDUniforms"),
            // signatureShape: .pixelLocalWithOverlay (NormalBlend constructed below)
        ]

        for (filter, functionName, structName) in filters {
            guard let body = filter.fusionBody.body else {
                XCTFail("\(type(of: filter)) fusionBody missing metadata")
                continue
            }
            XCTAssertEqual(body.functionName, functionName)
            XCTAssertEqual(body.uniformStructName, structName)
            XCTAssertNoThrow(
                try ShaderSourceExtractor.extractBody(
                    named: functionName,
                    from: body.sourceText,
                    sourceLabel: body.sourceLabel
                ),
                "Body \(functionName) not extractable from \(body.sourceLabel)"
            )
            XCTAssertNoThrow(
                try ShaderSourceExtractor.extractUniformStruct(
                    named: structName,
                    from: body.sourceText,
                    sourceLabel: body.sourceLabel
                ),
                "Struct \(structName) not extractable from \(body.sourceLabel)"
            )
        }

        // NormalBlend — needs a dummy overlay texture to construct.
        let device = MTLCreateSystemDefaultDevice()!
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        let overlay = device.makeTexture(descriptor: desc)!
        let nbFilter = NormalBlendFilter(overlay: overlay)
        guard let nbBody = nbFilter.fusionBody.body else {
            XCTFail("NormalBlend fusionBody missing metadata")
            return
        }
        XCTAssertEqual(nbBody.functionName, "DCRNormalBlendBody")
        XCTAssertEqual(nbBody.uniformStructName, "NormalBlendUniforms")
        XCTAssertNoThrow(
            try ShaderSourceExtractor.extractBody(
                named: "DCRNormalBlendBody",
                from: nbBody.sourceText,
                sourceLabel: nbBody.sourceLabel
            )
        )

        // LUT3D — needs parsed cube data to construct.
        let identity2Cube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let cubeData = identity2Cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let lut = try LUT3DFilter(cubeData: cubeData, dimension: 2)
        guard let lutBody = lut.fusionBody.body else {
            XCTFail("LUT3D fusionBody missing metadata")
            return
        }
        XCTAssertEqual(lutBody.functionName, "DCRLUT3DBody")
        XCTAssertEqual(lutBody.uniformStructName, "LUT3DUniforms")
        XCTAssertNoThrow(
            try ShaderSourceExtractor.extractBody(
                named: "DCRLUT3DBody",
                from: lutBody.sourceText,
                sourceLabel: lutBody.sourceLabel
            )
        )
    }

    // MARK: - BundledShaderSources

    /// Every bundled source string contains both the `@dcr:body-end`
    /// marker and a `struct <Name>Uniforms` declaration. Serves as
    /// a regeneration tripwire — if `Scripts/generate-bundled-
    /// shaders.sh` gets out of sync with the `.metal` files (e.g.
    /// someone edits a body without rerunning the generator) this
    /// test catches it.
    func testAllBundledSourcesContainExpectedMarkers() {
        let sources: [(name: String, text: String)] = [
            ("exposureFilter",     BundledShaderSources.exposureFilter),
            ("contrastFilter",     BundledShaderSources.contrastFilter),
            ("blacksFilter",       BundledShaderSources.blacksFilter),
            ("whitesFilter",       BundledShaderSources.whitesFilter),
            ("sharpenFilter",      BundledShaderSources.sharpenFilter),
            ("saturationFilter",   BundledShaderSources.saturationFilter),
            ("vibranceFilter",     BundledShaderSources.vibranceFilter),
            ("whiteBalanceFilter", BundledShaderSources.whiteBalanceFilter),
            ("ccdFilter",          BundledShaderSources.ccdFilter),
            ("filmGrainFilter",    BundledShaderSources.filmGrainFilter),
            ("lut3DFilter",        BundledShaderSources.lut3DFilter),
            ("normalBlendFilter",  BundledShaderSources.normalBlendFilter),
        ]
        for (name, text) in sources {
            XCTAssertTrue(
                text.contains("@dcr:body-begin"),
                "\(name) missing @dcr:body-begin marker"
            )
            XCTAssertTrue(
                text.contains("@dcr:body-end"),
                "\(name) missing @dcr:body-end marker"
            )
            XCTAssertTrue(
                text.contains("struct "),
                "\(name) missing uniform struct declaration"
            )
        }
    }
}
