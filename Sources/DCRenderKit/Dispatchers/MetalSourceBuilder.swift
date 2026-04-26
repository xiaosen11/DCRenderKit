//
//  MetalSourceBuilder.swift
//  DCRenderKit
//
//  Phase-3 step 3 runtime code generator. Turns a `PipelineGraph.Node`
//  into the complete Metal source for an uber kernel that the
//  compute backend will compile and cache.
//
//  Step 3a supports the simplest shape: a single `.pixelLocal` node
//  with signature `.pixelLocalOnly` — the seven pure per-pixel
//  filters (Exposure, Contrast, Blacks, Whites, Saturation, Vibrance,
//  WhiteBalance). Later steps extend this to `.fusedPixelLocalCluster`
//  members and to the four richer signature shapes.
//

import Foundation

@available(iOS 18.0, *)
internal enum MetalSourceBuilder {

    /// Result of a successful source build. The `source` is ready for
    /// `MTLDevice.makeLibrary(source:options:)`; the kernel named
    /// `functionName` is the entry point; `bindings` describes how
    /// the dispatcher should wire up the command encoder.
    struct BuildResult: Sendable {
        let source: String
        let functionName: String
        let bindings: Bindings
    }

    /// Binding plan extracted from the Node. Texture slot 0 is the
    /// output, slot 1 is the primary source; `uniformBufferCount`
    /// gives the number of `buffer(0..N-1)` slots the uber kernel
    /// expects uniform payloads at. Future shapes add auxiliary
    /// texture slots (tracked here as `auxiliaryTextureSlotCount`).
    struct Bindings: Sendable {
        let uniformBufferCount: Int
        let auxiliaryTextureSlotCount: Int
    }

    /// Errors surfaced by the builder. Each is recoverable at the
    /// compute-backend layer — if a node can't be code-generated,
    /// the backend falls back to dispatching the node's standalone
    /// production kernel (if one exists) or to per-node execution
    /// of a simpler graph.
    enum BuildError: Error, CustomStringConvertible {
        case unsupportedNodeKind(String)
        case unsupportedSignatureShape(FusionBodySignatureShape)
        case unsupportedBodyHelpers(functionName: String)
        case extractionFailed(Error)

        var description: String {
            switch self {
            case .unsupportedNodeKind(let kind):
                return "MetalSourceBuilder: node kind \(kind) is not supported by Phase-3 step 3a"
            case .unsupportedSignatureShape(let shape):
                return "MetalSourceBuilder: signature shape \(shape) is not supported by Phase-3 step 3a"
            case .unsupportedBodyHelpers(let name):
                return "MetalSourceBuilder: no helper injection rule for body \(name)"
            case .extractionFailed(let underlying):
                return "MetalSourceBuilder: shader extraction failed — \(underlying)"
            }
        }
    }

    // MARK: - Entry point

