# DCRenderKit Architecture

This document is the permanent narrative for how DCRenderKit is
designed and why. It pairs with
[`foundation-capability-baseline.md`](foundation-capability-baseline.md)
(which catalogues **what** the SDK guarantees) and the session
handoffs in `docs/session-handoff.md` (which record **when and by
whom** each decision landed).

Start here if you're:

- Adopting DCRenderKit and want to understand the execution model
  before writing integration code.
- Reviewing a PR that reshapes the core types and need the "why"
  behind the existing boundaries.
- Writing a custom filter and want to know where your code fits
  and which primitives it should reach for.

---

## 1. Design principles

Every decision downstream of this section traces back to one of
five commitments the SDK makes to its consumers:

### 1.1 Commercial-grade correctness, not "good enough"

The SDK pays for precision, not for speed at the cost of precision:
16-float intermediates between every step (§4.1), canonical
IEC 61966-2-1 sRGB transfer (§4.6), principled tone operators with
published derivations (§4.4). The rule is that any drift past
`testing.md` error budgets is an implementation bug, not a
tolerance-loosening opportunity.

### 1.2 Zero external dependencies

`Package.swift.dependencies` stays empty, enforced by
`PackageManifestTests`. The SDK consumes only system frameworks
(Metal, MetalKit, optional CoreVideo / Vision /
MetalPerformanceShaders). Every transitive dependency is one more
supply-chain risk the consumer inherits; adopters don't pick up
any from DCRenderKit.

### 1.3 iOS-only at the business layer

The SDK ships one platform — iOS 18+. macOS 15 is retained only as
a `swift test` host so CI can run the 300+ shader tests against a
real Metal GPU. No NSImage, no AppKit. Cross-platform spread would
introduce subtle behavioural divergences (shader precision, color-
space defaults, pixel-format conventions); keeping the surface
narrow means every consumer runs the same path.

### 1.4 Principled over fitted

Tier 2 tone operators (Contrast, Blacks, Whites, negative Exposure)
use published grading primitives (DaVinci log-slope, Reinhard toe,
Filmic shoulder, linear gain) rather than fitted polynomials. Tier 3
filters carry measurable contracts with fetched-URL references. When
the SDK reaches for an empirical constant, it's called out with a
`FIXME(§… Tier 2)` marker that links to the archived rationale.

### 1.5 Boundaries that scale up

Primitives (pools, caches, dispatchers) are injectable via
`Pipeline.init` so advanced consumers can isolate workloads (e.g.
per-queue pools for video capture + editor). The defaults (`.shared`
instances) cover every standard consumer without configuration.

---

## 2. Layer overview

```
┌───────────────────────────────────────────────────────────────┐
│  Consumer code                                                │
│    let pipeline = Pipeline()  // long-lived                    │
│    try pipeline.encode(                                        │
│        into: cb, source: tex, steps: [...],                    │
│        writingTo: drawable.texture)                            │
└───────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────┴─────────────────────────────────┐
│ Pipeline (Pipelines/)                                          │
│   · resolves source via TextureLoader                          │
│   · runs the pipeline compiler (Lowering → Optimizer →         │
│     LifetimeAwareTextureAllocator), memoised per Pipeline      │
│     via CompiledChainCache                                     │
│   · dispatches each graph node through ComputeBackend /        │
│     RenderBackend / ComputeDispatcher                          │
│   · batches contiguous pixel-local clusters into one TBDR      │
│     render pass with programmable blending                     │
└─────────────────────────────┬─────────────────────────────────┘
                              │
┌───────────────┐   ┌────────┴─────────┐   ┌─────────────────┐
│ Filters/      │   │ Dispatchers/     │   │ Core/ (kernels  │
│   FilterProt. │   │   Compute / Blit │   │   MultiPass     │
│   MultiPassF. │   │   Render / MPS   │   │   Executor)     │
│   16 filters  │   │                  │   │                 │
└───────┬───────┘   └────────┬─────────┘   └────────┬────────┘
        │                    │                      │
        ▼                    ▼                      ▼
┌───────────────────────────────────────────────────────────────┐
│  Resources/ (pools + caches — injectable into Pipeline.init)   │
│    TexturePool, UniformBufferPool, CommandBufferPool,          │
│    PipelineStateCache, SamplerCache, Device                    │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
                         Metal GPU
```

A few layering rules emerge from this shape:

- **Consumer code never reaches into `Core/` or `Resources/`
  directly.** Everything threads through `Pipeline` or a filter
  protocol conformance.
- **Dispatchers don't own resources.** They take pool / cache
  references as parameters and leave lifecycle to the caller
  (Pipeline, or the filter author).
