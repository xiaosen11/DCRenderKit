# Multi-Pipeline Cookbook

Three working recipes for running multiple `Pipeline` instances
concurrently in a single app, each with the right resource
isolation strategy. Pair with `docs/architecture.md` §4.17 / §4.18
for the underlying design rationale.

---

## Recipe 1 — single renderer (default)

**Use when**: your app has one rendering surface (one MTKView, one
photo editor, one video processor). 95 % of apps fit this shape.

```swift
import DCRenderKit

final class RenderCoordinator {
    private let pipeline = Pipeline()   // uses .shared singletons
    
    func render(commandBuffer: MTLCommandBuffer,
                source: MTLTexture,
                steps: [AnyFilter],
                drawable: MTLTexture) throws {
        try pipeline.encode(
            into: commandBuffer,
            source: source,
            steps: steps,
            writingTo: drawable
        )
    }
}
```

Why it works: every resource defaults to `.shared`, which is fine
because no other Pipeline is competing for the same pools or
mutating the same `ShaderLibrary`.

---

## Recipe 2 — concurrent preview + concurrent batch path

**Use when**: you have a real-time path (camera preview, video
playback) AND a batch path (export, save, transcode) that may run
simultaneously.

The principle: real-time path needs predictable low-latency
allocation; batch path needs a large transient texture budget.
Sharing pools means the batch path's bursty allocation can starve
the real-time path. Isolate the budget.

```swift
final class App {

    // Real-time path: camera preview at 30fps, ≤ 1080p frames
    let previewPipeline = Pipeline.makeIsolated(
        textureBudgetMB: 16,             // ~6 cached 1080p frames
        maxInFlightCommandBuffers: 3,    // 30fps double-buffer + safety
        uniformPoolCapacity: 4
    )

    // Batch path: photo export, full 4K processing
    func exportPhoto(source: MTLTexture, steps: [AnyFilter]) async throws -> MTLTexture {
        let exportPipeline = Pipeline.makeIsolated(
            textureBudgetMB: 256,           // 4K + multi-pass peak
            maxInFlightCommandBuffers: 1,   // one-shot, no benefit to N-deep
            uniformPoolCapacity: 1
        )
        return try await exportPipeline.process(
            input: .texture(source),
            steps: steps
        )
    }
}
```

Both Pipelines share `PipelineStateCache.shared` and
`ShaderLibrary.shared` — the SDK's compiled PSOs and built-in
shaders are reused across the two paths, so the export benefits
from the warm PSO cache populated by the preview.

What stays independent: `TexturePool`, `CommandBufferPool`,
`UniformBufferPool`. The export's transient 256 MiB allocation
can never displace the preview's 16 MiB working set.

---

## Recipe 3 — complete isolation (test harness, custom shaders)

**Use when**:
- You're writing tests that need precise PSO compile-count
  observations.
- You're loading custom `.metallib` files dynamically, and one
  Pipeline's library has function names that another Pipeline's
  library should not see.
- You need to clear a Pipeline's caches without affecting any
  other Pipeline.

```swift
let isolatedPipeline = Pipeline.makeFullyIsolated(
    device: .shared,
    textureBudgetMB: 64,
    maxInFlightCommandBuffers: 2
)

// Register a custom Metal library on this Pipeline's private
// ShaderLibrary — won't pollute Pipeline.shared instances.
let customLib = try device.metalDevice.makeLibrary(URL: myMetallibURL)
isolatedPipeline.shaderLibrary.register(customLib)

// PSOs compiled here go into isolatedPipeline's private caches.
let output = try isolatedPipeline.processSync(
    input: .texture(source),
    steps: [.single(MyCustomFilter())]
)
```

Note: `Pipeline.shaderLibrary` / `Pipeline.uberKernelCache` /
`Pipeline.uberRenderCache` are exposed read-only on every Pipeline
(internal access from inside the module; tests use
`@testable import`). The factory methods are the supported way to
inject independent instances.

---

## Recipe 4 — three coexisting Pipelines (the demo's pattern)

The bundled `Examples/DCRDemo` runs three Pipelines that briefly
coexist when a user starts an export from the editor while the
camera tab is also active. Pattern:

| Owner | Lifecycle | Budget | Why |
|---|---|---|---|
| Camera Coordinator | Long-lived (camera tab open) | 16 MiB / 3 CB / 4 uniform | Real-time 30fps |
| Editor Coordinator | Long-lived (editor tab open) | 64 MiB / 2 CB / 6 uniform | Interactive 4K |
| Export task | Per-export (transient) | 256 MiB / 1 CB / 1 uniform | One-shot |

When the user is editing a 4K photo and exports it while the
camera tab is still loaded behind, all three Pipelines exist
simultaneously — but their texture pools sum to 336 MiB peak,
properly partitioned. Without isolation, a shared 64 MiB pool
would either starve the export or evict the preview's working
set.

Source: see `Examples/DCRDemo/DCRDemo/Camera/MetalCameraPreview.swift`,
`Examples/DCRDemo/DCRDemo/Editing/MetalImagePreview.swift`, and
`Examples/DCRDemo/DCRDemo/Editing/PhotoEditModel.swift` for the
full integration.

---

## Diagnostics

`Pipeline.diagnostics` returns a `Pipeline.Diagnostics` snapshot:

```swift
let snap = pipeline.diagnostics
print("Texture: \(snap.textureBytesCached / 1024 / 1024) MiB cached")
print("Uniforms: \(snap.uniformSlotsInUse) / \(snap.uniformSlotsReserved)")
print("PSOs: compute=\(snap.uberComputePSOCount) render=\(snap.uberRenderPSOCount)")
```

Cheap; can be polled at 1-2 Hz from a debug HUD. The Demo's
`MultiPipelineStatusView` is a working SwiftUI implementation.

---

## Anti-patterns

❌ **Don't construct `Pipeline()` per-frame**. The `CompiledChainCache`
needs Pipeline lifetime to be longer than a single frame to amortise
optimisation cost. See §4.15.

❌ **Don't share a `TexturePool` between a real-time path and a
batch path**. The batch path's transient large allocation will
evict the real-time path's working set, causing reallocation churn
on the hot path.

❌ **Don't register custom shaders on `ShaderLibrary.shared` from
multiple Pipelines if the names overlap**. The cache key includes
library identity, so different libraries can have same-named
kernels safely — but `.shared` is one library; mutating it from
two places sequences the registrations and the last writer wins.

❌ **Don't mutate `Pipeline.diagnostics` snapshots and feed them
back**. The snapshot is read-only; it's a value type.

---

## Reference

- `docs/architecture.md` §4.17 — Multi-Pipeline isolation rationale
- `docs/architecture.md` §4.18 — Coexistence patterns / decision tree
- `Sources/DCRenderKit/Pipelines/Pipeline.swift` — `makeIsolated` /
  `makeFullyIsolated` factory implementations
- `Tests/DCRenderKitTests/MultiPipelineIsolationTests.swift` —
  6 isolation invariants verified by unit tests