    /// Build an uber-kernel Metal source for the given Node.
    /// Currently supports:
    ///
    ///   · `.pixelLocal` with signature `.pixelLocalOnly` (Step 3a)
    ///   · `.fusedPixelLocalCluster` where every member has
    ///     signature `.pixelLocalOnly` (Step 3b)
    ///
    /// Other node kinds and richer signature shapes surface as
    /// `.unsupportedNodeKind` / `.unsupportedSignatureShape` and
    /// extend in later Phase-3 steps.
    ///
    /// Guard order matters for diagnostic clarity: the signature-
    /// shape check is evaluated before the "no auxiliary inputs"
    /// precondition so consumers hitting LUT3D / NormalBlend /
    /// neighbour-read filters see the informative shape error
    /// rather than the structural "kind" error.
    static func build(for node: Node) throws -> BuildResult {
        switch node.kind {
        case let .pixelLocal(body, _, _, additionalAux):
            switch body.signatureShape {
            case .pixelLocalOnly:
                guard additionalAux.isEmpty else {
                    throw BuildError.unsupportedNodeKind(
                        "pixelLocalOnly shape should not carry additionalNodeInputs"
                    )
                }
                return try buildPixelLocalOnly(body: body)

            case .pixelLocalWithLUT3D:
                return try buildPixelLocalWithLUT3D(body: body)

            case .pixelLocalWithOverlay:
                return try buildPixelLocalWithOverlay(body: body)

            case .pixelLocalWithGid:
                // No built-in filter uses this shape yet; kept in
                // the enum as a reserved slot. Surface the miss
                // instead of generating untested source.
                throw BuildError.unsupportedSignatureShape(body.signatureShape)
            case .neighborReadWithSource:
                // `.pixelLocal` with `.neighborReadWithSource`
                // shape is a graph-construction error — the shape
                // belongs on `.neighborRead` nodes.
                throw BuildError.unsupportedNodeKind(
                    ".pixelLocal node declared a neighborReadWithSource shape"
                )
            }

        case let .neighborRead(body, _, _, _):
            switch body.signatureShape {
            case .neighborReadWithSource:
                return try buildNeighborReadWithSource(body: body)
            default:
                throw BuildError.unsupportedSignatureShape(body.signatureShape)
            }

        case let .fusedPixelLocalCluster(members, wantsLinear, aux):
            // Every member must use the `.pixelLocalOnly` shape —
            // mixed-shape clusters need the richer codegen that
            // lands in later steps.
            for member in members {
                guard member.body.signatureShape == .pixelLocalOnly else {
                    throw BuildError.unsupportedSignatureShape(member.body.signatureShape)
                }
            }
            guard aux.isEmpty else {
                throw BuildError.unsupportedNodeKind(
                    "pixelLocalOnly cluster should not carry additionalNodeInputs"
                )
            }
            return try buildFusedPixelLocalCluster(
                members: members,
                wantsLinearInput: wantsLinear
            )

        default:
            throw BuildError.unsupportedNodeKind(String(describing: node.kind))
        }
    }

    // MARK: - Shape: pixelLocalOnly