- **`MultiPassExecutor` is internal.** The only way to reach it is
  via `Pipeline` executing `.multi(filter)`; no
  consumer has a reason to invoke `.execute` directly (see
  `CHANGELOG.md` §48 for the rationale).
- **`Foundation/*.metal`** is shader-side shared code (sRGB
  transfer, OKLab matrices, guided-filter sub-kernels). Because
  SwiftPM compiles each `.metal` into its own library, these
  helpers are *mirrored* into every consuming shader rather than
  linked — see §4.9.

---

## 3. Data flow for a single `process(input:steps:)` / `encode(...)` call

1. **Source resolution** (`TextureLoader`). `PipelineInput.uiImage`
   / `.cgImage` go through `MTKTextureLoader` with the SDK's
   `.linear` / `.perceptual` decision driving the `.SRGB` flag.
   `.pixelBuffer` (camera frames) goes through `CVMetalTextureCache`
   for zero-copy; BGRA vs BGRA_srgb is chosen from the colour-space
   mode. `.texture` passes through.
2. **Pipeline compilation** (lowering + optimisation + texture
   planning). `Lowering` walks the filter chain and emits a
   `PipelineGraph`; `Optimizer` rewrites it under
   `PipelineOptimization.full` (DCE, vertical fusion, CSE, kernel
   inlining, tail sink); `LifetimeAwareTextureAllocator` colours
   the lifetime-interval graph to assign a pooled texture to each
   surviving node. The whole compile result (optimised graph, the
   chain-internal alias map, and the bucket plan) is memoised by
   `CompiledChainCache` keyed on the lowered-graph fingerprint —
   subsequent frames with the same chain topology hit the cache
   and skip every optimiser pass.
3. **Command buffer allocation** (`CommandBufferPool`).
   Concurrency-limited by semaphore, tagged with a caller-supplied
   label for diagnostics.
4. **Step-by-step execution** (`Pipeline.executeStep`):
   - `.single(filter)` → `ComputeDispatcher.dispatch` with a
     destination texture pulled from `TexturePool` at
     `intermediatePixelFormat = .rgba16Float`.
   - `.multi(filter)` → `MultiPassExecutor.execute` with the same
     intermediate format; the executor walks the filter's `Pass`
     graph, validates structure, allocates each intermediate from
     the pool, dispatches compute kernels, and enqueues
     intermediates for deferred release once the command buffer
     completes (§4.7).
5. **Final handoff**. The chain's last-step output is handed to
   the caller either as an `MTLTexture` (`process(...)` /
   `processSync(...)` / `encode(into:source:steps:)`) or blitted
   via MPS Lanczos into the caller's `CAMetalDrawable` /
   video-frame target (`encode(into:source:steps:writingTo:)`).
6. **Completion**. `scheduleDeferredEnqueue` fires on
   `addCompletedHandler` and returns the cycle's intermediates to
   the texture pool for the next frame's dequeue.

---

## 4. Key architectural decisions

Each decision below lists what we chose, what we rejected, and
why. The "origin" line points at the session / commit where the
decision landed so future readers can recover the full context.

### 4.1 `rgba16Float` intermediates by default

**Choice**: `Pipeline.intermediatePixelFormat` defaults to
`.rgba16Float`. The executor threads this through
`MultiPassExecutor.sourceInfo` rather than `source.pixelFormat`.

**Rejected**: Inheriting the source pixel format (typically
`.bgra8Unorm` for camera feeds). An 8-bit intermediate truncates
`ratio > 1.0` from HighlightShadow, sub-`1/255` detail residuals
from Clarity, and pyramid-accumulated bloom from SoftGlow.

**Why this is non-obvious**: The camera path looks "correct" in
low-contrast content — the failure mode only shows up as visible
banding in long filter chains on hero-frame content.

**Origin**: `CHANGELOG.md` `[Unreleased]` via `Bgra8UnormSourceContractTests`.

### 4.2 `.linear` vs `.perceptual` numerical mode

**Choice**: A one-line compile-time flip,
`DCRenderKit.defaultColorSpace`. Filters read the flag, the
drawable pixel format follows via
`DCRColorSpace.recommendedDrawablePixelFormat`.

**Rejected**: A runtime toggle. Each filter's hot path would grow
a branch per pixel; the compiler strips the unused branch when the
flag is a static let.

**Why this is non-obvious**: The two modes produce *different*
numerical outputs on the same input image — `.linear` is
mathematically correct for Reinhard / Rec.709 math but visually
drifts from `.perceptual`. The parity contract is exercised by
`LinearPerceptualParityTests` (315 grid points across 5 tone
filters) so consumers can pick either mode without "feel" drift.

**Origin**: Session B / findings-and-plan §7.3 (now archived, with
the drift formalised into the parity tests).

### 4.3 Typed `PipelineError` hierarchy

