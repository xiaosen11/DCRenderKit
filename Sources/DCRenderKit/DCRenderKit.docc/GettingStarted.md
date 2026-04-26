# Getting Started

A practical walkthrough of integrating DCRenderKit into an iOS app.

## Overview

This article covers the shortest path from "I have a photo" to "I
have a filtered result on screen or on disk." For the layered
execution model behind the scenes, see <doc:Architecture>.

## Requirements

- iOS 18.0+ (Package.swift deployment target)
- Xcode 16+ / Swift 6.0
- A device or simulator with Metal support

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/xiaosen11/DCRenderKit", from: "0.1.0"),
]
```

Or add via Xcode's **File → Add Package Dependencies…** menu,
pointing at the repository URL.

### Zero external dependencies

DCRenderKit itself pulls in no third-party code — the only
requirement is system Metal. Your consuming app inherits no
transitive supply-chain risk from the SDK.

## First filter chain

```swift
import DCRenderKit

let pipeline = Pipeline()  // long-lived; reuse across many calls

func applyBasicChain(to image: UIImage) async throws -> MTLTexture {
    return try await pipeline.process(
        input: .uiImage(image),
        steps: [
            .single(ExposureFilter(exposure: 5)),
            .single(ContrastFilter(contrast: 15, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.1)),
        ]
    )
}
```

> Important: hold one `Pipeline` per renderer / view (e.g. one per
> `MTKView` coordinator). Building a fresh `Pipeline` per frame
> wipes the per-instance compiled-chain cache and reintroduces
> O(N) optimiser work that the cache exists to amortise. Slider
> drags / new source frames don't require a new Pipeline — pass
> the new uniforms / texture into the encode call instead.

`.single(…)` wraps a `FilterProtocol` filter. `.multi(…)` wraps a
`MultiPassFilter` for graph-based filters (Clarity,
HighlightShadow, SoftGlow, PortraitBlur).

## Input sources

`PipelineInput` accepts four source types:

| Case                      | Use case                                           |
| ------------------------- | -------------------------------------------------- |
| `.uiImage(_:)`            | A `UIImage` from the photo library / share extension |
| `.cgImage(_:)`            | A pre-decoded `CGImage`                            |
| `.pixelBuffer(_:)`        | Camera frames (`CVPixelBuffer` from AVFoundation)  |
| `.texture(_:)`            | An already-loaded `MTLTexture`                     |

## Choosing a colour space

`DCRenderKit.defaultColorSpace` is the SDK-wide mode selector.
Flip it at compile time if you want to change the numerical
domain:

- `.linear` (default) — mathematically correct scene-light space.
  Best for HDR-ready pipelines and radiometric operations.
- `.perceptual` — gamma-encoded space matching the DigiCam parity
  target. Lets you carry forward "legacy look" content without
  retuning.

Both modes pass the 315-grid-point parity tests, so either gives
the same "feel" — pick the one that matches your rendering
pipeline expectations.

## Rendering into a drawable

For real-time preview (e.g. camera), encode the chain into your
`MTKView`'s drawable in a single command buffer:

```swift
// Long-lived; created once when the view is set up.
let pipeline = Pipeline()

// Per-frame:
let commandBuffer = CommandBufferPool.shared.makeCommandBuffer(label: "Preview")
try pipeline.encode(
    into: commandBuffer,
    source: cameraTexture,        // resolved from CVMetalTextureCache
    steps: steps,
    writingTo: drawable.texture
)
commandBuffer.present(drawable)
commandBuffer.commit()
```

`encode(into:source:steps:writingTo:)` performs MPS Lanczos
resampling + format conversion automatically, so source resolution
and destination drawable resolution / pixel format don't have to
match.

## Multi-pass filters with masks

Portrait blur needs a subject mask. The SDK ships
`PortraitBlurMaskGenerator` for Vision-based mask generation:

```swift
import Vision

guard let cgImage = image.cgImage,
      let mask = PortraitBlurMaskGenerator.generate(from: cgImage)
else {
    // Vision couldn't detect a foreground subject — fall back to
    // an identity chain, a fully-blurred chain, or surface the
    // failure in your UI.
    return image
}

let output = try await pipeline.process(
    input: .uiImage(image),
    steps: [.multi(PortraitBlurFilter(strength: 80, maskTexture: mask))]
)
```

The mask reaches both Poisson passes via
`PassInput.additional(0)` — see
<doc:Architecture> §4.10 for the routing detail.

## Error handling

`PipelineError` is a closed enum with five domains. You can
`switch` on the top level for coarse retry logic:

```swift
do {
    let output = try await pipeline.process(input: input, steps: steps)
    // …
} catch PipelineError.device(.gpuExecutionFailed) {
    // Transient — retry once.
} catch PipelineError.filter(.parameterOutOfRange) {
    // Clamp the slider and try again.
} catch PipelineError.resource(.texturePoolExhausted) {
    // Memory pressure — call TexturePool.shared.clear().
} catch {
    // Everything else.
}
```

## Spatial parameters and display density

A subset of filters — `FilmGrainFilter`, `SharpenFilter`, `CCDFilter` —
accept pixel-distance parameters (grain size, sharpening step, chromatic-
aberration offset). These are **visual-texture parameters**: the user
should perceive the same physical grain / edge width on screen regardless
of source-image resolution or display pixel density.

The SDK does not auto-scale these parameters; that would require filters
to import UIKit. Instead, callers compute the scaling factor and pass it in:

```
pixelValue = basePt × pixelsPerPoint
```

where `pixelsPerPoint` = "how many source-image pixels map to one screen
point in the current rendering context."

### Computing `pixelsPerPoint`

| Context | Formula | Concrete example |
| ------- | ------- | ---------------- |
| **Camera preview** (MTKView 1:1 blit) | `Float(sourceTexture.width) / max(Float(view.bounds.width), 1)` | 1080-wide frame, 360 pt view → 3.0 |
| **Editing preview** (full image → scaled UIImage) | `Float(sourceTexture.width) / max(Float(view.bounds.width), 1)` | 4032-wide photo, 390 pt view → ~10.3 |
| **Export** (no live view) | cache the last value from the editing preview | same formula, stored when the preview last drew |

`view.bounds.width` is already in UIKit **points**, so it accounts for
the display scale factor automatically.

> Important: Do **not** pass `UIScreen.main.scale` directly. Screen scale
> (e.g. 3.0 on a 3× iPhone) is the display's pixel density, not the
> source–to–screen ratio. A 720-pixel-wide source on a 3× screen in a
> 390 pt view gives `pixelsPerPoint ≈ 720 / 390 ≈ 1.85`, not 3.0.

### Filters that do *not* need `pixelsPerPoint`

Pure colour-and-tone operations — `ExposureFilter`, `ContrastFilter`,
`SaturationFilter`, `WhiteBalanceFilter`, `LUT3DFilter`, and others —
have no spatial dimension. Pass no density parameter; there is nothing to
adapt.

## Next steps

- Read <doc:Architecture> for the execution model and the
  rationale behind the layering.
- Browse the per-filter documentation under the **Shipping
  filters** topics in the sidebar to pick the right filter for
  your use case.
- Consult the
  [Tier 3 contract documents](https://github.com/xiaosen11/DCRenderKit/tree/main/docs/contracts)
  for the measurable behaviour of the perception-based filters.
