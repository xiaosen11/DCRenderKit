# Changelog

All notable changes to DCRenderKit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The project is pre-1.0; breaking changes happen without a major-version bump
until `v1.0.0`. Each breaking change is flagged explicitly below.

## [Unreleased]

### Added

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