**Choice**: Closed enum with 5 domains
(`device`/`texture`/`pipelineState`/`filter`/`resource`), each
with structured case data.

**Rejected**: `NSError` + userInfo dictionaries, or untyped `Error`
pass-through.

**Why**: Consumers can `switch` on the top-level cases for coarse
handling (retry transient `.device.gpuExecutionFailed`, surface
fatal `.pipelineState.functionNotFound`) without parsing strings.
Every case carries exactly the context needed to diagnose the
failure.

**Origin**: Session C, #74 completion.

### 4.4 Principled Tier 2 tone operators

**Choice**: Replace fitted polynomials with:
- Contrast: DaVinci log-space slope
  `y = pivot · (x/pivot)^slope`.
- Blacks: Reinhard toe with scale
  `y = x / (x + ε·(1 − x))`.
- Whites: Filmic shoulder
  `y = ε·x / ((1 − x) + ε·x)` — algebraic mirror of Blacks.
- Exposure (negative): pure linear gain.

**Rejected**: The prior fitted curves (MSE-tuned against consumer-
app JPEG exports). They scored well in-sample but had no closed-
form justification, and shipped behaviours that drifted off-
sample — especially at the tonal endpoints where the polynomial
fit degraded.

**Why**: Published grading primitives have predictable response
under extreme slider positions and are easier to document. The
"±1.585 stops of contrast at ±100" convention maps directly to
the DaVinci slope formulation.

**Origin**: Session C, D1 decision.

### 4.5 Tier 3 contracts for perception-based filters

**Choice**: Every filter in the "perception-based" tier
(Vibrance, Saturation, HighlightShadow, Clarity, SoftGlow) ships a
`docs/contracts/<name>.md` document with measurable clauses plus
a matching test in `Tests/DCRenderKitTests/Contracts/`.

**Rejected**: Informal "looks right" validation. "Perceptual" is
used as a label for filters that *could* be pinned down but
habitually aren't — the contract approach forces the pin.

