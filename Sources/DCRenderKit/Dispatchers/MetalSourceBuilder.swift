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
            guard body.signatureShape == .pixelLocalOnly else {
                throw BuildError.unsupportedSignatureShape(body.signatureShape)
            }
            guard additionalAux.isEmpty else {
                throw BuildError.unsupportedNodeKind(
                    "pixelLocalOnly shape should not carry additionalNodeInputs"
                )
            }
            return try buildPixelLocalOnly(body: body)

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
        // the filter's production `.metal` file.
        let uniformStructText: String
        let bodyText: String
        do {
            uniformStructText = try ShaderSourceExtractor.extractUniformStruct(
                named: body.uniformStructName,
                from: body.sourceMetalFile
            )
            bodyText = try ShaderSourceExtractor.extractBody(
                named: body.functionName,
                from: body.sourceMetalFile
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

        // ── Filter uniform struct (from \(body.sourceMetalFile.lastPathComponent)) ──
        \(uniformStructText)

        // ── Filter body (from \(body.sourceMetalFile.lastPathComponent)) ──
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
                    from: member.body.sourceMetalFile
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
                    from: member.body.sourceMetalFile
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
