# Foundation Capability Baseline

The checklist below enumerates the SDK's architectural guarantees —
each one a concrete, verifiable property of the codebase, not a
marketing claim. The purpose is two-fold:

1. **Downstream confidence.** A consumer choosing between image-
   processing SDKs can walk this list and verify the claims by
   inspecting the cited file / test, without relying on Trust Me
   It's Good.
2. **Regression discipline.** Every item here is backed by code or
   tests; future PRs that would regress an item must either (a) fix
   the item, (b) update this document with the reason for
   relaxation, or (c) be rejected. The list is therefore a soft
   invariant — an item moving out of "satisfied" is a signal that
   something eroded, not just a documentation stale-ness issue.

Each entry has a **claim** (the capability), **evidence** (where to
look in the tree), and **why it matters** (what breaks without it).

The list is organised by category; order inside each category is
roughly by the radius of consumer impact (things they'd notice
immediately first, infrastructural guarantees last).

---

## 1. Dependency & Platform Hygiene

### 1.1 Zero external Swift Package dependencies

- **Claim**: `Package.swift.dependencies` is empty. The SDK does not
  transitively pull in any third-party code.
- **Evidence**: `Package.swift` — the `dependencies: []` array with
  an explanatory comment; enforced by
  `Tests/DCRenderKitTests/PackageManifestTests.swift :
  testPackageHasNoExternalDependencies`, which fails the build if
  any `.package(url:…)` sneaks in.
- **Why it matters**: no transitive CVEs, no supply-chain
  compromise surface, no Swift-version mismatches imported from
  upstream. The only framework dependencies are system ones
  (Metal, MetalKit, optional CoreVideo / Vision /
  MetalPerformanceShaders) — they ship with the OS.

### 1.2 iOS-only business layer, macOS retained only as a test host

- **Claim**: every `public` API compiles on iOS. macOS 15 is
  retained in `Package.swift.platforms` solely to run
  `swift test` against a real Metal GPU on CI; no NSImage /
  AppKit / macOS-specific business APIs are shipped.
- **Evidence**: `Package.swift.platforms: [.iOS(.v18),
  .macOS(.v15)]`; no `#if canImport(AppKit)` branches in
  `Sources/`; `PipelineInput.uiImage(_:)` is gated on
  `canImport(UIKit)` (the only case compiled per-platform).
- **Why it matters**: the "linux-like" cross-platform inheritance
  that typically arrives alongside macOS support tends to bring
  subtle divergence (shader behaviours, color-space defaults,
  pixel formats). Keeping the SDK iOS-only removes that variable.

### 1.3 Swift 6 strict concurrency end-to-end

- **Claim**: both the SDK target and the test target build with
  `.swiftLanguageMode(.v6)`. All cross-actor captures are either
  `Sendable` by construction or annotated `@unchecked Sendable`
  with a written-out justification.
- **Evidence**: `Package.swift` `swiftSettings`; the
  `@unchecked Sendable` conformances in the codebase
  (`NormalBlendFilter`, `PortraitBlurFilter`, `LUT3DFilter`,
  `Pipeline`, various pool / cache classes) each carry an
  inline comment explaining why the capture is safe.
- **Why it matters**: data races in a pipeline library fail
  silently at first (wrong pixels, not crashes) and surface in
  production on customers' devices. Strict concurrency front-loads
  the audit to build time.

---

## 2. Correctness Architecture

### 2.1 Typed error hierarchy

- **Claim**: `PipelineError` is a closed Swift enum with five
  domains (`device`, `texture`, `pipelineState`, `filter`,
  `resource`) and their cases are exhaustively typed. No
  `NSError`, no untyped `Error` round-trips.
- **Evidence**: `Sources/DCRenderKit/Error/PipelineError.swift`.
  Each domain's cases include structured context (e.g.
  `TextureError.formatMismatch(expected:got:)`), not opaque
  strings. `LocalizedError` / `CustomStringConvertible`
  conformances make log output readable.
- **Why it matters**: callers can pattern-match on the top-level
  cases for coarse handling and drill into the domain enum for
  recovery — no stringly-typed error parsing.

### 2.2 16-float intermediate precision as the pipeline default

- **Claim**: `Pipeline.intermediatePixelFormat` defaults to
  `.rgba16Float`, and the default is threaded into
  `MultiPassExecutor` rather than inherited from
  `source.pixelFormat`. An 8-bit camera feed still produces 16-bit
  intermediates between filters.
- **Evidence**: `Pipeline.swift` init defaults;
  `Pipeline.executeMultiPass` passes
  `intermediatePixelFormat` into `MultiPassExecutor.execute`'s
  `sourceInfo` rather than reading `source.pixelFormat`.
