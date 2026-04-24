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
│    Pipeline(input: .uiImage(img), steps: […]).output() → tex   │
└───────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────┴─────────────────────────────────┐
│ Pipeline (Pipelines/)                                          │
│   · resolves source via TextureLoader                          │
│   · runs FilterGraphOptimizer (passthrough in Phase 1)         │
│   · chains outputs between steps, ping-pongs intermediates     │
│   · `.single(…)` → ComputeDispatcher                           │
│   · `.multi(…)`  → MultiPassExecutor (internal; #48)           │
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

## 3. Data flow for a single `output()` call

1. **Source resolution** (`TextureLoader`). `PipelineInput.uiImage`
   / `.cgImage` go through `MTKTextureLoader` with the SDK's
   `.linear` / `.perceptual` decision driving the `.SRGB` flag.
   `.pixelBuffer` (camera frames) goes through `CVMetalTextureCache`
   for zero-copy; BGRA vs BGRA_srgb is chosen from the colour-space
   mode. `.texture` passes through.
2. **Chain optimisation** (`FilterGraphOptimizer`). Phase 1 is
   passthrough — the step list is unchanged. Phase 2 will fuse
   adjacent same-`FuseGroup` filters into uber-kernels
   (`ToneFilter`, `ColorFilter`) to eliminate the per-filter
   16-float round-trip, but the API is already in place so the
   activation is a drop-in.
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
   the caller either as an `MTLTexture` (`outputSync()` /
   `output()` / `encode(into:)`) or blitted via MPS Lanczos into
   the caller's `CAMetalDrawable` / video-frame target
   (`encode(into:writingTo:)`).
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
