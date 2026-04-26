# Filter Development Guide

A complete walkthrough for adding a new filter to DCRenderKit —
from algorithm selection to framework integration to testing.

This guide has three parts:

- **Part 1 — Algorithm selection** (mandatory pre-code step)
- **Part 2 — Framework integration** (how to slot into the pipeline without causing performance degradation)
- **Part 3 — Testing requirements** (what a merged filter must prove)

---

## Part 1 — Algorithm selection

> **Rule**: No code before the algorithm is chosen and justified. This
> is enforced by `.claude/rules/filter-development.md`.

### Step 1: Classify the filter by dimension

| Type | Characteristic | Examples | Algorithm rule |
|------|---------------|---------|----------------|
| **1D per-pixel** | one pixel in → one pixel out | Exposure, Contrast, Saturation, Whites, Blacks | List ≥2 principled candidates; empirical fitting is a last resort |
| **2D neighbourhood** | reads neighbouring pixels | Sharpen, Blur, Edge detection | Must be based on a textbook algorithm with a citable source |
| **Multi-scale** | needs multiple resolution levels | Bloom, Highlight/Shadow, Clarity | Must use pyramid / guided filter / equivalent multi-pass structure |

### Step 2: List principled algorithm candidates

- **1D**: S-curve / power-law / log-curve / Extended Reinhard / parametric tone curve / Filmic curve…
- **2D**: Laplacian unsharp mask / Sobel / Gaussian / Bilateral / Guided Filter / Kuwahara…
- **Multi-scale**: Dual Kawase / Laplacian Pyramid / Mip Chain / Gaussian Pyramid / Local Laplacian…

Empirical fitting (choosing a formula because its MSE is lowest against a reference) is allowed only
if every principled candidate fails. Document why in the filter's doc comment.

### Step 3: Verify against an industry reference

Use WebSearch to find at least one industry implementation (paper / open-source project / official
tutorial) that confirms your chosen algorithm is the conventional solution for this problem class.

Source priority:
1. SIGGRAPH / ACM papers
2. LearnOpenGL / NVIDIA GPU Gems
3. darktable / RawTherapee / GIMP source code
4. Adobe / DaVinci Resolve / Apple official documentation
5. Personal blogs (lowest priority — supporting reference only)

### Step 4: Write the model-form justification in the doc comment

Every filter's doc comment must contain:

```swift
/// Model form justification:
///   - Type: [1D per-pixel | 2D neighbourhood | multi-scale]
///   - Algorithm: [specific algorithm name + paper/tutorial reference]
///   - Why not [alternative]: [reason]
```

**Red flag**: if the justification says "lowest MSE", "best result in testing", or "I tried several
formulas and this one fit best" — go back to Step 2.

---

## Part 2 — Framework integration

DCRenderKit's pipeline compiler runs five graph rewrites on every filter chain — Dead Code
Elimination (DCE), Vertical Fusion, Common Sub-Expression Elimination (CSE), Kernel Inlining,
and Tail Sink — plus the `TextureAliasingPlanner` (see `docs/architecture.md §4.16`).
A new filter must be designed so it participates in these optimisations rather than defeating them.

### 2.1 The four node kinds and their fusion behaviour

The most important integration decision is which `NodeKind` your filter produces. This is determined
by what your Metal shader needs to read.

| NodeKind | What it can read | GPU encoder | Fusion | Typical CPU cost |
|----------|-----------------|-------------|--------|-----------------|
| `pixelLocal` | only the same (x, y) pixel | Compute (uber kernel) when isolated; fragment when in a Phase-8 multi-cluster chain | **Fuses** into adjacent `pixelLocal` nodes | ~0 marginal if fused |
| `neighborRead` | any pixel within a neighbourhood | Compute | **Never fuses** | ~300 µs encoder setup |
| `nativeCompute` | any texel, arbitrary dispatch | Compute | **Never fuses** | ~300 µs encoder setup |
| `multiPass` | full DAG with texture dependencies | Per-pass (compute / blit / MPS / render) | N/A — handled by `MultiPassFilter` | Per-pass cost × N passes |

**Decision rule**: choose the weakest node kind that satisfies the algorithm.

