# v0.1.0 GA Release Criteria

**Status as of 2026-04-23 (Session C end):** approximately 70% of the GA gates
are satisfied. The remaining 30% splits into (a) work I can do autonomously
that has been triaged but not yet executed, and (b) work that requires real-
device evaluation or user decisions. Both are enumerated below.

The philosophy: `v0.1.0` is the **first public-facing release**. Subsequent
`0.x` versions may ship breaking changes if they're documented in
`CHANGELOG.md` under a `Changed (breaking)` block, but the v0.1.0 surface
must be coherent enough that consumers can start depending on it.

---

## ✅ Gates satisfied

### Correctness foundation

- [x] **Tier 1 (formula-is-spec) filters pass unit tests**: Sharpen,
      NormalBlend, LUT3D, Exposure+
- [x] **Tier 2 (principled tone operators) replaced their fitted curves**
      with grading primitives:
  - [x] Contrast → DaVinci log-space slope
  - [x] Blacks → Reinhard toe (Filmic toe)
  - [x] Whites → Filmic shoulder (mirror of Blacks)
  - [x] Exposure negative → pure linear gain
  - [x] WhiteBalance kept YIQ + Kelvin (already principled)
- [x] **Tier 3 (perception-based) filters have documented contracts** in
      `docs/contracts/` with measurable clauses:
  - Vibrance / Saturation / HighlightShadow / Clarity / SoftGlow

### Architecture

- [x] Typed error hierarchy in `PipelineError`
      (5 domains × many cases, no `NSError` anywhere)
- [x] Multi-pass filter architecture supports caller-supplied auxiliary
      textures (`PassInput.additional` + `MultiPassFilter.additionalInputs`)
- [x] Texture pool has cross-command-buffer deferred enqueue (no intra-CB
      reuse hazard)
- [x] Uniform pool is command-buffer-fenced (no ring-buffer overwrite
      under long chains)
- [x] Shader library loads both pre-compiled metallib (xcframework path)
      and runtime-compiled .metal (SwiftPM CLI path)
- [x] `.linear` / `.perceptual` color-space toggle with one-line flip
      via `DCRenderKit.defaultColorSpace`

### Documentation (English + Chinese)

- [x] `README.md` — overview, quick-start, filter catalogue, docs links
- [x] `CONTRIBUTING.md` — environment, rules, contract requirements
- [x] `CODE_OF_CONDUCT.md` — Contributor Covenant 2.1
- [x] `CHANGELOG.md` — keep-a-changelog with `[Unreleased]` populated
- [x] `LICENSE` (MIT)
- [x] `docs/contracts/` — per-filter measurable-behaviour contracts
- [x] `docs/findings-and-plan.md` — rigorous-audit plan

### CI + repo hygiene

- [x] GitHub Actions CI on macos-15 / Xcode 16 (swift build + swift test
      on macOS; xcodebuild build on iOS Simulator; Demo build too)
- [x] Lint job: no bare FIXME / TODO / HACK (must have `(§…)` or `(#…)`
      reference), no `.package(url:)` in Package.swift
- [x] Issue templates (bug / feature) + PR template
- [x] `PackageManifestTests` regression guard on zero-dependencies

### Regression / benchmark infrastructure

- [x] **Snapshot regression harness** (`SnapshotAssertion`) — 8-bit PNG
      baseline with per-channel |Δ| comparison, self-tested
- [x] **Linear/perceptual parity sweep** — 315 grid-point checks across
      5 tone-space filters guarantee `.linear` feel drift < 2-3%
- [x] **Pipeline benchmarking** (`PipelineBenchmark`) — median / p95 /
      stddev using `MTLCommandBuffer.gpuStart/EndTime`, no Instruments
      dependency

### Contract tests

- [x] 5 Tier 3 filter contract test suites (35+ cases) in
      `Tests/DCRenderKitTests/Contracts/`
- [x] Full test suite: **327 tests pass, 0 failures** at Session C end
      (HEAD `40feef5`)

---

## ⏳ Gates pending — I can do autonomously

### Code-quality polish (can land before v0.1.0)

