# ``DCRenderKit``

A commercial-grade Metal image-processing SDK for iOS 18+.

## Overview

DCRenderKit is an independent, principled-algorithms image
pipeline. It ships 16 filters across 4 correctness tiers, a
declarative multi-pass DAG executor, injectable resource pools,
and one-line-switchable `.linear` / `.perceptual` colour spaces.

### The 30-second version

```swift
import DCRenderKit

let pipeline = Pipeline(input: .uiImage(inputImage), steps: [
    .single(ExposureFilter(exposure: 10)),
    .single(ContrastFilter(contrast: 20, lumaMean: 0.5)),
    .multi(HighlightShadowFilter(highlights: -20, shadows: 15)),
    .single(SaturationFilter(saturation: 1.2)),
    .single(LUT3DFilter(cubeURL: lutURL, intensity: 0.8)),
])
let output = try await pipeline.output()
```

### What makes this SDK different

- **Zero external dependencies.** Only system frameworks (Metal,
  MetalKit, optional CoreVideo / Vision /
  MetalPerformanceShaders). No transitive supply-chain risk.
- **Principled tone operators** (Contrast → DaVinci log-slope,
  Blacks → Reinhard toe, Whites → Filmic shoulder, Exposure →
  linear gain + Reinhard). Published grading primitives, not
  fitted polynomials.
- **16-float intermediates** between every filter — no 8-bit
  banding in long chains.
- **Tier 3 contracts** pin perception-based filters (Vibrance,
  Saturation, HighlightShadow, Clarity, SoftGlow) to measurable
  clauses with fetched-URL references.
- **iOS 18+ only.** Strict Swift 6 concurrency; `@Sendable`
  enforced end-to-end.

See <doc:GettingStarted> for an adoption walkthrough and
<doc:Architecture> for the layered execution model.

## Topics

### Getting started

- <doc:GettingStarted>

### Core entry points

- ``Pipeline``
- ``AnyFilter``
- ``PipelineInput``
- ``FilterGraphOptimizer``

### Filter authoring protocols

- ``FilterProtocol``
- ``MultiPassFilter``
- ``ModifierEnum``
- ``FuseGroup``
- ``FilterUniforms``
- ``TextureInfo``
- ``Pass``
- ``PassInput``
- ``TextureSpec``

### Shipping filters — tone adjustment (Tier 1–2)

- ``ExposureFilter``
- ``ContrastFilter``
- ``BlacksFilter``
- ``WhitesFilter``
- ``SharpenFilter``

### Shipping filters — perception-based (Tier 3)

- ``HighlightShadowFilter``
- ``ClarityFilter``
- ``SoftGlowFilter``
- ``SaturationFilter``
- ``VibranceFilter``

### Shipping filters — colour grading / blend / LUT

- ``WhiteBalanceFilter``
- ``NormalBlendFilter``
- ``LUT3DFilter``
- ``CubeFileParser``

### Shipping filters — aesthetic (Tier 4)

- ``CCDFilter``
- ``FilmGrainFilter``
- ``PortraitBlurFilter``
- ``PortraitBlurMaskGenerator``

### Resources (injectable)

- ``Device``
- ``TextureLoader``
- ``DCRImage``
- ``TexturePool``
- ``TexturePoolSpec``
- ``UniformBufferPool``
- ``CommandBufferPool``
- ``PipelineStateCache``
- ``RenderPSODescriptor``
- ``BlendConfig``
- ``SamplerCache``
- ``SamplerConfig``
- ``ShaderLibrary``

### Dispatchers (filter-author primitives)

- ``ComputeDispatcher``
- ``RenderDispatcher``
- ``DrawCall``
- ``BlitDispatcher``
- ``MPSDispatcher``

### Observability

- ``DCRLogger``
- ``DCRLogLevel``
- ``OSLoggerBackend``
- ``DCRLogging``
- ``Invariant``
- ``ImageStatistics``
- ``PipelineBenchmark``
- ``PassGraphVisualizer``

### Errors

- ``PipelineError``
- ``DeviceError``
- ``TextureError``
- ``PipelineStateError``
- ``FilterError``
- ``ResourceError``

### Configuration

- ``DCRenderKit/DCRenderKit``
- ``DCRColorSpace``

### Architecture reference

- <doc:Architecture>