**Why**: Each clause has a quantitative assertion
("halo-free < 3 % at Zone VII", "skin-hue protection > 2× the
boost of equivalent non-skin patch", etc.) and a fetched-URL
reference to the underlying colour-science literature. A future
refactor can't silently regress a behaviour that has a contract
test.

**Origin**: Session B, A+.1 – A+.5.

### 4.6 IEC 61966-2-1 canonical sRGB, mirrored

**Choice**: A single canonical implementation of the true
piecewise sRGB transfer function lives in
`Shaders/Foundation/SRGBGamma.metal`. Every consuming shader has
its own *mirror* of the helper block (identical text), marked
with `// MIRROR: Foundation/SRGBGamma.metal`.

**Rejected**: `pow(c, 2.2)` / `pow(c, 1/2.2)` approximations.

**Why approximations are wrong**: The `pow(2.2)` approximation
diverges from the true curve by up to ~2% at midtones. A pipeline
that round-trips between gamma and linear accumulates that error
per conversion — every intermediate operation that linearises
and re-encodes adds another 2% of midtone drift.

**Why mirror instead of include**: SwiftPM compiles each `.metal`
file into its own `MTLLibrary` (see `ShaderLibrary.swift:236`), so
function symbols don't cross translation-unit boundaries. Until a
build-time Metal preprocessor resolves `#include` across the
Shaders tree, mirroring is the tractable approach.

**Origin**: Session B, §8.1 A.1.

### 4.7 Cross-CB deferred texture enqueue

**Choice**: Intermediate textures are returned to the pool only
**after** the command buffer that last read them completes on the
GPU, via `scheduleDeferredEnqueue`'s
`addCompletedHandler` hook.

**Rejected**: Enqueue-as-soon-as-encoded. Intra-CB hazard tracking
protects within one command buffer; cross-CB does not.

**Why**: If pipeline A's encoded CB is still running on the GPU
when pipeline B's CB dequeues the same texture, B's writes corrupt
A's still-pending reads. The deferral closes that hazard. The
cost is that the pool doesn't reclaim textures mid-CB, but Metal's
per-CB ping-pong pattern means intermediate textures are always
available for the next frame's dequeue anyway.

**Origin**: `CHANGELOG.md` `[Unreleased]` via `DeferredEnqueueTests`.

### 4.8 Command-buffer-fenced `UniformBufferPool`

**Choice**: Every large-uniform (>4 KB) dispatch reserves a unique
buffer slot for the command buffer's lifetime. Slots release on CB
completion. The pool grows on demand up to `maxBuffers` (default
64) rather than wrapping a ring.

**Rejected**: A naive ring buffer of N slots. A single CB with >N
large-uniform dispatches overwrites earlier binds before the GPU
reads them — silent corruption.

**Why**: Ring buffers are fine when dispatch count is bounded and
known; DCR doesn't know how many dispatches the user will queue in
a single CB (long filter chains, multi-pass filters with adaptive
pyramid depth). Fence the slot to the CB and grow on contention.

**Origin**: Session C, `UniformBufferPool` refactor.

### 4.9 Dual-path shader library loading

**Choice**: `ShaderLibrary.tryLoadDefaultLibrary` tries two
strategies: load a pre-compiled `default.metallib` from the
bundle (xcframework / Xcode build path), and fall back to
compiling every `.metal` source at runtime (SwiftPM CLI path).

**Rejected**: Insisting on one strategy. xcframework consumers
can't easily ship raw `.metal` sources; SwiftPM CLI doesn't run
the Metal compiler on `.metal` resources.

**Why**: DCRenderKit is consumed both ways (SPM package for
library authors, xcframework for app projects). Both must work.
Runtime compilation pays ~10–30 ms on first use — amortised by the
PSO cache across a session.

**Origin**: Session B, `ShaderLibrary` implementation.

### 4.10 `PassInput.additional(_:)` for caller-supplied textures

**Choice**: A multi-pass filter declares
`additionalInputs: [MTLTexture]` on the filter struct, and any
pass in its graph can reference
`.additional(i)` to consume `additionalInputs[i]`. The executor
routes the texture to `texture(2+i)` in the kernel.

**Rejected**: Caching the mask / LUT / auxiliary texture in the
filter's internal state and passing it to the kernel through
`FilterProtocol.additionalInputs`. That works for single-pass
filters but not for multi-pass, because the same auxiliary texture
needs to reach *multiple* passes — the old API would only bind it
to the first.

**Why**: DigiCam's portrait-blur flow is the canonical example.
Vision produces a subject mask; the two-pass Poisson blur needs it
in both passes, at the same resolution. `PassInput.additional(0)`
routes the caller-supplied mask to every pass that names it.

**Origin**: Session C, #75 PortraitBlur refactor.

### 4.11 Fast Guided Filter shared primitives

**Choice**: Three kernels
(`DCRGuidedDownsampleLuma`, `DCRGuidedComputeAB`,
`DCRGuidedSmoothAB`) live in
`Shaders/Foundation/GuidedFilter.metal` and are reused by
`HighlightShadowFilter` and `ClarityFilter` with different `eps` /
radius parameters.

**Rejected**: Per-filter clones. Bug-fixes would have to be
applied in multiple places; parameter choices would drift.

**Why**: Both filters need an edge-preserving base extractor; the
guided filter family is the right tool for both. Factoring the
primitive into `Foundation/` lets each filter tune its own
`eps` / `radius` (0.01 / 1.2 % short-side for HS; 0.005 / 1.9 %
for Clarity) while sharing the bug-surface-minimising
implementation.

**Origin**: Session B.

### 4.12 OKLCh for chroma operations

**Choice**: Saturation and Vibrance operate in OKLCh
(Ottosson 2020). Chroma scaling preserves OKLab lightness and
hue; the gamut clamp preserves `L` and `h` by reducing `C`.

**Rejected**: Rec.709 luma-anchored mix
(`mix(vec3(luma), rgb, s)`) and CIELAB 1976. Rec.709 suffers from
lightness shift at the blue-purple edge; CIELAB 1976 has
documented hue drift that photographers notice.

**Why**: OKLab was designed explicitly for image-processing chroma
manipulation and is the CSS Color Level 4 / 5 standard. Using it
means the SDK's "increase saturation" command produces the same
result a CSS-conformant renderer would.

**Origin**: Session B, #14 / #77 refactor.

### 4.13 Snapshot regression for Tier 4 aesthetic filters

**Choice**: FilmGrain, CCD, PortraitBlur — the "aesthetic" tier —
freeze pixel-level baselines via `SnapshotAssertion`. The
framework stores 8-bit PNGs next to the test file, first run
writes the baseline, subsequent runs fail on per-channel |Δ|
past a 2% tolerance.

**Rejected**: Insisting on measurable clauses (à la Tier 3). The
aesthetic filters don't decompose cleanly into "direction +
monotonicity + selectivity" clauses — they're evaluated
holistically. A snapshot is the honest representation.

**Why**: Aesthetic filters regress visibly under refactors even
when no clause is violated. The snapshot gate catches visual
drift at pixel precision; `maxChannelDrift = 0.02` sits above the
Float16 quantisation floor and below the "looks different"
perceptual threshold.

**Origin**: Session C, #36 implementation; #37/#38/#39 baseline
freeze still gated on real-device approval.

---

### 4.14 `CompiledChainCache` — per-Pipeline fingerprint memoization

**Choice**: Each `Pipeline` instance owns a `CompiledChainCache`
that maps a fingerprint of the lowered `PipelineGraph` → the
tuple of (optimised graph, `TextureAliasingPlan`). Cache hits skip
the entire Lowering → Optimizer → Planner stack per encode call.

**Fingerprint design**: The fingerprint hashes every node's
structural payload **and its raw uniform bytes**. Uniforms must
participate because the cached entry stores the optimised graph
nodes with their uniforms baked in: a slider drag changes uniform
values without changing topology, so excluding uniforms from the
key would return a stale graph with old uniforms (the symptom is
"slider doesn't change the rendering"). The four `NodeKind`
variants that carry uniforms (`.pixelLocal`, `.neighborRead`,
`.nativeCompute`, `.fusedPixelLocalCluster`) all feed
`uniforms.copyBytes(...)` into the hasher.

**Hit-rate consequence**: Camera preview with stable parameters
hits the cache every frame after the first — the structural work
runs once and amortises forever. A slider drag misses on every
frame during the drag (each frame re-runs the optimiser), then
returns to 100% hit-rate once the slider settles. Both behaviours
are intentional: the cache is meant to amortise structural
recompilation (graph shape changes when the filter list changes),
not to skip per-frame dispatch. Dispatch itself is O(N) in the
node count and cannot be cached.

**Boundary**: The cache is per-`Pipeline` instance. Two `Pipeline`
instances serving the same chain have independent caches and do
not share compiled graphs. There is no process-global graph cache.
This keeps invalidation simple at the cost of redundant
compilation when two pipelines run identical chains (e.g. preview
+ export at the same point in time). For current use cases (one
pipeline per MTKView) this cost does not materialise. Multi-
Pipeline scenarios are explicitly supported — see §4.17 for the
isolation model and the recommended budget shapes.

**Why Phase 11's long-lived `Pipeline` (§4.15) matters here**:
Before Phase 11, callers built a fresh `Pipeline` per frame, which
threw the cache away every frame and reduced its hit rate to zero
even on stable chains. The cache was technically correct in that
era but never paid back its bookkeeping cost. Long-lived
`Pipeline` is what turns this cache from a no-op into the actual
amortisation primitive the compiler depends on.

**Origin**: Phase 10 design; activated by Phase 11's long-lived
`Pipeline` lifecycle.

---

### 4.15 Long-lived `Pipeline` renderer (Phase 11)

**Choice**: Prior to Phase 11, `Pipeline` stored `source` and
`steps` as properties and the `encode` family read them from
`self`. This forced callers to construct a new `Pipeline` (or
mutate its properties) each frame — wiping the
`CompiledChainCache` and reintroducing O(N) Optimizer work on
every frame. Phase 11 removes these properties entirely: `source`
and `steps` are passed at each `encode(into:source:steps:)` /
`process(input:steps:)` call site. One `Pipeline` is created when
a view is set up and reused for every subsequent frame.

**API rule this implies**: `Pipeline` is a long-lived object.
Never create a `Pipeline` inside a draw callback, inside a
`URLSession` completion, or in any other per-frame / per-call
scope. Create it once, store it as an instance property of your
coordinator, and call `encode` / `process` on it repeatedly.
Multiple long-lived Pipelines can coexist (e.g. one per MTKView
in a multi-tab app); see §4.17 for resource isolation when you
have more than one.

**Why not keep source/steps as properties**: The property model
conflates "renderer configuration" (metal device, optimization
flags, color space) with "current frame data" (source texture,
filter steps). Separating them at the call site makes the cache
lifetime obvious — the cache is valid for the lifetime of the
renderer, not for the lifetime of a single configuration.

**Backward compatibility note**: This is a breaking API change
(pre-1.0 window used intentionally — see §1.3). There is no
migration shim. Old code that constructs `Pipeline(source:steps:)`
or calls `encode(into:)` without arguments will fail to compile.

**Origin**: Phase 11 refactor.

---

### 4.16 Frame Graph stream B — structural optimizations and their boundaries

The pipeline compiler runs five graph rewrites — Dead Code
Elimination, Vertical Fusion, Common Sub-Expression Elimination,
Kernel Inlining, Tail Sink — plus the `TextureAliasingPlanner`
after `Lowering` produces the initial `PipelineGraph`. The
rewrites change graph structure; the planner assigns physical
textures to the rewritten nodes. Together these form "stream B"
in the frame-graph sense: they reduce GPU work and memory
pressure without touching filter semantics.

#### Dead Code Elimination (DCE)

Walks the graph backward from `finalID` via each node's
`dependencyRefs`, marks every reachable node, and drops the rest.
Standard reachability BFS; O(V + E). Typical sources of dead
nodes:

- identity-parameter filters that lowering keeps as placeholders;
- CSE-collapsed duplicates whose originating node becomes an
  orphan;
- `VerticalFusion` / `TailSink` outputs whose former members stop
  being referenced after fusion.

**Boundary**: DCE is purely reachability-based — it removes nodes
with no path to the final node. It does not reorder nodes, does
not reason about side effects (the SDK's nodes are pure GPU
dispatches with no side-effect concept), and does not look inside
nodes. `NodeRef.source` and `NodeRef.additional(_)` don't point at
nodes, so they don't contribute to reachability; only
`NodeRef.node(_)` does.

#### Common Sub-Expression Elimination (CSE)

Folds nodes with identical `NodeSignature` (function name, uniform
bytes, input refs, output spec) — the second occurrence is rewritten
to reference the first. Real-world trigger: `HighlightShadowFilter`
and `ClarityFilter` both emit `DCRGuidedDownsampleLuma` as their
first pass; in a chain that contains both, CSE collapses those
duplicates into one node that both filters' later passes read from.

**Boundary**: Two structural exclusions are never folded. (1) `isFinal`
nodes — a graph must have exactly one final node, so folding away the
final would corrupt the graph. (2) `.fusedPixelLocalCluster` nodes —
clusters are themselves fusion products; their `NodeSignature` is
nil so they don't participate. CSE also doesn't reason about
mathematical equivalence: `f(g(x))` and `g(f(x))` are never merged
even when numerically equivalent for a specific input.

#### Vertical Fusion (VerticalFusion)

Merges runs of adjacent `.pixelLocal` nodes into a single
`.fusedPixelLocalCluster` node. The cluster's members run in order
inside a single uber kernel that the Phase-3 codegen generates;
member-to-member pixel data flows through **shader-local registers**,
not intermediate textures.

**Merge conditions** for an adjacent pair `A → B` (all must hold):
1. Both `A` and `B` are `.pixelLocal`.
2. `B.inputs == [.node(A.id)]` — `B`'s only texture input is `A`'s
   output, entering at the primary slot.
3. `A.outputSpec == .sameAsSource` **and** `B.outputSpec ==
   .sameAsSource` — no resolution change between the two.
4. `A.wantsLinearInput == B.wantsLinearInput` — both bodies expect
   the same colour-space representation; mixing would require a
   gamma wrapper the uber kernel can't elide.
5. `A` has exactly one consumer in the whole graph (namely `B`),
   and `A` is not the final node — fan-out or final-status would
   force `A`'s output to remain externally observable, defeating
   fusion.

**Tradeoff**: Cluster fusion reduces GPU encoder overhead and
eliminates intermediate texture round-trips between members. The
cost is that fused clusters are harder to debug (member outputs
are not readable as Metal textures). When debugging a filter
chain, set `PipelineOptimization.none` to defeat fusion and
inspect each pass independently.

**Boundary — what fusion IS not**: A single fused cluster runs
inside one Metal kernel/fragment with member bodies inlined back
to back, passing `half3 rgb` through registers. **Programmable
blending (`[[color(0)]]`) is unrelated to intra-cluster body
chaining** — programmable blending appears only in Phase 8's
multi-cluster render-chain dispatch (`RenderBackend.executeChain`),
where each draw is a *separate* cluster reading the previous
draw's tile-memory result. Inside one cluster, there's no blending
involved.

#### Texture Aliasing (`TextureAliasingPlanner`)

Assigns pooled "buckets" (one MTLTexture per bucket) to
intermediate graph nodes using greedy interval-graph colouring by
release time. Two nodes share a bucket if (a) their live-ranges
on the declaration-order timeline do not overlap, **and** (b) they
have the same `TextureInfo` spec (width × height × pixelFormat).
For the DCR pipeline graph every node's lifetime is a contiguous
interval on the 1-D declaration timeline, so interval-graph
colouring is optimal — the planner hits the theoretical minimum
bucket count.

**Format compatibility**: Free-list lookup keys on the full
`TextureInfo` spec, so a bucket allocated for `.rgba16Float` will
never be reused for a `.bgra8Unorm` node — no fallback path is
needed because the lookup simply won't return an incompatible
bucket. Different specs produce independent free lists in
`freePerSpec[spec]`.

**Boundary — chain-internal cluster nodes get NO bucket**: When
Phase-8 chained-render dispatch is in play, intermediate clusters
in the middle of a `RenderBackend.executeChain` draw chain pass
their result to the next cluster via Metal's programmable blending
(tile memory) and never write a real texture. The planner
recognises these via the `chainInternalAlias` map and **skips
bucket allocation entirely** for them — `bucketOf[id]` is aliased
to the chain tail's bucket so `mapping[id]` lookups still resolve,
but no MTLTexture is dispensed. This is the Phase-8 memory win:
chaining N clusters needs only one physical render-target texture
instead of N intermediates.

**Tradeoff**: The plan is computed once per unique chain shape and
cached by `CompiledChainCache`. The materialisation step (texture-
pool dequeue) still runs every frame because the previous frame's
textures may still be in flight on the GPU; only the planner /
optimiser CPU work is amortised by the cache.

#### Kernel Inlining (head fusion)

Absorbs a `.pixelLocal` producer `P` into an immediately-downstream
`.neighborRead` consumer `N`, so `N`'s neighbour-read kernel reads
raw source pixels and applies `P`'s body to each sample before the
neighbourhood combine. This replaces two dispatches and one
intermediate texture with one slightly heavier dispatch. It is the
spatial analogue of `VerticalFusion`: where vertical fusion merges
bodies that all touch the same pixel coordinate, kernel inlining
widens the neighbour-read's sample loop so each sample pays the
inlined body's per-pixel cost. Phase-3 codegen consumes
`Node.inlinedBodyBeforeSample` to emit one kernel that loops over
neighbours, applies the inlined body to each read, and finally
runs the neighbour-read body.

**Merge conditions** (all required):
1. `N.kind == .neighborRead`.
2. `N.inputs[0] == .node(P.id)` — `P`'s output is `N`'s primary
   texture source.
3. `P.kind == .pixelLocal`.
4. `P.outputSpec == .sameAsSource`.
5. `P.isFinal == false`.
6. `P` has exactly one consumer in the graph (namely `N`).
7. `N` doesn't already carry an inlined body — double-inlining
   needs codegen support that doesn't ship.

#### Tail Sink (tail fusion, aggressive)

The opposite of `KernelInlining`: absorbs a downstream `.pixelLocal`
into its upstream producer, so the producer's own kernel applies
the pixelLocal body right before `output.write` runs.

The "aggressive" variant sinks across more than just
pixelLocal-to-pixelLocal boundaries:

- A `.fusedPixelLocalCluster` can absorb a pixelLocal successor
  by extending its `members` array;
- A `.neighborRead` node can tag its trailing sink on
  `Node.tailSinkedBody` for codegen to splice into the write path;
- `.nativeCompute` successors are skipped because the compiler
  can't modify an opaque kernel's write logic.

Worth running after `VerticalFusion` + `KernelInlining` + `CSE`
because those earlier passes expose new tail-sink opportunities by
producing clusters and folding duplicates.

**Boundary**: Tail Sink is a graph-rewrite that fuses bodies into
producer kernels. It is **not** about routing the tail node's
output into the caller-supplied drawable — that "final blit"
question is handled separately by the dispatch layer at
`encode(into:source:steps:writingTo:)`, not by the optimiser.

---

### 4.17 Multi-Pipeline isolation

DCRenderKit supports multiple `Pipeline` instances coexisting in
the same process. Typical scenarios:

- A camera-preview tab and a photo-editor tab are both
  instantiated; the camera Coordinator and the editor Coordinator
  each own a long-lived Pipeline.
- A user starts an export (a transient Pipeline) while a preview
  is still running — three Pipelines briefly coexist.
- Two camera surfaces (e.g. picture-in-picture) each render into
  their own MTKView with a dedicated Pipeline.

**Choice**: every `Pipeline` accepts injected resources at
construction time. The default `Pipeline()` no-arg init binds
every dependency to the SDK-wide `.shared` instances, which is
correct for single-renderer apps. Apps with multiple concurrent
Pipelines should inject independent pools where budget contention
matters.

**Categorisation of resources**:

| Resource | Default | Multi-Pipeline strategy | Why |
|---|---|---|---|
| `Device` | `.shared` | Always share | Single GPU per process |
| `TextureLoader` | `.shared` | Share | Stateless |
| `SamplerCache` | `.shared` | Share | Sampler descriptors immutable |
| `PipelineStateCache` | `.shared` | Share | PSOs are immutable; cache key includes library identity (see §4.14, library-aware key) so independent libraries don't collide on same kernel name |
| `UberKernelCache` / `UberRenderPipelineCache` | `.shared` | Share by default; inject independent only for test isolation | Uber kernel hashes already exclude uniforms; cross-Pipeline reuse is pure win |
| `ShaderLibrary` | `.shared` | Share by default; **inject independent if you register custom shaders dynamically per Pipeline** | The only correctness risk is name collision when two Pipelines register different shaders under the same name — independent libraries solve this |
| `TexturePool` | `.shared` | **Inject independent for budget isolation** | Memory budget is global; one Pipeline's bursty allocation can starve another |
| `CommandBufferPool` | `.shared` | **Inject independent for in-flight CB budget** | Concurrent CB count is global; a 1-shot export can block 30fps preview |
| `UniformBufferPool` | `.shared` | **Inject independent if rapid uniform churn matters** | Slot-pool fence-blocks under contention |

**Convenience factories**: `Pipeline.makeIsolated(...)` constructs
a Pipeline with **independent texture / CB / uniform pools** but
**shared PSO caches and ShaderLibrary** — the standard shape for
"two Pipelines in two tabs." `Pipeline.makeFullyIsolated(...)`
gives every dependency a fresh instance — used by tests and the
rare case where shader-name conflicts require library separation.

**Diagnostics**: `Pipeline.diagnostics` returns a snapshot of the
Pipeline's per-instance utilisation (texture bytes cached,
uniform slots in use, uber-kernel PSO count). Apps can call this
on a 1 Hz timer to feed a HUD; the demo's
`MultiPipelineStatusView` is a working example.