- **Why it matters**: filters like HighlightShadow / Clarity
  produce `ratio > 1.0` or sub-`1/255` residuals. An 8-bit
  intermediate silently truncates these, yielding visible banding
  on long chains. The 16-float default avoids that without the
  consumer having to ask.

### 2.3 Multi-pass DAG executor

- **Claim**: filters can declare a topologically-ordered graph of
  compute passes via `MultiPassFilter.passes(input:) -> [Pass]`.
  The executor validates the graph, allocates intermediates from
  the pool, routes inputs, and releases intermediates as soon as
  their last consumer has run.
- **Evidence**: `Sources/DCRenderKit/Core/MultiPassExecutor.swift`
  (≈300 lines). Validation enforces unique pass names, exactly
  one `isFinal`, no self-references, no forward references.
  Lifetime analysis computes last-use steps and releases eagerly
  inside the CB, with a deferred enqueue to avoid cross-CB
  hazards. `Sources/DCRenderKit/Core/PassGraphVisualizer.swift`
  renders the graph to text or Mermaid for debugging.
- **Why it matters**: multi-pass filters (pyramid bloom, guided
  filter, two-pass Poisson) are common in image processing. Without
  a framework-level executor each filter reimplements the texture-
  lifetime boilerplate — a frequent source of leaks and cross-frame
  texture reuse hazards.

### 2.4 Caller-supplied auxiliary textures

- **Claim**: a `MultiPassFilter` can declare
  `additionalInputs: [MTLTexture]` and reference them from any pass
  via `PassInput.additional(Int)`. The pipeline plumbs the textures
  through to every pass that needs them, not just the first.
- **Evidence**: `Sources/DCRenderKit/Core/MultiPassFilter.swift`
  defines the API; `MultiPassExecutor.resolveInputs` bounds-checks
  the index and selects the right texture per pass;
  `Tests/DCRenderKitTests/IntegrationTests/PortraitBlurMaskPipelineTests.swift`
  verifies the DigiCam-style mask-routing path end-to-end.
- **Why it matters**: subject masks, LUTs, and blend overlays are
  natively supported without each filter inventing its own
  convention. A two-pass filter with a mask (like PortraitBlur)
  doesn't have to cache the mask texture in its own struct state
  or bolt it onto every pass's `inputs`.

### 2.5 Texture pool with cross-CB deferred enqueue

- **Claim**: intermediate textures are returned to a thread-safe
  LRU pool only **after** the command buffer that last read them
  completes on the GPU. Concurrent pipelines on separate command
  buffers never observe each other's in-flight textures.
- **Evidence**: `Sources/DCRenderKit/Resources/TexturePool.swift`
  (the pool primitive — LRU + memory-pressure eviction on iOS);
  `Sources/DCRenderKit/Pipelines/Pipeline.swift :
  scheduleDeferredEnqueue` (the deferred-enqueue wrapper, with a
  written-out rationale for why intra-CB early enqueue was wrong);
  `Tests/DCRenderKitTests/DeferredEnqueueTests.swift` (regression
  coverage).
- **Why it matters**: a naive pool that enqueues as soon as a step
  finishes encoding looks correct because the first CB hasn't
  been submitted — but Metal's hazard tracking only protects
  within a single CB. Another pipeline's CB can dequeue the
  texture and start writing while the first CB reads on the GPU.
  Subtle corruption follows. The deferral closes it.

### 2.6 Command-buffer-fenced uniform pool

- **Claim**: `UniformBufferPool` reserves a unique buffer per
  command buffer per dispatch. A single CB with N large-uniform
  dispatches gets N distinct backing stores; pooled buffers free
  only on CB completion.
- **Evidence**: `Sources/DCRenderKit/Resources/UniformBufferPool.swift`
  (Slot-with-reservation design, grows on demand up to
  `maxBuffers`, falls back to one-off allocation at the cap);
  `Tests/DCRenderKitTests/ResourceManagementTests.swift`
  (`UniformBufferPoolTests`) verifies reservation release.
- **Why it matters**: the earlier ring-buffer design could wrap
  inside a single CB, silently overwriting an earlier dispatch's
  uniforms before the GPU reached it. The bug manifests only
  under long filter chains and is near-impossible to repro
  post-facto — pre-empting it via a fence is cheaper than
  debugging it in production.

### 2.7 Shader library dual-path loading

