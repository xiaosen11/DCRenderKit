# v0.1.0 Public API Freeze Review

This document is the v0.1.0-candidate commitment sheet: every
top-level `public` type is listed here with an explicit stability
tier, so consumers can reason about what they can depend on during
the 0.x series and which surfaces are still in flux.

Filed per `docs/release-criteria.md` Tier 2 requirement #49.

---

## 1. Stability tiers

| Tier          | Meaning                                                                                                   |
| ------------- | --------------------------------------------------------------------------------------------------------- |
| **Stable**    | Source-compatible within the 0.x series unless explicitly flagged as a breaking change in `CHANGELOG.md`. |
| **Evolving** | Expected to see at least one shape-level change before `v1.0.0`. Each change will go through `CHANGELOG`. |
| **Experimental** | May be removed or reshaped without a `CHANGELOG` entry. Not recommended for production dependencies. |

During the pre-1.0 period, `CHANGELOG.md`'s
`[Unreleased] → Changed (breaking)` / `Removed (breaking)` blocks
are the authoritative log of breaking changes; this document is the
forward-looking commitment that gates those changes.

---

## 2. Public API surface (by category)

### 2.1 SDK meta

| Symbol                              | Kind   | Tier    | Notes                                              |
| ----------------------------------- | ------ | ------- | -------------------------------------------------- |
| `DCRenderKit`                       | enum   | Stable  | Namespace for SDK-level constants and configuration |
| `DCRenderKit.version`               | static | Stable  | SemVer string                                      |
| `DCRenderKit.channel`               | static | Stable  | `"dev"` / `"release"`                              |
| `DCRenderKit.defaultColorSpace`     | static | Stable  | One-line flip between `.linear` / `.perceptual`    |
| `DCRColorSpace`                     | enum   | Stable  | Two-case switch; new cases would require a major bump |

### 2.2 Pipeline / execution

| Symbol                    | Kind        | Tier     | Notes                                                    |
| ------------------------- | ----------- | -------- | -------------------------------------------------------- |
| `Pipeline`                | final class | Stable   | Entry-point type; init surface deliberately wide         |
| `Pipeline.output()`       | async       | Stable   | Preferred production API                                 |
| `Pipeline.outputSync()`   | throws      | Stable   | For tests / deterministic completion                     |
| `Pipeline.encode(into:)`  | throws      | Stable   | External CB control — for realtime renderers             |
| `Pipeline.encode(into:writingTo:)` | throws | Stable  | Presentation-path helper; MPS Lanczos bridge             |
| `PipelineInput`           | enum        | Stable   | Four cases (`texture` / `cgImage` / `pixelBuffer` / `uiImage`) |
| `AnyFilter`               | enum        | Stable   | `.single(…)` / `.multi(…)`                               |
| `FilterGraphOptimizer`    | struct      | Evolving | Phase 1 is passthrough; Phase 2 will add real fusion     |

### 2.3 Filter protocols

| Symbol              | Kind     | Tier   | Notes                                                          |
| ------------------- | -------- | ------ | -------------------------------------------------------------- |
| `FilterProtocol`    | protocol | Stable | Required by every single-pass filter; four protocol members    |
| `MultiPassFilter`   | protocol | Stable | Required by every multi-pass filter; two protocol members      |
| `ModifierEnum`      | enum     | Stable | Four dispatch targets (`.compute` / `.render` / `.blit` / `.mps`) |
| `FuseGroup`         | enum     | Evolving | Currently 2 cases (`toneAdjustment` / `colorGrading`); more will land alongside Phase 2 fusion |
| `FilterUniforms`    | struct   | Stable | POD wrapper; `.empty` + `init<T>(_:)`                          |
| `TextureInfo`       | struct   | Stable | `width`/`height`/`pixelFormat` tuple                           |
| `Pass`              | struct   | Stable | Factory methods (`Pass.compute` / `Pass.final`)                |
| `PassInput`         | enum     | Stable | Three cases (`source` / `named(_:)` / `additional(_:)`)        |
| `TextureSpec`       | enum     | Stable | Five cases for sizing intermediates                            |

### 2.4 Filters (16 — all **Stable** at 0.1.0)

The sliders / parameters on these structs **may still retune** their
ranges within the pre-1.0 window, but the filter shape itself
(public properties, identity conditions, slider extremes) is
committed:

