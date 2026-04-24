# Changelog

All notable changes to DCRenderKit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The project is pre-1.0; breaking changes happen without a major-version bump
until `v1.0.0`. Each breaking change is flagged explicitly below.

## [Unreleased]

### Added

- **Pipeline compiler (Phase 5 step 5.1 – 5.2).** SDK built-in filters
  now dispatch through a runtime-compiled *uber kernel* produced by the
  Phase 1–3 pipeline compiler instead of the pre-compiler standalone
  `DCR<Name>Filter` symbols. Delivers the cross-filter fusion
  infrastructure that Phase 5 step 5.3 will use to collapse chains of
  pixel-local filters into a single dispatch. New additive public API:
  - `PipelineOptimization` enum (`.full` default, `.none` disables
    cross-filter fusion but keeps codegen). Introduced ahead of step 5.3
    so the API is stable when fusion flips on; in steps 5.1 – 5.2 both
    modes behave identically since each filter still dispatches
    independently.
  - `Pipeline.optimization: PipelineOptimization` property + new
    `optimization:` parameter on both initialisers (defaults `.full`;
    additive — every existing call site keeps compiling).
- **Integration tests for PortraitBlur mask routing**
  (`Tests/DCRenderKitTests/IntegrationTests/PortraitBlurMaskPipelineTests`).
  Three synthetic-source, half-split-mask scenarios covering the
  Demo→SDK path: spatial selectivity (proves `additional(0)` is
  consumed by both Poisson passes), a DigiCam-style edit chain
  (Exposure → Contrast → PortraitBlur(mask) → Saturation → Sharpen)
  confirming `additionalInputs` survives step-to-step texture handoff,
  and mask / source resolution mismatch exercising the shader's
  `gid / inputW * maskW` coordinate remap. All synthetic; Demo never
  gains an XCTest target. Test count 326 → 329.
- **Snapshot-regression harness** (`SnapshotAssertion.assertMatchesBaseline`).
  8-bit PNG baselines stored under `Tests/DCRenderKitTests/__Snapshots__/`.
  First run writes baseline + `XCTSkip`; subsequent runs fail on per-channel
  |Δ| drift past tolerance. Self-tested with `SnapshotAssertionTests`.
- **Pipeline benchmarking primitive** (`PipelineBenchmark.measureChainTime`).
  Measures end-to-end GPU time via `MTLCommandBuffer.gpuStart/EndTime` — no
  Instruments dependency. Returns median / p95 / min / max / stddev.
- **Linear/perceptual parity sweep** (`LinearPerceptualParityTests`).
  5 tone-space filters × 7 sliders × 9 input levels = 315 grid-point checks
  that the SDK's two color-space modes produce equivalent visual output.
  Formal replacement for the "feel drift" subjective description in
  `findings-and-plan.md` §7.3.
- **Foundation/SRGBGamma.metal** — canonical IEC 61966-2-1 piecewise sRGB
  transfer helpers (`DCRSRGBLinearToGamma` / `DCRSRGBGammaToLinear`) shared
  across 8 filter shaders via the MIRROR-comment pattern. Replaces 8 per-
  filter copies with differing names.
- **PortraitBlur two-pass Poisson architecture.** Second pass uses a
  90°-rotated Poisson pattern, yielding 32 uncorrelated sample positions and
  `σ · √2` effective radius — the Apple Portrait / Lightroom 50–100 px
  range at 1080p / 4K.
- **`MultiPassFilter.additionalInputs` + `PassInput.additional(Int)`.** Lets
  a multi-pass filter reference caller-supplied auxiliary textures
  (subject masks, LUTs, etc.) across its pass graph.
- **`PackageManifestTests.testPackageHasNoExternalDependencies`.** Regression
  guard that `.package(url:...)` can never sneak into `Package.swift`
  without breaking `swift test`.
- **`SRGBGammaConversionTests`** (12 cases) — IEC 61966-2-1 round-trip and
  known-value assertions at Norman Koren Zone-System midpoints.

### Changed (breaking)

- **`ContrastFilter`** — replaced fitted cubic pivot with DaVinci Resolve
  log-space slope `y = pivot · (x/pivot)^slope`, `slope = exp2(contrast ·
  1.585)`. Pivot still scene-adaptive (from `lumaMean`). Response shape at
  non-zero slider positions differs from the prior cubic.
- **`BlacksFilter`** — replaced fitted `y = x · (1 + k·(1-x)^a)` envelope
  with Reinhard-toe-with-scale `y = x / (x + ε·(1 − x))`, `ε = exp2(−slider
  · 1.0)`. Shadow-crush branch no longer clamps to zero at −100; soft
  (asymptotic) crush via Reinhard. Parameter count drops from 2 fitted to
  1 interpretable.