- **Claim**: `ShaderLibrary` loads a pre-compiled
  `default.metallib` when the SDK is consumed as an xcframework
  (Xcode's Metal toolchain produces one), and falls back to
  compiling every `.metal` source at runtime when consumed via
  `swift build` / SwiftPM CLI (which does not run the Metal
  compiler on resources).
- **Evidence**: `Sources/DCRenderKit/Core/ShaderLibrary.swift :
  tryLoadDefaultLibrary` — two strategies with logging.
- **Why it matters**: `swift test` would otherwise fail on any
  machine without Xcode's Metal compiler in the chain. Runtime
  compilation is slower on first use (~10-30 ms) but amortised
  by the PSO cache across a session.

---

## 3. Colour Space & Algorithm Foundation

### 3.1 One-line `.linear` / `.perceptual` switch

- **Claim**: `DCRenderKit.defaultColorSpace` flips the SDK between
  "mathematically-correct linear-light" and "DigiCam-parity
  gamma-encoded" modes. All colour-space-sensitive filters branch
  on this flag; the MTKView drawable pixel format is derived
  automatically via `DCRColorSpace.recommendedDrawablePixelFormat`.
- **Evidence**: `Sources/DCRenderKit/Core/DCRColorSpace.swift`
  (the enum + helpers); `Sources/DCRenderKit/DCRenderKit.swift`
  (the global default); consumption points in every tone-space
  filter.
- **Why it matters**: the choice between "linear for
  correctness" and "gamma for parity" is a real trade-off with
  different answers for different products. Forcing a rebuild
  (not a runtime toggle) means the compiler strips the unused
  branch out of hot paths — no per-pixel overhead from the
  switch itself.

### 3.2 Principled Tier 2 tone operators

- **Claim**: the tone-adjustment filters (Contrast, Blacks,
  Whites, Exposure) each implement a published, principled
  primitive rather than a fitted polynomial:
  - `ContrastFilter`: DaVinci Resolve log-space slope
    `y = pivot · (x/pivot)^slope`, `slope = exp2(c · 1.585)`.
  - `BlacksFilter`: Reinhard toe with scale
    `y = x / (x + ε·(1 − x))`.
  - `WhitesFilter`: Filmic shoulder `y = ε·x / ((1 − x) + ε·x)` —
    algebraic mirror of the Blacks toe.
  - `ExposureFilter` negative branch: pure linear gain
    `y = clamp(x · gain, 0, 1)`, `gain = exp2(ev)`. Positive
    branch is Reinhard tonemap.
- **Evidence**: `Sources/DCRenderKit/Filters/Adjustment/**/*.swift`
  — every filter's Swift doc comment includes a
  `Model form justification` block citing the operator's
  published reference (Reinhard 2002, DaVinci log-space slope
  via ACES RRT, Hable's Filmic 2010).
  `Tests/DCRenderKitTests/ToneAdjustmentFilterTests.swift`
  verifies each operator's response at slider extremes and the
  identity condition.
- **Why it matters**: fitted polynomial curves optimise
  in-sample fit against a specific reference but drift out-of-
  sample; a filmic grading primitive generalises across content
  because it was derived to. The single-parameter Blacks / Whites
  primitives are easier to tune than the prior 2-parameter fits,
  and the DaVinci log-slope gives a predictable "±1.585 stops of
  contrast at slider ±100" consumer convention.

### 3.3 Linear / perceptual parity 315-point sweep guard

- **Claim**: a test sweep runs each tone-space filter twice —
  once in `.perceptual` mode, once in `.linear` mode with the
  input gamma-inverted — and requires the outputs match to
  within 2-3% after re-gamma-encoding the linear result.
  Formal replacement for the subjective "feel drift" in
  `docs/findings-and-plan.md` §7.3.
- **Evidence**:
  `Tests/DCRenderKitTests/LinearPerceptualParityTests.swift` —
  5 filters × 7 slider positions × 9 input grey levels = 315
  grid points per run.
- **Why it matters**: the `.linear` / `.perceptual` flip
  (capability 3.1) is only useful if both modes feel equivalent;
  otherwise consumers choose between "correct but visually
  drifted" and "visually matched but mathematically wrong". The
  parity sweep makes that equivalence a CI-checked property.

### 3.4 Canonical IEC 61966-2-1 sRGB transfer

- **Claim**: the SDK uses the true piecewise sRGB transfer
  function (`12.92·c` below `0.0031308`, `1.055·c^(1/2.4) − 0.055`
  above), not the `pow(c, 2.2)` approximation. A single canonical
  implementation in `Foundation/SRGBGamma.metal` is mirrored into
  eight filter shaders (`// MIRROR: Foundation/SRGBGamma.metal`);
  the mirrors are byte-identical and verified by tests.
- **Evidence**:
  `Sources/DCRenderKit/Shaders/Foundation/SRGBGamma.metal`
  (canonical helpers plus three test kernels);
  `Tests/DCRenderKitTests/SRGBGammaConversionTests.swift`
  (12 round-trip / known-value cases at Norman Koren Zone
  midpoints).
- **Why it matters**: the `pow(2.2)` approximation diverges from
  the true curve by up to ~2% at midtones. Every pipeline that
  mixes gamma / linear representations (which is every non-
  trivial pipeline) accumulates that error per conversion. The
  canonical helpers close the loophole.

### 3.5 OKLCh perceptual colour grading

- **Claim**: Saturation and Vibrance operate in OKLCh (Ottosson
  2020). `L` (perceptual lightness) and `h` (hue) are preserved
  on chroma scaling; a binary-search gamut clamp protects
  clipping cases while preserving `L` and `h`.
- **Evidence**:
  `Sources/DCRenderKit/Shaders/Foundation/OKLab.metal` (canonical
  matrices + gamut clamp);
  `Sources/DCRenderKit/Shaders/ColorGrading/{Saturation,
  Vibrance}/*.metal` (mirror the helpers);
  `Tests/DCRenderKitTests/OKLabConversionTests.swift` +
  `Tests/DCRenderKitTests/Contracts/{Saturation, Vibrance}*.swift`
  verify the round-trip and semantic contracts.
- **Why it matters**: Rec.709-luma-anchored saturation shifts
  perceived lightness at the gamut boundary (blue-purple is the
  classic failure mode). OKLCh was designed explicitly for
  image-processing chroma manipulation and is the CSS Color
  Level 4 / 5 standard — using it means the SDK's "increase
  saturation" command produces the same result a CSS-conformant
  renderer would.

### 3.6 Fast Guided Filter shared primitives

- **Claim**: `HighlightShadowFilter` and `ClarityFilter` both
  consume a shared three-kernel Fast Guided Filter (He & Sun,
  2015) with different `eps` / radius parameters. The
  implementation is factored into `Foundation/GuidedFilter.metal`
  so the two consumers share code, not copy it.
- **Evidence**:
  `Sources/DCRenderKit/Shaders/Foundation/GuidedFilter.metal`
  (the three shared kernels: `DCRGuidedDownsampleLuma`,
  `DCRGuidedComputeAB`, `DCRGuidedSmoothAB`); the
  `HighlightShadowFilter.passes` and `ClarityFilter.passes`
  graphs both reference them with different uniform values.
- **Why it matters**: changes to the guided filter happen in
  one place; both filters benefit or regress together. The
  contracts in `docs/contracts/highlight_shadow.md` and
  `docs/contracts/clarity.md` document each consumer's
  parameter choices (`eps = 0.01` vs. `0.005`, radius 1.2%
  vs. 1.9% of quarter-res short side) with the design
  rationale for the difference.

---

## 4. Verification & Quality Gates

### 4.1 Tier 3 filter contracts

- **Claim**: the five perception-based filters (Vibrance,
  Saturation, HighlightShadow, Clarity, SoftGlow) each ship a
  `docs/contracts/<filter>.md` document declaring ≥ 6 measurable
  clauses (identity, direction, gamut, selectivity, …), each
  clause with a fetched URL reference and a test case.
- **Evidence**: `docs/contracts/*.md` (five files, ≥ 6 clauses
  each, 35+ clauses total);
  `Tests/DCRenderKitTests/Contracts/*.swift` (the contract test
  files); `ContractTestHelpers.swift` supplies shared OKLab
  transform reference CPU-side so the assertions are derived
  independently of the Metal shader under test.
- **Why it matters**: "perceptual" filters are famously hard to
  pin down — "looks right" is not a testable property. The
  contract approach decomposes each filter into measurable
  properties and asserts each one, so a future refactor can't
  silently regress a subtle behaviour.

### 4.2 Snapshot regression for Tier 4 aesthetic filters

- **Claim**: the aesthetic filters (FilmGrain, CCD, PortraitBlur)
  are frozen by 8-bit PNG snapshots with per-pixel |Δ|
  comparison. First-run writes the baseline; subsequent runs
  fail on drift past tolerance (default 2% — above the Float16
  quantisation floor, below "looks different" perception).
- **Evidence**:
  `Tests/DCRenderKitTests/SnapshotAssertion.swift` (the
  primitive, 8-bit-PNG + max-channel-Δ comparison with
  file-adjacent storage under `__Snapshots__/`);
  `SnapshotAssertionTests.swift` exercises the framework itself;
  TODO #37 / #38 / #39 track the real-device baseline-freeze
  step for the three aesthetic filters.
- **Why it matters**: aesthetic filters don't have the
  measurable clauses Tier 3 does, but they can regress visually
  across refactors. Snapshot regression catches drift without
  needing to list each possible failure mode.

### 4.3 MTLCommandBuffer.gpuStart/EndTime benchmark

- **Claim**: `PipelineBenchmark` measures end-to-end GPU wall-
  clock time for a filter chain via
  `MTLCommandBuffer.gpuStartTime` / `gpuEndTime`, with no
  Instruments dependency and no external tooling. Returns median
  / p95 / min / max / stddev across a configurable sample count
  after warmup.
- **Evidence**:
  `Sources/DCRenderKit/Statistics/PipelineBenchmark.swift`;
  `Tests/DCRenderKitTests/PipelineBenchmarkTests.swift` verifies
  the statistics primitive.
- **Why it matters**: downstream consumers can measure their
  specific chain's performance from inside their own test suite
  without needing to spin up Instruments. The SDK does **not**
  enforce hard performance thresholds in CI (pre-release
  decision — see `docs/release-criteria.md`), but the primitive
  exists for consumers who want to.

### 4.4 Test coverage parity with surface

- **Claim**: every filter source file has at least one test
  file. Contract filters have both a unit test and a contract
  test. Shared infrastructure (Pipeline, MultiPassExecutor,
  Dispatchers, Resource pools, TextureLoader) each have their
  own test file. Smoke tests exercise representative multi-
  filter chains to catch integration regressions.
- **Evidence** (as of the `0.1.0-dev` cycle): 329 tests across
  ~30 test files covering 16 filter sources, 5 Tier 3 contracts
  with 35+ clauses, 11 SmokeTests, 14 Pipeline tests, 20
  Infrastructure tests, 27 ResourceManagement tests, and six
  basic-infra self-tests added in Session C (snapshot, parity
  sweep, package manifest, sRGB, OKLab, benchmark). CI runs on
  macos-15 + Xcode 16.
- **Why it matters**: a test count is a proxy for discipline,
  not coverage per se — but the one-test-file-per-source-file
  floor plus the five contract suites plus the parity /
  snapshot frameworks mean no filter is shipped without some
  verifiable property asserted.

---

## 5. Out-of-scope guarantees (intentional gaps)

Some properties a reader might expect from a "professional" image-
processing SDK are **not** guaranteed, by design:

- **External-app pixel parity** (Lightroom / Photoshop / Pixel
  Cake / etc.). DCRenderKit commits to principled operators with
  documented contracts; it does not chase bit-exact parity with
  any specific third-party tool. Session C convergence made this
  explicit; `docs/findings-and-plan.md` §8.5 is archived under
  that decision.
- **Hard CI performance thresholds.** `PipelineBenchmark` is a
  measurement primitive, not a gate — number-targets are
  device-dependent and the SDK has no authority to enforce them
  across consumer hardware.
- **Cross-platform support** (macOS business layer, Catalyst,
  tvOS, visionOS, Android). iOS-only is a commitment; consumers
  who need broader platform support should wrap the SDK
  themselves or wait for an explicit v1.x expansion.
- **HDR inputs beyond the `[0, 1]` clamp.** Filters assume
  input values are in `[0, 1]` (linear or gamma depending on
  colour-space mode). Proper HDR support — wide-gamut +
  > 1.0 luma values flowing through the chain — is Phase 2.
- **Video time-domain stability.** Every contract is defined
  for a single still image. Temporal consistency (frame-to-
  frame stability of Tier 3 / Tier 4 filters) is Phase 2 and
  would require per-filter contract additions.

These gaps are documented so consumers can decide before adopting
whether the SDK's scope fits their product. They're not silent.

---

## 6. How to use this document

### 6.1 For adopters

Walk the list. Items in §1-§4 are things the SDK actively
guarantees and tests — pick the ones that matter for your use case,
grep the cited paths, satisfy yourself they mean what they say.
Items in §5 are non-guarantees — if any are blockers for your
product, raise them in Discussions / Issues before adopting.

### 6.2 For contributors

A PR that would regress an item is a PR against this baseline.
Such PRs should either:

1. Restore the item in the same change set, or
2. Update this document (ideally in the same PR) explaining the
   relaxation — and that relaxation needs explicit maintainer
   buy-in per `docs/maintainer-sop.md` §3 (breaking changes).

Additions to the baseline are welcome and should come with the same
claim / evidence / rationale trio.

### 6.3 For maintainers

This file is one of three "architecture truth" documents
(together with `docs/release-criteria.md` and
`docs/session-handoff.md`). A release that would violate an item
here without a corresponding update is an instability signal;
refer to the maintainer SOP for the full procedure.