| Filter                | Tier   | Stability note                                       |
| --------------------- | ------ | ---------------------------------------------------- |
| `BlacksFilter`        | Stable | Session C curve rewrite locked; shape stable         |
| `WhitesFilter`        | Stable | Same; `lumaMean:` parameter has been removed         |
| `ContrastFilter`      | Stable | DaVinci log-slope; stable                            |
| `ExposureFilter`      | Stable | Positive Reinhard / negative linear gain; stable     |
| `SharpenFilter`       | Stable | Unsharp mask; `step` is pt×pixelsPerPoint-driven     |
| `HighlightShadowFilter` | Stable | Guided filter + Zone-system windows; stable        |
| `ClarityFilter`       | Stable | Guided filter residual; stable                       |
| `NormalBlendFilter`   | Stable | Source-over with overlay                             |
| `SaturationFilter`    | Stable | OKLCh; `s = 0` semantics changed from Rec.709 at v0.1 |
| `VibranceFilter`      | Stable | OKLCh Adobe-semantic selective + skin protect        |
| `WhiteBalanceFilter`  | Stable | YIQ + Kelvin piecewise                               |
| `CCDFilter`           | Stable | Compound aesthetic filter                            |
| `FilmGrainFilter`     | Stable | Sin-trick + symmetric SoftLight                      |
| `PortraitBlurFilter`  | Stable | Two-pass Poisson; `additionalInputs[0]` is the mask  |
| `SoftGlowFilter`      | Stable | Dual Kawase pyramid bloom                            |
| `LUT3DFilter`         | Stable | Software trilinear + dither                          |
| `CubeFileParser`      | Stable | `.cube` parser                                       |
| `PortraitBlurMaskGenerator` | Stable | Vision wrapper; `iOS 17+` gated (SDK deploy target is iOS 18) |

### 2.5 Infrastructure (injection points)

Consumers can inject custom instances of these via `Pipeline.init`'s
fully-specified constructor — so they stay public even though most
consumers use the shared defaults.

| Symbol                  | Kind        | Tier   | Notes                                                              |
| ----------------------- | ----------- | ------ | ------------------------------------------------------------------ |
| `Device`                | final class | Stable | Wrapper over `MTLDevice`; `.shared` / `.tryShared`                 |
| `TextureLoader`         | final class | Stable | Four input paths; `.shared`                                        |
| `DCRImage` (typealias)  | typealias   | Stable | `= UIImage` under `canImport(UIKit)`                               |
| `TexturePool`           | final class | Stable | LRU pool with memory-pressure eviction                             |
| `TexturePoolSpec`       | struct      | Stable | Request descriptor                                                 |
| `UniformBufferPool`     | final class | Stable | CB-fenced pool for large uniforms (> 4 KB)                         |
| `CommandBufferPool`     | final class | Stable | Concurrency-limited CB factory                                     |
| `PipelineStateCache`    | final class | Stable | Compute + render PSO cache                                         |
| `RenderPSODescriptor`   | struct      | Stable | Render PSO compilation key                                         |
| `BlendConfig`           | struct      | Stable | Colour-attachment blending config                                  |
| `SamplerCache`          | final class | Stable | Sampler state cache                                                |
| `SamplerConfig`         | struct      | Stable | Request descriptor                                                 |
| `ShaderLibrary`         | final class | Stable | Registration / lookup point for custom Metal libraries             |

### 2.6 Dispatchers (filter-author primitives)

Consumers writing custom filters reach these directly:

| Symbol                  | Kind   | Tier   | Notes                                                                 |
| ----------------------- | ------ | ------ | --------------------------------------------------------------------- |
| `ComputeDispatcher`     | struct | Stable | `.dispatch(...)` is the de-facto entry for custom compute filters     |
| `RenderDispatcher`      | struct | Stable | `.dispatch(...)` / `.dispatchBatch(...)` for render-based filters     |
| `DrawCall`              | struct | Stable | Parameter type of `RenderDispatcher.dispatchBatch`                    |
| `BlitDispatcher`        | struct | Stable | Texture copies / mipmap generation                                    |
| `MPSDispatcher`         | struct | Stable | Optional Apple MPS layer (Gaussian blur / Lanczos / stats reduction)  |

### 2.7 Observability / ancillary

| Symbol                | Kind     | Tier     | Notes                                                |
| --------------------- | -------- | -------- | ---------------------------------------------------- |
| `DCRLogger`           | protocol | Stable   | Injection point for custom log sinks                 |
| `DCRLogLevel`         | enum     | Stable   | 5 levels                                             |
| `OSLoggerBackend`     | struct   | Stable   | Default `os.Logger`-backed implementation            |
| `DCRLogging`          | enum     | Stable   | Global accessor; `.logger` getter/setter             |
| `Invariant`           | enum     | Stable   | Defensive programming helpers for filter authors     |
| `ImageStatistics`     | enum     | Stable   | `lumaMean(of:)` (async)                              |
| `PipelineBenchmark`   | struct   | Stable   | Consumer-level timing primitive                      |
| `PipelineBenchmark.Result` | struct | Stable  | `medianMs` / `p95Ms` / `min` / `max` / `stdDev`      |
| `PassGraphVisualizer` | enum     | Stable   | `.render(passes:format:)` — debug utility            |

