# Architecture

A short overview of DCRenderKit's layered execution model. The
full cross-cutting design narrative lives at
[`docs/architecture.md`](https://github.com/xiaosen11/DCRenderKit/blob/main/docs/architecture.md);
this article is the DocC-accessible TL;DR.

## Overview

Consumer code touches two surfaces: ``Pipeline`` (for execution)
and the filter protocols (``FilterProtocol`` /
``MultiPassFilter``) for writing or extending filters. Everything
else is internal machinery reachable through dependency injection
if advanced use cases demand isolation.

## The five layers

1. **Entry (``Pipeline``)**: resolves input via ``TextureLoader``,
   runs the chain through the pipeline compiler (lowering,
   optimisation, lifetime-aware allocation), dispatches every
   resulting graph node, and returns the final texture.
2. **Filters**: 16 ship in the SDK; custom filters conform to
   ``FilterProtocol`` (single-pass) or ``MultiPassFilter``
   (DAG-based).
3. **Dispatchers**: ``ComputeDispatcher``, ``RenderDispatcher``,
   ``BlitDispatcher``, ``MPSDispatcher``. Filter authors can
   invoke these directly when a custom filter needs a specific
   encoder primitive.
4. **Core / Foundation**: internal execution machinery
   (``Pass``, ``TextureInfo``, shader foundations for sRGB /
   OKLab / guided filter). Mostly for reading rather than reaching
   into.
5. **Resources** (injectable pools / caches): ``Device``,
   ``TexturePool``, ``UniformBufferPool``, ``CommandBufferPool``,
   ``PipelineStateCache``, ``SamplerCache``, ``ShaderLibrary``.

## Execution flow

For `pipeline.process(input:steps:)` / `pipeline.encode(into:source:steps:writingTo:)`:

1. ``TextureLoader`` resolves source to an `MTLTexture`.
2. The pipeline compiler runs: `Lowering` translates the chain to
   a `PipelineGraph`, `Optimizer` rewrites it (DCE, vertical
   fusion, CSE, kernel inlining, tail sink) under
   ``PipelineOptimization/full``, and
   `LifetimeAwareTextureAllocator` assigns pooled textures with
   interval-graph aliasing.
3. ``CommandBufferPool`` hands out a concurrency-limited command
   buffer.
4. The pipeline walks the optimised graph, batching contiguous
   pixel-local clusters into a single chained render pass with
   programmable blending and dispatching every other node through
   ``ComputeBackend`` or ``ComputeDispatcher``.
5. The chain's tail-node output is handed back either as a
   texture or blitted into a caller-supplied drawable.
6. `addCompletedHandler` fires on CB completion and returns
   intermediates to the pool for the next frame's dequeue.

## Tier classification of filters

| Tier | Validation                                       | Filters                                              |
| ---- | ------------------------------------------------ | ---------------------------------------------------- |
| 1    | Formula is spec (identity / extreme / direction) | ``ExposureFilter`` (positive), ``SharpenFilter``, ``NormalBlendFilter``, ``LUT3DFilter`` |
| 2    | Principled tone operator + `LinearPerceptualParityTests` sweep | ``ContrastFilter``, ``BlacksFilter``, ``WhitesFilter``, ``ExposureFilter`` (negative), ``WhiteBalanceFilter`` |
| 3    | Per-filter contract document + contract tests    | ``HighlightShadowFilter``, ``ClarityFilter``, ``SoftGlowFilter``, ``SaturationFilter``, ``VibranceFilter`` |
| 4    | Snapshot regression (real-device baseline)       | ``FilmGrainFilter``, ``CCDFilter``, ``PortraitBlurFilter`` |

## Key cross-cutting decisions

Eighteen architectural decisions anchor the design; each is
explained in `docs/architecture.md` §4. The highlights:

- **rgba16Float intermediates** (§4.1) — no 8-bit banding in long
  chains.
- **`.linear` / `.perceptual` toggle** (§4.2) — one-line compile-
  time flip.
- **Principled tone operators** (§4.4) — DaVinci log-slope for
  contrast, Reinhard toe for blacks, Filmic shoulder for whites.
- **Tier 3 contracts** (§4.5) — perception-based filters pin
  measurable behaviour.
- **Cross-CB deferred texture enqueue** (§4.7) — no cross-CB
  hazard under concurrent pipelines.
- **PassInput.additional(_:)** (§4.10) — caller-supplied masks /
  LUTs reach every pass in a multi-pass graph.
- **CompiledChainCache** (§4.14) — per-Pipeline fingerprint
  memoization skips Lowering + Optimizer + Planner on cache hits.
  Fingerprint hashes uniform bytes; without this, slider drags
  silently dispatch stale uniforms.
- **Long-lived Pipeline** (§4.15) — `Pipeline` is a renderer,
  not a recipe. Create once per view; pass `source` + `steps` at
  each `encode` call. Per-frame construction wipes the cache.
- **Frame Graph stream B optimizations** (§4.16) — DCE, vertical
  fusion, CSE, kernel inlining, tail sink, plus
  `TextureAliasingPlanner`. Vertical fusion has four hard
  interruption conditions (neighborRead, fan-out, resolution
  change, `final` flag); everything else fuses automatically under
  `PipelineOptimization.full`.
- **Multi-Pipeline isolation** (§4.17 / §4.18) — multiple `Pipeline`
  instances coexist with injectable `TexturePool` /
  `CommandBufferPool` / `UniformBufferPool` for budget isolation
  while still sharing `PipelineStateCache` / `UberKernelCache` /
  `ShaderLibrary` for compile-time amortisation. Use
  `Pipeline.makeIsolated(...)` for the standard "two tabs" shape;
  `Pipeline.makeFullyIsolated(...)` for tests that need complete
  separation. See `docs/multi-pipeline-cookbook.md` for recipes.

For the full treatment, see
[`docs/architecture.md`](https://github.com/xiaosen11/DCRenderKit/blob/main/docs/architecture.md).