- Pure per-pixel colour/tone operation → `pixelLocal`
- Needs any pixel other than (x, y) → `neighborRead` or `nativeCompute`
- Has internal texture dependencies or multiple outputs → `multiPass`

### 2.2 Writing a fusion-compatible `pixelLocal` filter

A `pixelLocal` filter automatically fuses with adjacent `pixelLocal` nodes under
`PipelineOptimization.full`. No annotation is needed. The only requirement is that
`FilterProtocol.passes(input:)` returns a single pass with kind `.pixelLocal`.

```swift
// Fragment shader — reads only (x, y) from input texture.
// This is the cheapest node kind. It fuses for free.
kernel void myFilter_fragment(/* ... */) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    half4 src = in.read(gid);
    // per-pixel operation only — no texture2d<>.sample() with offset
    out.write(result, gid);
}
```

**What breaks fusion** (four hard interruption conditions):

1. **`neighborRead` or `nativeCompute` kind** — any compute dispatch interrupts the current
   fragment cluster. The node before and the node after each get their own pass.

2. **Fan-out** — if an intermediate node's output is consumed by two or more downstream nodes,
   the compiler cannot fuse across the fork because the intermediate value must remain
   observable. Avoid fan-out in single-branch chains; it is only valid in DAG-based
   `MultiPassFilter` graphs.

3. **Resolution change** — if your filter outputs a texture at a different size than its input
   (e.g. a downscale pass in a pyramid), fusion is interrupted. The new resolution requires a
   new pooled texture; the compiler cannot merge a resolution-changing pass into an existing
   cluster.

4. **`final` flag** — setting `final = true` on a pass signals that this pass is a terminal
   colour-management step and should not have further filters fused after it. Use this only
   for filters that do their own gamma encode or apply a final LUT. Unnecessary use of `final`
   silently prevents all downstream fusion.

### 2.3 Understanding the performance ceiling

Phase 11 + VerticalFusion + TextureAliasingPlanner represent the current architectural optimum.
This section documents what is reducible and what is not, so filter authors have realistic
expectations.

**Reducible with correct filter design:**

| Cost | Reducible by | Mechanism |
|------|-------------|-----------|
| Extra encoder setup per pass | Using `pixelLocal` when possible | Fusion collapses N passes into 1 |
| Extra texture round-trip per pass | Using `pixelLocal` when possible | Fusion eliminates intermediate write+read |
| Peak heap pressure | Keeping intermediate texture count low | Aliasing shares slots across non-overlapping lifetimes |

**Irreducible regardless of filter design:**

| Cost | Why it cannot be eliminated |
|------|----------------------------|
| ~300 µs CPU per non-fused dispatch | Metal encoder setup is a fixed cost per compute command encoder |
| GPU execution time for each shader | Irreducible — that is the actual filter cost |
| One dispatch per `neighborRead` / `nativeCompute` node | These cannot be fused; each needs its own encoder |
| O(N compile) on first chain shape | Cached after first encounter, but the first frame pays it |

**Concrete example** — a chain with 14 filters including 4 multi-pass (HighlightShadow 5-pass,
Clarity 5-pass, SoftGlow 7-pass, PortraitBlur 2-pass) produces ~29 dispatches and takes
~5–10 ms CPU encode time. This is expected behaviour; it is not a framework bottleneck.
Adding one more `pixelLocal` filter adds zero marginal cost if it fuses; adding one more
`neighborRead` filter adds ~300 µs CPU + one texture round-trip.

### 2.4 Uniform struct design for correct fingerprinting

The `CompiledChainCache` fingerprints chains by hashing every node's uniform bytes (see
`architecture.md §4.14`). Incorrect uniform struct design can produce silent cache bugs.

**Rules:**

1. **All semantically distinct filter states must produce distinct byte representations.** If two
   different slider values that should produce different visual output happen to round to the same
   bytes, the cache will serve stale results.

2. **Use `Float`, not `Double`.** Metal buffers do not support `double`. On Swift side, `Double`
   and `Float` have different byte widths — a mismatch corrupts the uniform layout.

3. **Pad explicitly for Metal alignment.** Metal requires `float4` members to be 16-byte aligned.
   Add explicit `var _pad: Float = 0` members rather than relying on implicit Swift layout.