- **`WhitesFilter`** — replaced fitted weighted-parabola + luma-ratio +
  lumaMean-LUT with Filmic shoulder `y = ε·x / ((1 − x) + ε·x)`, `ε =
  exp2(slider · 1.0)`. Algebraic mirror of BlacksFilter's toe.
  **API break**: `lumaMean:` argument removed from `init`. The shoulder
  doesn't need a scene-adaptive pivot.
  Uniform struct shrinks from 16 bytes to 8.
- **`ExposureFilter` negative branch** — replaced fitted `A·x^γ + B·x`
  compound curve with pure linear gain (`y = clamp(x · gain, 0, 1)`,
  `gain = exp2(slider · 0.7 · 4.25)`). Positive branch (Reinhard
  tonemap) unchanged.
- **`PortraitBlurFilter`** — now conforms to `MultiPassFilter` (was
  `FilterProtocol`). Pipeline call sites use `.multi(filter)` instead of
  `.single(filter)`. Swift-side `×0.5` product compression removed; shader
  coefficient raised from `0.025 × shortSide` to `0.030 × shortSide` per
  pass, giving `0.0424 × shortSide` effective (two-pass) peak radius.
  At slider=100, real-device behaviour now matches Apple Portrait /
  Lightroom 50–100 px blur range; previously it was ≈ 14 px @ 1080p.
- **OKLCh Saturation** — operates in OKLab perceptual-lightness-preserving
  space (Ottosson 2020). At `saturation = 0` the result is OKLab-L-preserving
  gray, not Rec.709-Y-preserving. Typical difference < 0.05 in linear units.
- **Adobe-semantic Vibrance** — switched from a GPUImage-family
  max-anchor saturation to OKLCh low-chroma boost + warm-skin-hue
  protection. Already-saturated pixels get less boost than the prior
  curve; warm skin (≈ 45°±25° on OKLCh hue) is protected.

### Removed (breaking)

- **macOS business-layer support.** DCRenderKit is now iOS-only at
  the API surface. macOS 15 is retained in `Package.swift` as a
  `swift test` host (so the 300+ shader-driven tests can run against
  a real Metal GPU on CI), but no macOS business APIs are shipped:
  - `PipelineInput.nsImage(_:)` case removed.
  - `TextureLoader.makeTexture(from: NSImage, ...)` overload removed.
  - `typealias DCRImage = NSImage` branch removed.
  - `PortraitBlurMaskGenerator` `@available(iOS 17.0, macOS 14.0, *)`
    annotations tightened to `@available(iOS 17.0, *)`.
  - CI matrix no longer builds the AppKit framework configuration.

### Fixed