**Origin**: Phase 12 (post-Phase-11 multi-Pipeline support).

---

### 4.18 Pipeline coexistence patterns

The three canonical Pipeline budget profiles in the bundled Demo
illustrate common multi-Pipeline shapes:

#### Real-time preview (camera, video)

```swift
Pipeline.makeIsolated(
    textureBudgetMB: 16,            // 6× rgba16Float 1080p frames
    maxInFlightCommandBuffers: 3,    // 30fps double-buffer + safety
    uniformPoolCapacity: 4
)
```

Source frames are small (1080p), filter chain is per-frame, slider
churn moderate. The texture pool is small but in-flight CB count
is 3 to keep GPU busy without dropping frames.

#### Interactive editing (full-res photo)

```swift
Pipeline.makeIsolated(
    textureBudgetMB: 64,             // 4K source + multi-pass intermediates
    maxInFlightCommandBuffers: 2,    // interactive but not stale-queued
    uniformPoolCapacity: 6           // rapid slider drags update many filters
)
```

4K rgba16Float source ≈ 32 MiB, multi-pass intermediates after
aliasing peak around 24-48 MiB; 64 MiB covers comfortably.
Uniform-slot churn is higher than camera (slider drags update
many filters in parallel) so allocate 6 slots.

#### One-shot export (no live preview)