4. **Keep the struct small.** All bytes are hashed on every encode call. A 256-byte uniform struct
   hashes 256 bytes per encode; a 16-byte struct hashes 16. For typical filter parameters
   (3–8 floats), keep structs under 64 bytes.

5. **Do not store non-deterministic values in uniforms.** `random()`, `Date()`, `UUID()`, or any
   expression whose value changes between calls must never live in a `uniforms` computed property.
   The pipeline rebuilds filters on every frame for real-time preview; non-deterministic uniforms
   produce flicker. Compute random seeds once (at filter construction time) and store them as
   `let` constants.

### 2.5 Spatial parameters — size-aware pixel distances

Filters with pixel-distance parameters (grain size, sharpening step, chromatic aberration offset)
must follow `.claude/rules/spatial-params.md`. The short version:

| Parameter type | Formula | Example |
|---------------|---------|---------|
| Visual texture (grain, sharpening edge width) | `basePt × pixelsPerPoint` | `grainSize = 1.5 × pixelsPerPoint` |
| Image structure (guided filter radius, blur radius) | `shortSide × ratio` or `quarterW × ratio` | `radius = shortSide × 0.025` |
| Pure colour/tone | no adaptation needed | Exposure gain, saturation factor |

`pixelsPerPoint` is injected by the caller; filters must not import UIKit or read screen scale
directly. The parameter flows through `FilterUniforms` as a plain `Float`.

### 2.6 Texture aliasing — what filter authors must not do

The `TextureAliasingPlanner` may assign your filter's output texture to a slot that is later
reused by a subsequent filter's input. This is safe because the planner guarantees non-overlapping
live ranges. However:

- **Do not hold strong `MTLTexture` references to intermediate outputs past a pass boundary.**
  If you cache an intermediate texture returned from a `Pass.output`, it may contain different
  content on the next frame.
- **Do not read from a `Pass.input` texture after the pass has returned.** The planner considers
  that texture's live range ended at the pass boundary.
- `MultiPassFilter` graphs that pass textures between internal passes via `PassInput.additional(_:)`
  are exempt — those textures are caller-managed and not aliased.

---

## Part 3 — Testing requirements

Every merged filter must pass the minimum test matrix from `.claude/rules/testing.md`. The table
below maps test categories to the framework concerns in Part 2.

| Test category | What it verifies | Framework concern |
|--------------|-----------------|-------------------|
| Identity (zero params → output ≈ input) | Filter is a no-op at default | Uniform correctness |
| Extreme values don't crash | ±100 produces finite, in-gamut output | Bounds check in Metal kernel |
| Directionality (positive param → brighter / darker) | Effect direction matches documentation | Shader correctness |
| Numerical (typical input matches formula ± tolerance) | Shader implements the chosen algorithm | Algorithm correctness |
| Contract (SDK-promised behaviour is observable) | Public API invariants hold | `pixelFormat`, `width`, `height` post-encode |
| **Source format coverage** | `bgra8Unorm` AND `rgba16Float` sources both tested | Format-path correctness |

For multi-scale and multi-pass filters, add:

| Additional test | What it verifies |
|----------------|-----------------|
| Intermediate texture format is `rgba16Float` | Aliasing planner picks the right format |
| Pass count matches design | `MultiPassFilter.passes(input:)` returns expected count |

---

## Checklist before opening a PR

- [ ] Algorithm chosen from principled candidates, justified in doc comment with model-form section
- [ ] Industry reference fetched (URL in doc comment or PR description)
- [ ] NodeKind is the weakest kind that satisfies the algorithm (see §2.1)
- [ ] Uniform struct uses `Float`, has explicit padding, contains no non-deterministic values
- [ ] Spatial parameters use `pixelsPerPoint` or image-ratio formula (not hardcoded pixel counts)
- [ ] Metal kernel has bounds check at entry (`if gid.x >= width || gid.y >= height return;`)
- [ ] `swift build` zero warnings
- [ ] `swift test` all green (including `bgra8Unorm` source coverage)
- [ ] Demo compiles (`xcodebuild Demo build`)
- [ ] No `TODO` / `FIXME` / `HACK` comments
- [ ] All public symbols have SwiftDoc