### 2.8 Error hierarchy (all **Stable**)

Every error case is documented and typed; consumers can pattern-
match on the top-level `PipelineError` cases or drill into each
domain enum.

| Symbol                | Kind | Tier   | Notes                                              |
| --------------------- | ---- | ------ | -------------------------------------------------- |
| `PipelineError`       | enum | Stable | Top level; 5 domain cases                          |
| `DeviceError`         | enum | Stable | Metal device / queue / encoder failures            |
| `TextureError`        | enum | Stable | Load / format / dimension issues                   |
| `PipelineStateError`  | enum | Stable | PSO compile / function lookup                      |
| `FilterError`         | enum | Stable | Parameter / pass-graph / fusion failures           |
| `ResourceError`       | enum | Stable | Pool exhaustion                                    |

---

## 3. Known breaking changes in the `[Unreleased]` set

All of these land in `v0.1.0` as the "starting state"; the
corresponding `CHANGELOG.md` entries are the adoption checklist for
anyone who followed `main` pre-release.

- **Session B** — `SaturationFilter` moved to OKLCh; `s = 0` now
  lands on OKLab-L-preserving grey rather than Rec.709 Y grey.
- **Session B** — `VibranceFilter` rewritten from GPUImage-family
  max-anchor to OKLCh selective + skin-hue protect.
- **Session C** — `ContrastFilter` / `BlacksFilter` / `WhitesFilter` /
  `ExposureFilter` (negative branch) replaced their fitted curves
  with principled operators; response shape differs at every
  non-zero slider position.
- **Session C** — `WhitesFilter.init`'s `lumaMean:` parameter
  removed; the Filmic shoulder doesn't need a scene-adaptive pivot.
- **Session C** — `PortraitBlurFilter` moved from `FilterProtocol`
  to `MultiPassFilter`; call sites must use `.multi(…)` not
  `.single(…)`.
- **Session C** — macOS business-layer paths removed (`PipelineInput.nsImage`,
  `TextureLoader.makeTexture(from: NSImage, ...)`, `typealias
  DCRImage = NSImage`). SDK is iOS-only at the API surface.
- **Session C** — sRGB helper shaders renamed from
  `dcr_{filter}LinearToGamma` to the canonical
  `DCRSRGBLinearToGamma` / `DCRSRGBGammaToLinear`.
- **Session D** — `MultiPassExecutor` demoted from `public` to
  `internal`. Pre-1.0 is the last window to do so without
  guaranteed adoption breakage.

---

## 4. Deprecation workflow (post-0.1.0)

Future deprecations of public API, in order:

1. **Announce**: Add `@available(iOS 18.0, *, deprecated, message: "…")`
   to the declaration, pointing at the replacement.
2. **Log**: `CHANGELOG.md [Unreleased] → Deprecated` entry with the
   affected symbol, reason, and replacement.
3. **Carry for one minor version**: do not remove in the same
   release that announces — consumers need at least one minor to
   migrate.
4. **Remove**: `CHANGELOG.md [Unreleased] → Removed (breaking)`
   entry; delete the declaration.

The one exception is security-driven removals, which follow the
`SECURITY.md` coordinated-disclosure timeline and may skip the
"carry for one minor" step.

---

## 5. What a consumer can count on

- Calling `Pipeline(input: .uiImage(img), steps: [.single(filter1),
  .multi(filter2), …])` will keep working across the 0.x series.
- Every `public` symbol in §2 will carry a migration note in
  `CHANGELOG.md` before it changes.
- The SDK will not introduce a new external dependency
  (`PackageManifestTests` enforces this).
- The iOS-18 deployment floor will not rise within 0.x.
- The 329-test suite size will not decrease; tests will be added
  for every new `public` behaviour.

---

## 6. Sign-off

This audit walked every `public` declaration in `Sources/` as
enumerated by `grep -rn "^public " Sources/`. Demotion decisions
are recorded in `CHANGELOG.md` and in the individual filter /
type source-file headers.

The v0.1.0 public surface **is the committed surface**. Subsequent
0.x releases may expand it (additive changes are not breaking) and
may demote or remove symbols per §4. `v1.0.0` will freeze the final
surface for the 1.x major series.
