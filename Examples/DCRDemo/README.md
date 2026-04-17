# DCRDemo

iOS sample app exercising DCRenderKit across the three real production
scenarios: camera preview, photo-edit preview, and photo-edit export.
Aligned with DigiCam's effect-test page (24 sliders + LUT presets) so
side-by-side feedback stays apples-to-apples.

## Running

Requires Xcode 26+, iOS 18+ device.

```bash
cd Examples/DCRDemo
xcodegen generate           # (re)creates DCRDemo.xcodeproj from project.yml
open DCRDemo.xcodeproj       # configure Team / signing in Xcode UI
```

Once signing is set up, CLI builds:

```bash
xcodebuild -project DCRDemo.xcodeproj \
           -scheme DCRDemo \
           -destination 'generic/platform=iOS' \
           build
```

For simulator (no signing needed):

```bash
xcodebuild -project DCRDemo.xcodeproj \
           -scheme DCRDemo \
           -destination 'generic/platform=iOS Simulator' \
           CODE_SIGNING_ALLOWED=NO \
           build
```

## Performance acceptance

Target on modern iPhones (A16+):

| Scenario | Expected FPS |
|----------|--------------|
| Camera preview, idle (no filters enabled) | 60 |
| Camera preview, normal chain (≤ 5 filters) | 30+ |
| Camera preview, every slider active | ≥ 15 |
| Photo-edit preview, parameter tweak | < 100 ms latency |
| Photo-edit export (12MP → Photos) | < 1 s |

The in-app HUD colours FPS: green ≥ 50, amber 25–50, red < 25.

## Architecture

- `EditParameters` — 24 `@Observable` slider values + LUT preset
- `FilterChainBuilder` — pure function, `EditParameters` → `[AnyFilter]`
- `CameraController` — AVCaptureSession + CVMetalTextureCache zero-copy
- `MetalCameraPreview` / `MetalImagePreview` — `MTKView` bridges
- `PhotoEditModel` — sample-image picker + async export to Photos
- `PerformanceMetrics` — rolling-window FPS / GPU-ms tracker
- `RootTabView` — two-tab host: Camera / Photo

Tabs share the same `EditParameters` instance, so tuning the look in one
page carries over to the other.