- **`xcodebuild docbuild` / xcframework metallib link**: `air-lld`
  was failing with `12 duplicated symbols for target air64_v27`
  on the OKLab helper functions. SwiftPM's per-`.metal` compilation
  model never co-links the mirrors (Foundation/OKLab.metal +
  SaturationFilter.metal + VibranceFilter.metal each become their
  own MTLLibrary), but Xcode's framework / DocC build pulls every
  shader source into a single default.metallib where `inline` was
  not enough to deduplicate the six OKLab helpers. Marked the six
  helpers `static inline` in all three files so each translation
  unit owns its private copy and the linker has nothing to merge.
  Inlining still drops the standalone copy at codegen, so runtime
  cost is zero. SRGBGamma helpers (already `inline`) were not
  affected by `air-lld` — left untouched. Xcode's
  `Product → Build Documentation` and the CI `docs` job (#61) now
  succeed.

### Removed (breaking)

- **`MultiPassExecutor` is now internal** (#48). The type is only
  reached through ``Pipeline`` via `.multi(filter)`; no consumer
  invoked `MultiPassExecutor.execute` directly, and pre-1.0 is the
  last window where the demotion is free (per the release-criteria
  note that #48 downgrading becomes breaking in 0.2+). Tests reach
  it through `@testable import DCRenderKit`.

### Removed

- `dcr_{filter}LinearToGamma` / `dcr_{filter}GammaToLinear` per-shader
  prefix-named sRGB helpers — replaced by the canonical
  `DCRSRGBLinearToGamma` / `DCRSRGBGammaToLinear` (MIRROR of
  `Foundation/SRGBGamma.metal`).
- `dcr_perceptualToLinearApprox` / `dcr_linearToPerceptualApprox` from
  `ExposureFilter.metal` (legacy names kept from the pre-IEC `pow(,2.2)`
  approximation era — renamed to the canonical DCR helpers).
- `WhitesFilter.lutInterpolate` (the LUT is gone with the shoulder rewrite).
- `WhitesFilter.init`'s `lumaMean:` argument (unused by the shoulder).

### Internal / docs

- **CCD structural test suite** (#93). Adds four per-arm isolation
  tests that run with the other CCD sub-effects disabled so each
  branch's invariant is asserted independently:
  chromatic-aberration R-left / B-right offset on a vertical colour
  boundary; saturation-boost identity on a grey patch;
  digital-noise block quantisation within a grain block with
  cross-block difference; and strength-mix linearity
  (`out_0.5 ≈ 0.5·(out_0 + out_1)`). `CCDFilter` test count rises
  from 2 → 6.
- **Typed-error regression suite** (`PipelineErrorTests`, #94).
  Central catalogue of the `PipelineError` hierarchy: every case
  across all five domains (`device` / `texture` / `pipelineState` /
  `filter` / `resource`) gets instantiated and asserted for
  non-empty diagnostic text and for payload surfacing
  (parameter names, error tokens, CoreVideo return codes).
  Pattern-match tests confirm `switch` on the top-level type
  selects the correct domain, and trigger tests drive
  `Invariant.require*` + `LUT3DFilter(cubeURL:)` +
  `LUT3DFilter(cubeData:dimension:)` through the typed throw path.
  15 new tests in a dedicated file — covers a gap the previous
  tests filled implicitly across multiple dispatcher / loader
  suites.
- **Release-automation workflow** (`.github/workflows/release.yml`,
  #62). Triggers on `v*` tags pushed to the repository; runs a
  `swift build -Xswiftc -warnings-as-errors` + `swift test`
  verification pass on the tagged commit, extracts the matching
  `## [X.Y.Z]` section from `CHANGELOG.md`, and publishes a GitHub
  Release with the section as the body. Pre-1.0 or suffixed tags
  (`v0.*`, `v1.0.0-rc.1`) are automatically marked as prereleases.
  Tags themselves are created by the maintainer per
  `docs/maintainer-sop.md` §2 — the workflow only reacts to the
  push.
- **DocC catalog + GitHub Pages deploy workflow** (#57 / #61).
  `Sources/DCRenderKit/DCRenderKit.docc/` contains three articles:
  `DCRenderKit.md` (landing page with full topic taxonomy),
  `GettingStarted.md` (adoption walkthrough), and
  `Architecture.md` (layered-model reference pointing at the full
  `docs/architecture.md`). A new `docs` CI job on `main` builds
  the catalog via `xcodebuild docbuild`, transforms the archive
  for static hosting, and publishes to GitHub Pages. The
  workflow runs only on `main` so PR CI stays fast; the public
  site is a snapshot of the latest merged commit. Deliberately
  no `swift-docc-plugin` dependency — the zero-external-
  dependency rule applies to build-time plugins too. Local
  preview is Xcode's Product → Build Documentation.
- **Architecture narrative document**
  (`docs/architecture.md`, #58). Distils the "why" behind 13
  cross-cutting architectural decisions from session handoffs into
  a permanent artifact: rgba16Float intermediates, .linear vs
  .perceptual mode toggle, typed error hierarchy, principled Tier 2
  tone operators, Tier 3 contracts, canonical IEC sRGB with the
  MIRROR pattern, cross-CB deferred texture enqueue, CB-fenced
  uniform pool, dual-path shader library loading,
  `PassInput.additional(_:)` routing, Fast Guided Filter shared
  primitives, OKLCh for chroma, and Tier 4 snapshot regression.
  Each entry carries choice / rejected / why / origin. Pairs with
  `foundation-capability-baseline.md` (capabilities) and
  `api-freeze-review.md` (surface commitments) as the three
  architecture-truth documents.
- **`@available(iOS 18.0, *)` sweep** (#47). Every top-level public
  declaration now carries the annotation — 64 types across Sources/
  (enums, structs, classes, protocols, typealiases). The SDK
  deployment target set in `Package.swift` already enforces
  iOS 18.0, so the annotations are redundant at the language level,
  but they give every public symbol an explicit per-API anchor for
  future `@available(*, deprecated, message:)` markers (see the
  deprecation workflow in `docs/api-freeze-review.md` §4). The
  three `@available(iOS 17.0, *)` annotations inside
  `PortraitBlurMaskGenerator` were raised to iOS 18 to match the
  enclosing type.
- **Public API freeze review document**
  (`docs/api-freeze-review.md`, #49). Walks every `public`
  declaration across 8 categories (SDK meta / pipeline execution /
  filter protocols / 16 filters / infrastructure injection / filter-
  author dispatchers / observability / error hierarchy) and assigns
  each symbol a **Stable** / **Evolving** / **Experimental** tier.
  Records the complete `[Unreleased]` breaking-change roster so
  adopters upgrading through the pre-release period have a single
  migration checklist. Codifies the post-0.1.0 deprecation
  workflow (announce → log → carry one minor → remove) and the
  consumer-facing "what you can count on" guarantees for the 0.x
  series.
- **SwiftDoc coverage sweep across filter layer** (#59 first pass).
  Added doc comments for the FilterProtocol / MultiPassFilter
  conformance members (`modifier`, `uniforms`, `additionalInputs`,
  `fuseGroup`, `passes(input:)`) and the `public init(…)` of every
  shipped filter: Blacks, Whites, Contrast, Exposure, Sharpen,
  HighlightShadow, Clarity, NormalBlend, Saturation, Vibrance,
  WhiteBalance, CCD, FilmGrain, PortraitBlur, SoftGlow, LUT3D.
  Also filled in per-member docs for `PipelineBenchmark.Result`
  (iterations / median / p95 / min / max / stddev). Closes the
  highest-volume gap from the audit; infrastructure-type public
  members (Pipeline / Device / TexturePool / …) were already
  documented at member level and do not need adjustment.
- **Zero unreferenced FIXME / TODO / HACK marker audit**. The CI
  lint rule that every marker carry a `(§…)` or `(#…)` reference
  catches contributor misses; this pass closed two false positives
  in the existing code (a `FIXME` keyword quoted as prose inside
  `CCDFilter.metal`'s comment, and a `TODO.md` filename reference
  inside `PackageManifestTests`'s XCTAssert message). The 19
  surviving `FIXME` markers — all tagged
  `(§8.6 Tier 2 [archived])` or `(§8.4 Audit.* [archived])` —
  denote empirical magic-number constants accepted as tier-2 tech
  debt pending the Tier 4 snapshot-freeze step (TODO #37/#38/#39).
- **Zero-warning audit across SDK + test targets**, locked as a CI
  gate via `-Xswiftc -warnings-as-errors` on both `swift build` and
  `swift test` steps. Fixed one Swift-6 Sendable-capture warning in
  `ResourceManagementTests` (extracted a local `poolRef` so the
  background closure no longer reaches into non-Sendable `self`) and
  the `#file` → `#filePath` default-argument divergence that
  surfaced across `SmokeTests`, `ColorGradingFilterTests`, and
  `ToneAdjustmentFilterTests`. `MultiPassAndLoaderTests`'s
  documentation-only test had a dead local variable removed.
- **Foundation capability baseline** (`docs/foundation-capability-baseline.md`).
  18 verifiable architectural claims grouped by category
  (dependency / platform, correctness architecture, colour-space &
  algorithm foundation, verification gates), each with an evidence
  path (code / test / doc) plus a "why it matters" rationale. Also
  lists five intentional out-of-scope gaps (external pixel parity,
  CI perf gates, cross-platform, HDR > 1.0, video temporal
  stability) so adopters can decide before adopting. Paired with
  `docs/release-criteria.md` and `docs/session-handoff.md` as the
  three architecture-truth documents that the maintainer SOP
  treats as non-negotiable.
- **GitHub Discussions guide** (`docs/discussions-guide.md`). Defines
  the four-category layout (Q&A / Show-and-tell / Ideas / General),
  posting / moderation conventions, and a one-time enablement
  checklist for the repo owner. Complements CONTRIBUTING.md's "open
  a Discussion for exploratory feature ideas" pointer.
- **Project governance documents** (`SECURITY.md` at the repo root,
  `docs/maintainer-sop.md` under docs/). `SECURITY.md` scopes the
  security-relevant surface, defines a tiered response SLA, and
  points reporters at GitHub's private-advisory form.
  `docs/maintainer-sop.md` is the maintainer-facing playbook: PR
  review checklist, release-cut sequence, breaking-change
  registration rules, security-response workflow, and an issue-triage
  baseline.
- **Tier 3 filter contracts** formalised in `docs/contracts/` for
  Vibrance, Saturation, HighlightShadow, Clarity, SoftGlow. Each carries
  ≥ 6 measurable clauses with derivation and industry-reference fetched
  URLs.
- Magic-number `FIXME` annotations clustered into §8.6 Tier 2 and
  §8.4 industry-audit categories (see `docs/findings-and-plan.md`).
- `.claude/rules/*.md` hard-constraint catalog expanded to 5 rules:
  `commit-verification`, `engineering-judgment`, `testing`,
  `filter-development`, `spatial-params`.
- Session-based work handoff documented in `docs/session-handoff.md`.

---

## Template for future releases

Once `v0.1.0` ships, subsequent entries follow this shape:

```
## [0.1.0] - YYYY-MM-DD

### Added
- …

### Changed
- …

### Deprecated
- …

### Removed
- …

### Fixed
- …

### Security
- …
```