```swift
Pipeline.makeIsolated(
    textureBudgetMB: 256,            // 4K full-pass peak
    maxInFlightCommandBuffers: 1,    // export is one-shot
    uniformPoolCapacity: 1           // single dispatch
)
```

Export pays a transient large allocation but doesn't need
double-buffering. Critically, the export Pipeline must be
**isolated from any concurrent preview Pipeline** — a 256 MiB
transient pool that shared budget with a 16 MiB preview pool
would starve the preview.

#### Decision tree

When designing a new Pipeline owner, ask:

1. **Will my Pipeline coexist with others?** No → just use
   `Pipeline()`. Yes → continue.
2. **Will my allocations be very different in size from
   neighbours' (10×+ disparity)?** Yes → use `makeIsolated` with
   appropriately sized pools. No → `Pipeline()` with shared pools
   is fine.
3. **Do I register custom shaders that other Pipelines should
   not see?** Yes → use `makeFullyIsolated` (or pass an explicit
   `shaderLibrary:` to the full init).
4. **Am I in a test that needs precise PSO compile counts /
   pool budget observations?** Yes → `makeFullyIsolated`.

**Origin**: Phase 12.

---

## 5. Cross-references

- [`foundation-capability-baseline.md`](foundation-capability-baseline.md) —
  the 18-claim capability catalogue.
