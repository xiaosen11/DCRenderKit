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
   runs `steps` through ``FilterGraphOptimizer``, dispatches each
   step, and manages intermediate texture lifecycle.
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

For `pipeline.output()`:

1. ``TextureLoader`` resolves source to an `MTLTexture`.
2. ``FilterGraphOptimizer/optimize(_:)`` rewrites the step list
   (passthrough in Phase 1; fusion active in Phase 2).
3. ``CommandBufferPool`` hands out a concurrency-limited command
   buffer.
4. For each step:
   - ``AnyFilter/single(_:)`` → ``ComputeDispatcher/dispatch(kernel:uniforms:additionalInputs:source:destination:commandBuffer:psoCache:uniformPool:)``
     with a texture-pool-backed destination.
   - ``AnyFilter/multi(_:)`` → the internal multi-pass executor
     walks the filter's ``Pass`` graph, allocates intermediates,
     and dispatches each pass.
5. The chain's last-step output is handed back either as a
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

Thirteen architectural decisions anchor the design; each is
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

For the full treatment, see
[`docs/architecture.md`](https://github.com/xiaosen11/DCRenderKit/blob/main/docs/architecture.md).