- [ ] **`@available(iOS 18.0, *)` annotation sweep** (#47)
      across every top-level `public` declaration (44 types / enums /
      classes / extensions). Redundant with Package.swift platform
      constraints for now, but makes future per-API deprecation easy.
- [ ] **`internal` / `fileprivate` strict audit** (#48). The current
      `public` surface may contain types that should be demoted (e.g.
      pool internals, some helpers). Downgrading in v0.1.0 is free;
      downgrading in v0.2 is a breaking change.
- [ ] **Public API freeze review + breaking-changes catalog** (#49).
      Walk every public type and sign off on its shape. Emit a
      `docs/api-freeze-review.md` that enumerates what's committed to
      for v0.1.0.
- [ ] **SwiftDoc completeness audit** (#59). Every `public` symbol
      should have a doc comment; the review also catches "doc comment
      says X, signature says Y" drift.
- [ ] **Zero-warning build** (`swift build -warnings-as-errors`) (#72).
- [ ] **Zero TODO / FIXME audit** (#71). The `.claude/rules/` convention
      is already that every FIXME carries a `(§…)` reference; the audit
      verifies nothing has slipped and either resolves or converts any
      outstanding FIXMEs to GitHub issues.
- [ ] **OKLab / SRGB mirror → Metal preprocessor** (informal follow-up
      to #76). Replace the MIRROR-comment pattern with a build-time
      `#include`-resolving step. Purely internal, no API impact.

### Release plumbing

- [ ] **DocC catalog + GitHub Pages deploy** (#57, #61). Generate
      browsable API docs at `https://xiaosen11.github.io/DCRenderKit/`.
      Can be done as a follow-on: DocC doesn't block v0.1.0 source
      release, only "polished docs website".
- [ ] **Release-automation workflow** (#62). Tag push → release draft
      + CHANGELOG entry extraction + artifact upload. Not needed for
      first release (`git tag v0.1.0 && git push --tags` works); useful
      afterwards.
- [ ] **`v0.1.0` tag** (#63) — the last step, once everything above is
      in the "done" column.
- [ ] **Maintainer SOP + code-review process** (#70). Short document
      describing how PRs are reviewed and how releases cut.
- [ ] **Architecture docs** (#58) — extract the "why" from per-session
      handoffs into a permanent `docs/architecture.md`. Can follow
      v0.1.0.

### Platform validation

iOS-only at the business layer; macOS retained as a `swift test`
host. Cross-platform expansion tasks (#44 macOS / #45 Catalyst /
#46 tvOS/visionOS) were dropped at Session C convergence, and the
NSImage / AppKit code paths were stripped from the SDK. No
additional platform-validation work is required for v0.1.0.

---

## 🧑 Gates pending — user action required

These gates cannot advance without real-device evaluation or explicit
product decisions. They block v0.1.0 to the extent that we consider
"visual quality on real user content" a release criterion; they do NOT
block a tag + first-download milestone if we're willing to ship "SDK
compiles + contracts pass" quality first.

### Real-device visual regression

- [ ] **Tier 3 five-filter real-device regression** (formalised in the
      Session C handoff test plan, not yet in a TODO ticket). HS /
      Clarity / SoftGlow / Vibrance / Saturation each at slider
      {-100/-50/0/+50/+100} on real photographs. Contracts pass on
      synthetic patches; user-ceiling evaluation is still required.
- [ ] **#75 PortraitBlur** slider +100 evaluated on-device. Shader
      coefficient 0.030 (this Session's choice) produces effective
      46 px @ 1080p / 92 px @ 4K blur; user confirms whether this
      matches the Apple Portrait / Lightroom feel target. Shader
      `kDCRPortraitBlurCoef` has documented tuning directions if the
      first attempt misses in either direction.
- [ ] **#37 FilmGrain baseline freeze** — gated on real-device
      confirmation that current output is satisfying.
- [ ] **#38 CCD baseline freeze** — same.
- [ ] **#39 PortraitBlur baseline freeze** — gated on #75 above.

### Product decisions

- [ ] **#11 Pixel-Cake JPEG export decision**. If the user wants
      external Tier 2 ground-truth anchoring, 20 JPEGs (4 sliders × 5
      filters) need to be exported for SSIM comparison; otherwise we
      ship "matches DCR's own principled operators" without external
      app parity.
- [ ] **#46 tvOS / visionOS support decision**. If yes, platforms
      manifest and CI matrix expand; if no, `Package.swift` can stay
      as-is and the decision is documented as "out of scope for 0.x".
- [ ] **#52 DigiCam migration audit**. PortraitBlurFilter and
      WhitesFilter had API-breaking changes this Session that require
      DigiCam call-site updates. This is a downstream concern — v0.1.0
      can ship first and DigiCam upgrades as part of adopting it.

### Third-party comparison

Dropped at Session C convergence. DCRenderKit is an independent
principled-operators codebase; no external-library parity is
pursued. The per-filter `Model form justification` blocks + the
per-contract clauses in `docs/contracts/` are the commitment.

---

## Release-go/no-go summary

Three tiers of v0.1.0 meaning:

1. **Minimal viable release** — SDK compiles, unit tests green,
   documented, installable. All `✅ Gates satisfied` above. **Achieved
   today.** The project can be tagged `v0.1.0-rc.1` and published.

2. **Consumer-grade release** — plus the `@available` sweep, API
   freeze review, SwiftDoc completeness, zero-warning build. **All
   autonomous; can be finished in one more focused session.**

3. **Visual-quality-committed release** — plus real-device
   confirmation that the Tier 3 perception filters and Tier 4
   aesthetic filters look good to the user at slider extremes. **Gated
   on user.**

Each tier is a valid v0.1.0. The question for the maintainer is which
tier to commit to in the release notes.