    /// Build an uber kernel for a single pure pixel-local body.
    ///
    /// Generated structure (whitespace trimmed in actual output):
    ///
    ///     #include <metal_stdlib>
    ///     using namespace metal;
    ///
    ///     {helpers — e.g. canonical SRGBGamma + filter-private block}
    ///
    ///     {uniform struct declaration, verbatim from the filter's .metal}
    ///
    ///     {body function, verbatim from the filter's .metal}
    ///
    ///     kernel void DCR_Uber_{hash}(
    ///         texture2d<half, access::write> output [[texture(0)]],
    ///         texture2d<half, access::read>  input  [[texture(1)]],
    ///         constant {UniformStruct}& u0          [[buffer(0)]],
    ///         uint2 gid [[thread_position_in_grid]])
    ///     {
    ///         if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    ///         const half4 c = input.read(gid);
    ///         half3 rgb = c.rgb;
    ///         rgb = {BodyFunction}(rgb, u0);
    ///         output.write(half4(rgb, c.a), gid);
    ///     }
    private static func buildPixelLocalOnly(body: FusionBody) throws -> BuildResult {
        // Helper text blocks for this body. Empty result means the
        // builder doesn't know how to supply dependencies for this
        // filter — surface it rather than produce a source that
        // fails to compile at runtime.
        let helpers = FusionHelperSource.helpersForBody(named: body.functionName)
        guard !helpers.isEmpty else {
            throw BuildError.unsupportedBodyHelpers(functionName: body.functionName)
        }

        // Extract the uniform struct and body-function texts from
        // the filter's bundled source string.
        let uniformStructText: String
        let bodyText: String
        do {
            uniformStructText = try ShaderSourceExtractor.extractUniformStruct(
                named: body.uniformStructName,
                from: body.sourceText,
                sourceLabel: body.sourceLabel
            )
            bodyText = try ShaderSourceExtractor.extractBody(
                named: body.functionName,
                from: body.sourceText,
                sourceLabel: body.sourceLabel
            )
        } catch {
            throw BuildError.extractionFailed(error)
        }

        let functionName = uberFunctionName(for: body)
        let joinedHelpers = helpers.joined(separator: "\n\n")

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // ── Injected helpers ────────────────────────────────────────
        \(joinedHelpers)

        // ── Filter uniform struct (from \(body.sourceLabel)) ──
        \(uniformStructText)

        // ── Filter body (from \(body.sourceLabel)) ──
        \(bodyText)

        // ── Uber kernel ────────────────────────────────────────────
        kernel void \(functionName)(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
            constant \(body.uniformStructName)& u0 [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            const half4 c = input.read(gid);
            half3 rgb = c.rgb;
            rgb = \(body.functionName)(rgb, u0);
            output.write(half4(rgb, c.a), gid);
        }
        """

        return BuildResult(
            source: source,
            functionName: functionName,
            bindings: Bindings(
                uniformBufferCount: 1,
                auxiliaryTextureSlotCount: 0
            )
        )
    }

    // MARK: - Shape: pixelLocalWithLUT3D (LUT3D)

    /// Build an uber kernel whose body reads a 3D LUT texture in
    /// addition to `rgb / u / gid`. LUT binds at texture slot 2;
    /// output and source stay at 0 and 1.
    private static func buildPixelLocalWithLUT3D(body: FusionBody) throws -> BuildResult {
        let (helpers, uniformStructText, bodyText) = try extractArtefacts(for: body)
        let functionName = uberFunctionName(for: body)

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // ── Injected helpers ────────────────────────────────────────
        \(helpers)

        // ── Filter uniform struct (from \(body.sourceLabel)) ──
        \(uniformStructText)

        // ── Filter body (from \(body.sourceLabel)) ──
        \(bodyText)

        // ── Uber kernel (pixelLocalWithLUT3D) ──────────────────────
        kernel void \(functionName)(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
            texture3d<float, access::read> lut    [[texture(2)]],
            constant \(body.uniformStructName)& u0 [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            const half4 c = input.read(gid);
            half3 rgb = \(body.functionName)(c.rgb, u0, gid, lut);
            output.write(half4(rgb, c.a), gid);
        }
        """

        return BuildResult(
            source: source,
            functionName: functionName,
            bindings: Bindings(
                uniformBufferCount: 1,
                auxiliaryTextureSlotCount: 1
            )
        )
    }

    // MARK: - Shape: pixelLocalWithOverlay (NormalBlend)

    /// Build an uber kernel whose body composites a 2D overlay on
    /// top of the primary source. Overlay binds at texture slot 2;
    /// `outputSize` is computed from the output texture and passed
    /// as the body's last argument. Note the body takes and returns
    /// `half4` (not `half3`) — alpha is needed for Porter-Duff.
    private static func buildPixelLocalWithOverlay(body: FusionBody) throws -> BuildResult {
        let (helpers, uniformStructText, bodyText) = try extractArtefacts(for: body)
        let functionName = uberFunctionName(for: body)

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // ── Injected helpers ────────────────────────────────────────
        \(helpers)

        // ── Filter uniform struct (from \(body.sourceLabel)) ──
        \(uniformStructText)

        // ── Filter body (from \(body.sourceLabel)) ──
        \(bodyText)

        // ── Uber kernel (pixelLocalWithOverlay) ────────────────────
        kernel void \(functionName)(
            texture2d<half, access::write> output  [[texture(0)]],
            texture2d<half, access::read>  input   [[texture(1)]],
            texture2d<half, access::read>  overlay [[texture(2)]],
            constant \(body.uniformStructName)& u0 [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            const uint outW = output.get_width();
            const uint outH = output.get_height();
            if (gid.x >= outW || gid.y >= outH) return;
            const half4 c = input.read(gid);
            const half4 rgba = \(body.functionName)(c, u0, gid, overlay, uint2(outW, outH));
            output.write(rgba, gid);
        }
        """

        return BuildResult(
            source: source,
            functionName: functionName,
            bindings: Bindings(
                uniformBufferCount: 1,
                auxiliaryTextureSlotCount: 1
            )
        )
    }

    // MARK: - Shape: neighborReadWithSource (Sharpen / FilmGrain / CCD)

    /// Build an uber kernel whose body samples the primary source
    /// at offsets relative to `gid`. No aux texture slot — the body
    /// receives the input texture itself as its `src` parameter.
    private static func buildNeighborReadWithSource(body: FusionBody) throws -> BuildResult {
        let (helpers, uniformStructText, bodyText) = try extractArtefacts(for: body)
        let functionName = uberFunctionName(for: body)

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // ── Injected helpers ────────────────────────────────────────
        \(helpers)

        // ── Filter uniform struct (from \(body.sourceLabel)) ──
        \(uniformStructText)

        // ── Filter body (from \(body.sourceLabel)) ──
        \(bodyText)

        // ── Uber kernel (neighborReadWithSource) ───────────────────
        kernel void \(functionName)(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
            constant \(body.uniformStructName)& u0 [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            const half4 c = input.read(gid);
            half3 rgb = \(body.functionName)(c.rgb, u0, gid, input);
            output.write(half4(rgb, c.a), gid);
        }
        """

        return BuildResult(
            source: source,
            functionName: functionName,
            bindings: Bindings(
                uniformBufferCount: 1,
                auxiliaryTextureSlotCount: 0
            )
        )
    }

    /// Shared extraction for single-body shapes — pulls helper
    /// blocks + uniform struct + body text, wrapping any
    /// `ShaderSourceExtractor` failure in `BuildError
    /// .extractionFailed`.
    private static func extractArtefacts(
        for body: FusionBody
    ) throws -> (helpers: String, uniformStruct: String, body: String) {
        let helperBlocks = FusionHelperSource.helpersForBody(named: body.functionName)
        guard !helperBlocks.isEmpty else {
            throw BuildError.unsupportedBodyHelpers(functionName: body.functionName)
        }
        let uniformStructText: String
        let bodyText: String
        do {
            uniformStructText = try ShaderSourceExtractor.extractUniformStruct(
                named: body.uniformStructName,
                from: body.sourceText,
                sourceLabel: body.sourceLabel
            )
            bodyText = try ShaderSourceExtractor.extractBody(
                named: body.functionName,
                from: body.sourceText,
                sourceLabel: body.sourceLabel
            )
        } catch {
            throw BuildError.extractionFailed(error)
        }
        return (helperBlocks.joined(separator: "\n\n"), uniformStructText, bodyText)
    }

    // MARK: - Shape: fusedPixelLocalCluster (pixelLocalOnly members)

    /// Build an uber kernel for a `.fusedPixelLocalCluster` whose
    /// members are all `.pixelLocalOnly`. The kernel declares one
    /// uniform buffer slot per member and emits a sequential chain
    /// of body calls inside a single thread-per-pixel dispatch.
    ///
    /// Deduplication rules:
    ///
    ///   · helper text blocks are injected once per unique content
    ///   · uniform struct declarations are injected once per unique
    ///     struct name (two nodes of the same filter share the
    ///     declaration)
    ///   · body function declarations are injected once per unique
    ///     function name (same rationale — Metal forbids duplicate
    ///     symbol definitions in one compilation unit)
    ///
    /// The call site still issues one call per member regardless of
    /// dedup, so two back-to-back `ExposureFilter` nodes get two
    /// separate uniform buffer bindings (u0, u1) feeding the same
    /// `DCRExposureBody` function.
    private static func buildFusedPixelLocalCluster(
        members: [FusedClusterMember],
        wantsLinearInput: Bool
    ) throws -> BuildResult {
        precondition(!members.isEmpty, "VerticalFusion should never emit an empty cluster")

        // Collect helpers deduped by text content.
        var helperTexts: [String] = []
        var seenHelpers: Set<String> = []
        for member in members {
            let blocks = FusionHelperSource.helpersForBody(named: member.body.functionName)
            guard !blocks.isEmpty else {
                throw BuildError.unsupportedBodyHelpers(
                    functionName: member.body.functionName
                )
            }
            for block in blocks {
                if seenHelpers.insert(block).inserted {
                    helperTexts.append(block)
                }
            }
        }

        // Extract uniform struct texts (unique by struct name).
        var uniformStructTexts: [String] = []
        var seenStructs: Set<String> = []
        for member in members {
            guard seenStructs.insert(member.body.uniformStructName).inserted else {
                continue
            }
            do {
                let text = try ShaderSourceExtractor.extractUniformStruct(
                    named: member.body.uniformStructName,
                    from: member.body.sourceText,
                    sourceLabel: member.body.sourceLabel
                )
                uniformStructTexts.append(text)
            } catch {
                throw BuildError.extractionFailed(error)
            }
        }

        // Extract body function texts (unique by function name).
        var bodyTexts: [String] = []
        var seenBodies: Set<String> = []
        for member in members {
            guard seenBodies.insert(member.body.functionName).inserted else {
                continue
            }
            do {
                let text = try ShaderSourceExtractor.extractBody(
                    named: member.body.functionName,
                    from: member.body.sourceText,
                    sourceLabel: member.body.sourceLabel
                )
                bodyTexts.append(text)
            } catch {
                throw BuildError.extractionFailed(error)
            }
        }

        let functionName = uberFunctionName(
            forCluster: members,
            wantsLinearInput: wantsLinearInput
        )

        // One `constant X& uN [[buffer(N)]]` param per member.
        let uniformParamList = members.enumerated().map { index, member in
            "    constant \(member.body.uniformStructName)& u\(index) [[buffer(\(index))]]"
        }.joined(separator: ",\n")

        // Sequential body calls: rgb passes through each member in
        // cluster order, fed by that member's own uniform buffer.
        let bodyCallChain = members.enumerated().map { index, member in
            "    rgb = \(member.body.functionName)(rgb, u\(index));"
        }.joined(separator: "\n")

        let memberSummary = members.map { $0.body.functionName }.joined(separator: " → ")

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // ── Injected helpers ────────────────────────────────────────
        \(helperTexts.joined(separator: "\n\n"))

        // ── Uniform structs (deduped by name) ──────────────────────
        \(uniformStructTexts.joined(separator: "\n\n"))

        // ── Body functions (deduped by name) ───────────────────────
        \(bodyTexts.joined(separator: "\n\n"))

        // ── Uber kernel: \(memberSummary) ──
        kernel void \(functionName)(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
        \(uniformParamList),
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            const half4 c = input.read(gid);
            half3 rgb = c.rgb;
        \(bodyCallChain)
            output.write(half4(rgb, c.a), gid);
        }
        """

        return BuildResult(
            source: source,
            functionName: functionName,
            bindings: Bindings(
                uniformBufferCount: members.count,
                auxiliaryTextureSlotCount: 0
            )
        )
    }

    /// Cluster-level uber-kernel name. Hashes the ordered sequence
    /// of member body-function names + uniform-struct names + the
    /// cluster's linearity flag. Uniform values stay out of the
    /// hash (same reason as single-node naming: slider positions
    /// are bound at dispatch).
    internal static func uberFunctionName(
        forCluster members: [FusedClusterMember],
        wantsLinearInput: Bool
    ) -> String {
        var hasher = FNV1aHasher()
        for member in members {
            hasher.combine(member.body.functionName)
            hasher.combine(member.body.uniformStructName)
        }
        hasher.combine(wantsLinearInput ? "lin" : "gam")
        return "DCR_UberCluster_\(String(hasher.finalize(), radix: 16))"
    }

    // MARK: - Fragment shader build (Phase 7)

    /// Variant of a cluster's fragment shader. `init` samples the
    /// source texture (used by the first — or only — draw of a
    /// render pass); `chain` reads the running colour attachment via
    /// programmable blending (Phase 8 chained-cluster mode).
    enum FragmentClusterVariant: Sendable, Hashable {
        case `init`
        case chain
    }

    /// Result of a fragment-pipeline build. Source carries the
    /// init fragment (samples source) and — for chain-eligible
    /// shapes — the chain fragment (programmable-blending input
    /// from the running attachment), plus the shared full-screen
    /// vertex shader.
    ///
    /// `chainFragmentFunction` is `nil` for shapes that cannot
    /// participate in chained dispatch — currently only
    /// `.neighborReadWithSource`, whose body samples the source
    /// at offsets and therefore cannot operate on a programmable-
    /// blending input that exposes only the current pixel value.
    /// Such clusters can still serve as the FIRST draw of a
    /// render-pass batch (init mode); subsequent draws must come
    /// from chain-eligible shapes.
    struct FragmentBuildResult: Sendable {
        let source: String
        let vertexFunction: String
        let initFragmentFunction: String
        let chainFragmentFunction: String?
        let signatureShape: FusionBodySignatureShape
        let bindings: Bindings
    }

    /// Build a vertex+fragment pair for a `.fusedPixelLocalCluster`
    /// node whose members are all `.pixelLocalOnly`. Used by the
    /// Phase-8 `RenderBackend` and the Phase-7 fragment-vs-compute
    /// parity test. The fragment samples the source texture once at
    /// the thread-position pixel coordinate, runs every member
    /// body in order, and emits the final colour to attachment 0.
    ///
    /// The vertex shader is a stateless triangle-strip full-screen
    /// quad keyed off `vertex_id` (0..3) — no vertex buffer needed,
    /// so the dispatcher just calls `drawPrimitives(.triangleStrip,
    /// vertexStart: 0, vertexCount: 4)`.
    internal static func buildFragmentClusterPipeline(
        members: [FusedClusterMember],
        wantsLinearInput: Bool
    ) throws -> FragmentBuildResult {
        precondition(!members.isEmpty, "VerticalFusion should never emit an empty cluster")

        // Member uniforms / bodies / helpers reuse the same
        // dedup logic as the compute path.
        var helperTexts: [String] = []
        var seenHelpers: Set<String> = []
        for member in members {
            let blocks = FusionHelperSource.helpersForBody(named: member.body.functionName)
            guard !blocks.isEmpty else {
                throw BuildError.unsupportedBodyHelpers(
                    functionName: member.body.functionName
                )
            }
            for block in blocks where seenHelpers.insert(block).inserted {
                helperTexts.append(block)
            }
        }

        var uniformStructTexts: [String] = []
        var seenStructs: Set<String> = []
        for member in members where seenStructs.insert(member.body.uniformStructName).inserted {
            do {
                let text = try ShaderSourceExtractor.extractUniformStruct(
                    named: member.body.uniformStructName,
                    from: member.body.sourceText,
                    sourceLabel: member.body.sourceLabel
                )
                uniformStructTexts.append(text)
            } catch {
                throw BuildError.extractionFailed(error)
            }
        }

        var bodyTexts: [String] = []
        var seenBodies: Set<String> = []
        for member in members where seenBodies.insert(member.body.functionName).inserted {
            do {
                let text = try ShaderSourceExtractor.extractBody(
                    named: member.body.functionName,
                    from: member.body.sourceText,
                    sourceLabel: member.body.sourceLabel
                )
                bodyTexts.append(text)
            } catch {
                throw BuildError.extractionFailed(error)
            }
        }

        let shape = members.first!.body.signatureShape
        // Every cluster member shares one `signatureShape` by
        // VerticalFusion's same-shape guard; defensive sanity check
        // so a hand-built cluster that violates the invariant is
        // surfaced instead of silently emitting wrong shader source.
        for member in members where member.body.signatureShape != shape {
            throw BuildError.unsupportedNodeKind(
                "fragment cluster requires uniform signatureShape; mixed \(shape) and \(member.body.signatureShape)"
            )
        }

        let baseName = uberFunctionName(
            forCluster: members,
            wantsLinearInput: wantsLinearInput
        )
        let vertexName = "\(baseName)_VS"
        let initFragmentName = "\(baseName)_FS_init"
        let chainFragmentName = "\(baseName)_FS_chain"

        let uniformParamList = members.enumerated().map { index, member in
            "    constant \(member.body.uniformStructName)& u\(index) [[buffer(\(index))]]"
        }.joined(separator: ",\n")

        let memberSummary = members.map { $0.body.functionName }.joined(separator: " → ")

        // Per-shape fragment emission. Each branch defines:
        //   • initFragment  — samples source texture, applies body chain
        //   • chainFragment — programmable-blending input (.color(0)),
        //     applies body chain. `nil` for non-chainable shapes.
        let initFragment: String
        let chainFragment: String?
        let auxTextureCount: Int

        switch shape {
        case .pixelLocalOnly:
            let calls = members.enumerated().map { i, m in
                "    rgb = \(m.body.functionName)(rgb, u\(i));"
            }.joined(separator: "\n")
            initFragment = """
            // ── Fragment (init, pixelLocalOnly): samples source ──────
            // Cluster: \(memberSummary)
            fragment half4 \(initFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                texture2d<half, access::read> source [[texture(0)]],
            \(uniformParamList))
            {
                const uint2 gid = uint2(in.position.xy);
                const half4 c = source.read(gid);
                half3 rgb = c.rgb;
            \(calls)
                return half4(rgb, c.a);
            }
            """
            chainFragment = """
            // ── Fragment (chain, pixelLocalOnly): programmable blend ─
            // Cluster: \(memberSummary)
            fragment half4 \(chainFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                half4 prev [[color(0)]],
            \(uniformParamList))
            {
                half3 rgb = prev.rgb;
            \(calls)
                return half4(rgb, prev.a);
            }
            """
            auxTextureCount = 0

        case .pixelLocalWithLUT3D:
            // body signature: rgb = body(rgb, u, gid, lut)
            let calls = members.enumerated().map { i, m in
                "    rgb = \(m.body.functionName)(rgb, u\(i), gid, lut);"
            }.joined(separator: "\n")
            initFragment = """
            // ── Fragment (init, pixelLocalWithLUT3D) ──────────────────
            // Cluster: \(memberSummary)
            fragment half4 \(initFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                texture2d<half, access::read> source [[texture(0)]],
                texture3d<float, access::read> lut [[texture(1)]],
            \(uniformParamList))
            {
                const uint2 gid = uint2(in.position.xy);
                const half4 c = source.read(gid);
                half3 rgb = c.rgb;
            \(calls)
                return half4(rgb, c.a);
            }
            """
            chainFragment = """
            // ── Fragment (chain, pixelLocalWithLUT3D) ─────────────────
            // Cluster: \(memberSummary)
            fragment half4 \(chainFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                half4 prev [[color(0)]],
                texture3d<float, access::read> lut [[texture(0)]],
            \(uniformParamList))
            {
                const uint2 gid = uint2(in.position.xy);
                half3 rgb = prev.rgb;
            \(calls)
                return half4(rgb, prev.a);
            }
            """
            auxTextureCount = 1

        case .pixelLocalWithOverlay:
            // body signature: rgba = body(rgba, u, gid, overlay, outputSize)
            // Returns half4 (Porter-Duff alpha math). NormalBlend
            // body forwards source alpha through the composite.
            let calls = members.enumerated().map { i, m in
                "    rgba = \(m.body.functionName)(rgba, u\(i), gid, overlay, outputSize);"
            }.joined(separator: "\n")
            // outputSize is bound as a small uniform buffer at slot
            // `members.count` (right after the per-member uniforms).
            let outputSizeBuffer = members.count
            initFragment = """
            // ── Fragment (init, pixelLocalWithOverlay) ────────────────
            // Cluster: \(memberSummary)
            fragment half4 \(initFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                texture2d<half, access::read> source [[texture(0)]],
                texture2d<half, access::read> overlay [[texture(1)]],
            \(uniformParamList),
                constant uint2& outputSize [[buffer(\(outputSizeBuffer))]])
            {
                const uint2 gid = uint2(in.position.xy);
                half4 rgba = source.read(gid);
            \(calls)
                return rgba;
            }
            """
            chainFragment = """
            // ── Fragment (chain, pixelLocalWithOverlay) ───────────────
            // Cluster: \(memberSummary)
            fragment half4 \(chainFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                half4 prev [[color(0)]],
                texture2d<half, access::read> overlay [[texture(0)]],
            \(uniformParamList),
                constant uint2& outputSize [[buffer(\(outputSizeBuffer))]])
            {
                const uint2 gid = uint2(in.position.xy);
                half4 rgba = prev;
            \(calls)
                return rgba;
            }
            """
            auxTextureCount = 1

        case .neighborReadWithSource:
            // body signature: rgb = body(rgb, u, gid, source).
            // The body samples `source` at offsets, so chain mode is
            // not viable — programmable blending exposes only the
            // current pixel of the running attachment. Init only.
            let calls = members.enumerated().map { i, m in
                "    rgb = \(m.body.functionName)(rgb, u\(i), gid, source);"
            }.joined(separator: "\n")
            initFragment = """
            // ── Fragment (init, neighborReadWithSource) ───────────────
            // Cluster: \(memberSummary)
            fragment half4 \(initFragmentName)(
                DCRFullScreenVertexOut in [[stage_in]],
                texture2d<half, access::read> source [[texture(0)]],
            \(uniformParamList))
            {
                const uint2 gid = uint2(in.position.xy);
                const half4 c = source.read(gid);
                half3 rgb = c.rgb;
            \(calls)
                return half4(rgb, c.a);
            }
            """
            chainFragment = nil
            auxTextureCount = 0

        case .pixelLocalWithGid:
            // No SDK filter uses this shape today; surface the miss
            // rather than emit untested source.
            throw BuildError.unsupportedSignatureShape(shape)
        }

        let chainFragmentText = chainFragment ?? "// chain variant not emitted for shape \(shape)"

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        // ── Injected helpers ────────────────────────────────────────
        \(helperTexts.joined(separator: "\n\n"))

        // ── Uniform structs (deduped by name) ──────────────────────
        \(uniformStructTexts.joined(separator: "\n\n"))

        // ── Body functions (deduped by name) ───────────────────────
        \(bodyTexts.joined(separator: "\n\n"))

        // ── Vertex shader: full-screen triangle strip ─────────────
        struct DCRFullScreenVertexOut {
            float4 position [[position]];
        };

        vertex DCRFullScreenVertexOut \(vertexName)(uint vid [[vertex_id]]) {
            const float2 verts[4] = {
                float2(-1.0,  1.0),
                float2(-1.0, -1.0),
                float2( 1.0,  1.0),
                float2( 1.0, -1.0),
            };
            DCRFullScreenVertexOut out;
            out.position = float4(verts[vid], 0.0, 1.0);
            return out;
        }

        \(initFragment)

        \(chainFragmentText)
        """

        return FragmentBuildResult(
            source: source,
            vertexFunction: vertexName,
            initFragmentFunction: initFragmentName,
            chainFragmentFunction: chainFragment != nil ? chainFragmentName : nil,
            signatureShape: shape,
            bindings: Bindings(
                uniformBufferCount: members.count,
                auxiliaryTextureSlotCount: auxTextureCount
            )
        )
    }

    // MARK: - Uber-kernel naming

    /// Deterministic name for the uber kernel of the given body,
    /// derived from a FNV-1a hash of the body's stable signature
    /// (function name + uniform struct name + signature shape
    /// discriminant). Uniform values are excluded — the same shader
    /// handles every slider position of a given filter.
    ///
    /// Returning the same name for structurally-equivalent calls
    /// lets `PipelineStateCache` share PSOs across Nodes that
    /// otherwise differ only in their uniform payload.
    internal static func uberFunctionName(for body: FusionBody) -> String {
        var hasher = FNV1aHasher()
        hasher.combine(body.functionName)
        hasher.combine(body.uniformStructName)
        hasher.combine(shapeTag(body.signatureShape))
        return "DCR_Uber_\(String(hasher.finalize(), radix: 16))"
    }

    /// Stable textual tag for each signature shape. Hash input
    /// cannot depend on `String(describing:)` because enum-case
    /// debug output changes across Swift versions, which would
    /// quietly invalidate PSO cache keys after a toolchain bump.
    private static func shapeTag(_ shape: FusionBodySignatureShape) -> String {
        switch shape {
        case .pixelLocalOnly:         return "pxl"
        case .pixelLocalWithGid:      return "pxg"
        case .pixelLocalWithLUT3D:    return "lut"
        case .pixelLocalWithOverlay:  return "ovl"
        case .neighborReadWithSource: return "nbr"
        }
    }
}

// MARK: - FNV-1a

/// Simple deterministic hash for uber-kernel name derivation.
/// FNV-1a is chosen for its stability (same input → same output
/// across processes, compilers, and architectures) and its bit
/// distribution for short strings. Output is the 64-bit hash value;
/// callers typically render it in hex.
@available(iOS 18.0, *)
private struct FNV1aHasher {
    private var state: UInt64 = 0xcbf29ce484222325

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            state ^= UInt64(byte)
            state &*= 0x100000001b3
        }
        // Delimiter between combined strings prevents accidental
        // collision from adjacent inputs that concatenate.
        state ^= 0xff
        state &*= 0x100000001b3
    }

    func finalize() -> UInt64 {
        state
    }
}
