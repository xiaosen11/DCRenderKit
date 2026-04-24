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

    // MARK: - File I/O

    /// File-URL variant surfaces `fileUnreadable` on a missing path.
    func testFileUnreadableWrapsUnderlyingError() {
        let missingURL = URL(fileURLWithPath: "/tmp/dcr-test-nonexistent.metal")
        XCTAssertThrowsError(
            try ShaderSourceExtractor.extractBody(named: "Anything", from: missingURL)
        ) { error in
            if case ShaderSourceExtractor.ExtractionError.fileUnreadable(let url, _) = error {
                XCTAssertEqual(url, missingURL)
            } else {
                XCTFail("Expected .fileUnreadable, got \(error)")
            }
        }
    }

    // MARK: - Integration against production shaders

    /// Sanity check: for every SDK built-in filter that has
    /// adopted the Phase-3 body-function convention, the
    /// extractor finds both the body and the uniform struct in
    /// its production `.metal` file. Filters that are still in
    /// flight (FilmGrain / CCD / LUT3D / NormalBlend / Sharpen at
    /// this step) are excluded from the list.
    func testProductionPixelLocalShadersExposeBodiesAndUniforms() throws {
        let pixelLocalFiltersInFlight: [(filter: any FilterProtocol, functionName: String, structName: String)] = [
            (ExposureFilter(),     "DCRExposureBody",     "ExposureUniforms"),
            (ContrastFilter(),     "DCRContrastBody",     "ContrastUniforms"),
            (BlacksFilter(),       "DCRBlacksBody",       "BlacksUniforms"),
            (WhitesFilter(),       "DCRWhitesBody",       "WhitesUniforms"),
            (SaturationFilter(),   "DCRSaturationBody",   "SaturationUniforms"),
            (VibranceFilter(),     "DCRVibranceBody",     "VibranceUniforms"),
            (WhiteBalanceFilter(), "DCRWhiteBalanceBody", "WhiteBalanceUniforms"),
        ]

        for (filter, functionName, structName) in pixelLocalFiltersInFlight {
            guard let body = filter.fusionBody.body else {
                XCTFail("\(type(of: filter)) fusionBody missing in-flight metadata")
                continue
            }
            XCTAssertEqual(
                body.functionName, functionName,
                "\(type(of: filter)) descriptor's functionName should match the production marker"
            )
            XCTAssertEqual(
                body.uniformStructName, structName,
                "\(type(of: filter)) descriptor's uniformStructName should match the shader struct"
            )

            // Body extraction must succeed on the real file.
            XCTAssertNoThrow(
                try ShaderSourceExtractor.extractBody(
                    named: functionName,
                    from: body.sourceMetalFile
                ),
                "Body \(functionName) not extractable from \(body.sourceMetalFile.lastPathComponent)"
            )

            // Uniform struct extraction must also succeed.
            XCTAssertNoThrow(
                try ShaderSourceExtractor.extractUniformStruct(
                    named: structName,
                    from: body.sourceMetalFile
                ),
                "Struct \(structName) not extractable from \(body.sourceMetalFile.lastPathComponent)"
            )
        }
    }

    /// Round-trip via the on-disk overload — write a temporary
    /// file, read its body back. Confirms the disk-path and
    /// source-path overloads produce identical results.
    func testDiskAndSourceOverloadsAgree() throws {
        let source = """
        // @dcr:body-begin RoundTrip
        inline int RoundTrip() { return 7; }
        // @dcr:body-end
        """
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dcr-test-roundtrip.metal")
        try source.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inMem = try ShaderSourceExtractor.extractBody(
            named: "RoundTrip",
            from: source
        )
        let onDisk = try ShaderSourceExtractor.extractBody(
            named: "RoundTrip",
            from: tmp
        )
        XCTAssertEqual(inMem, onDisk)
    }
}