- [`api-freeze-review.md`](api-freeze-review.md) — the v0.1.0
  commitment sheet per public type.
- [`release-criteria.md`](release-criteria.md) — the tiered
  release-readiness checklist.
- [`session-handoff.md`](session-handoff.md) — the per-session
  history that seeded this document.
- [`contracts/`](contracts/) — per-Tier-3-filter contract documents.
- [`maintainer-sop.md`](maintainer-sop.md) — operational playbook
  pointing back to these architecture docs from the review side.
- [`filter-development.md`](filter-development.md) — complete guide
  for adding a new filter: algorithm selection, NodeKind choice,
  fusion compatibility, uniform struct design, and test matrix.
- [`multi-pipeline-cookbook.md`](multi-pipeline-cookbook.md) —
  3 working recipes for running multiple `Pipeline` instances
  with the right resource isolation strategy.

---

## 6. Maintenance

This document is committed for the v0.x series. Add a new §4.N
entry whenever a PR lands that changes a layering boundary or
introduces a new cross-cutting primitive. Point the new entry at
the commit / session that landed it so future readers can recover
context.

The `foundation-capability-baseline.md` document tracks individual
capabilities; this document tracks the relationships between
capabilities — how they fit into a coherent execution model. Both
are maintained during pre-1.0; divergence between them should be
treated as a documentation bug.
