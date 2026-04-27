# DCRenderKit

[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B-lightgrey)](https://developer.apple.com/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> A commercial-grade Metal-based image processing SDK for iOS.
> 专为 iOS 打造的商用级 Metal 图像处理 SDK。

---

## 🌏 English

### Overview

DCRenderKit is a high-precision, zero-external-dependency Metal image-processing SDK. Built for
consumer photo-editing apps and camera pipelines that want Lightroom-grade filter quality without
Core Image's synchronization overhead or the accumulated 8-bit quantisation of ad-hoc Metal
filter chains.

Highlights:

- **Principled tone operators.** Every tone curve (Exposure / Contrast / Blacks / Whites) is a
  documented grading primitive (Reinhard / DaVinci log-slope / Filmic toe / Filmic shoulder) with
  a fetched reference — no opaque "best-MSE polynomial fit" coefficients in the codepath.
- **Principled color operators.** Saturation and Vibrance both operate in OKLCh (Ottosson 2020 /
  CSS Color Level 4), with a bi-directional gamut clamp that preserves lightness and hue.
- **Declarative multi-pass filters.** SoftGlow, HighlightShadow, Clarity, and PortraitBlur
  declare a pass graph; the framework handles texture allocation, lifetime, and disposal.
- **Zero external dependencies.** Only Metal + MetalKit + (optional) MetalPerformanceShaders +
  (optional) Vision. Nothing to vend through your app's SBOM.
- **16-bit float intermediates** between filters — no banding from chained 8-bit quantisation.
- **Full Swift 6 strict-concurrency conformance.**
- **Color-space aware.** Choose `.linear` (physically correct radiometric math) or `.perceptual`
  (DigiCam parity) with a single line of config.

Status: **pre-1.0**, targeting `v0.1.0` first public release. The filter-correctness foundation
is complete; the public API freeze and release-plumbing are the remaining gates — see
[TODO.md](TODO.md) and [docs/release-criteria.md](docs/release-criteria.md).

### Quick Start

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/xiaosen11/DCRenderKit.git", from: "0.1.0")
]
```

Minimal example — apply two filters to a `UIImage`:

```swift
import DCRenderKit

let pipeline = Pipeline(
    input: .uiImage(myImage),
    steps: [
        .single(ExposureFilter(exposure: 20)),
        .single(ContrastFilter(contrast: 15, lumaMean: 0.5)),
        .multi(SoftGlowFilter(strength: 30)),
    ]
)

let resultTexture = try await pipeline.output()
```

Camera preview — encode into the drawable for a `MTKView`:

```swift
func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable else { return }
    let commandBuffer = try device.commandQueue.makeCommandBuffer()!

    let pipeline = Pipeline(
        input: .pixelBuffer(latestCameraFrame),
        steps: [
            .single(LUT3DFilter(cubeURL: presetURL)),
            .single(FilmGrainFilter(density: 0.3)),
        ]
    )
    try pipeline.encode(into: commandBuffer, writingTo: drawable.texture)

    commandBuffer.present(drawable)
    commandBuffer.commit()
}
```

### Filter Catalogue (v0.1.0 scope)

| Filter | Kind | Algorithm |
|---|---|---|
| `ExposureFilter` | Tone | Linear gain (neg) + Reinhard (pos) |
| `ContrastFilter` | Tone | DaVinci log-space slope around scene pivot |
| `BlacksFilter` | Tone | Reinhard toe with scale (Filmic toe) |
| `WhitesFilter` | Tone | Filmic shoulder (inverse of BlacksFilter toe) |
| `WhiteBalanceFilter` | Color | YIQ tint axis + Kelvin piecewise warm overlay |
| `SaturationFilter` | Color | OKLCh uniform chroma scaling with gamut clamp |
| `VibranceFilter` | Color | OKLCh selective saturation + skin-hue protection |
| `HighlightShadowFilter` | Local tone | 5-pass Fast Guided Filter + Zone-system smoothstep windows |
| `ClarityFilter` | Local tone | 5-pass Fast Guided Filter, residual-detail amplification |
| `SoftGlowFilter` | Effect | Adaptive pyramid bloom (Dual-Kawase family) |
| `SharpenFilter` | Effect | Laplacian unsharp-mask with `pixelsPerPoint` scaling |
| `FilmGrainFilter` | Effect | sin-trick pseudo-random + symmetric SoftLight |
| `CCDFilter` | Effect | Fused CA + sat-boost + noise + sharpen |
| `PortraitBlurFilter` | Effect | Mask-driven two-pass Poisson-disc blur |
| `LUT3DFilter` | Color | Software trilinear `.cube` sampler |
| `NormalBlendFilter` | Blend | Porter-Duff over (premultiplied alpha) |

Every filter's algorithmic choice carries a `Model form justification` block pointing at a
reference (paper / open-source implementation / industry presentation) — no unsourced
"industry-standard" claims.

### Requirements

- iOS 18.0+
- Swift 6.0 (strict concurrency)
- Xcode 16+

(macOS 15 is retained as a `swift test` host for the Metal compute
kernels; no business-layer macOS target — the SDK ships no `NSImage`
loader and imports UIKit-only paths under `#if canImport(UIKit)`.)

### Documentation

- [TODO.md](TODO.md) — currently-pending work, per-phase
- [docs/architecture.md](docs/architecture.md) — full design narrative,
  including multi-Pipeline isolation (§4.17 / §4.18)
- [docs/multi-pipeline-cookbook.md](docs/multi-pipeline-cookbook.md) —
  recipes for running multiple `Pipeline`s concurrently (camera +
  editor + export, etc.) with the right resource isolation
- [docs/filter-development.md](docs/filter-development.md) —
  guide for adding a new filter (algorithm selection, NodeKind
  choice, fusion compatibility, test matrix)
- [docs/contracts/](docs/contracts/) — per-filter measurable behaviour contracts
  (HighlightShadow / Clarity / SoftGlow / Saturation / Vibrance)
- [docs/known-issues.md](docs/known-issues.md) — confirmed
  non-SDK issues affecting CI / specific OS combinations
- [docs/findings-and-plan.md](docs/findings-and-plan.md) — rigorous-audit plan and
  `.linear` color-space findings
- [docs/session-handoff.md](docs/session-handoff.md) — per-session handoff document

### Known limitations

- One test class (`MultiPassExecutorTests`) is skipped on the CI's
  `macos-15` runner due to a Metal driver bug specific to
  macOS 15.7.4 / Xcode 16.4. Local macOS 26 + Xcode 17 reproduce
  no issue; functional coverage is preserved by other tests.
  See [docs/known-issues.md](docs/known-issues.md) for the full
  context.

### License

MIT — see [LICENSE](LICENSE).

---

## 🇨🇳 中文

### 概述

DCRenderKit 是高精度、零外部依赖的 Metal 图像处理 SDK。为希望取得 Lightroom 级滤镜质量，又不想承担
Core Image 同步开销或手写 Metal 滤镜链在多 pass 中累积 8-bit 量化色带的消费级修图 app 与相机管线设计。

核心价值：

- **曲线滤镜原理派实现。** 每一条 tone curve（Exposure / Contrast / Blacks / Whites）都是一个
  有论文或开源工程出处的调色原语（Reinhard / DaVinci 对数斜率 / Filmic 趾 / Filmic 肩），代码路径里
  没有不透明的"最低 MSE 多项式拟合"系数。
- **色彩滤镜原理派实现。** Saturation 与 Vibrance 均工作在 OKLCh（Ottosson 2020 / CSS Color
  Level 4）空间，配合双向色域夹紧保留感知亮度与色相。
- **声明式多 pass 滤镜。** SoftGlow / HighlightShadow / Clarity / PortraitBlur 声明一个 pass
  graph，框架负责纹理分配、生命周期与回收。
- **零外部依赖。** 仅依赖 Metal + MetalKit +（可选）MetalPerformanceShaders +（可选）Vision。
  不把额外依赖带入你 app 的 SBOM。
- **中间纹理默认 16-bit float** —— 长滤镜链不累积 8-bit 量化色带。
- **完整 Swift 6 严格并发遵从。**
- **色彩空间感知。** 一行配置切换 `.linear`（物理辐射正确）与 `.perceptual`（DigiCam parity）。

状态：**pre-1.0**，正在冲刺 `v0.1.0` 首个公开版本。滤镜正确性基础已完整，剩下的发布门槛是
public API 冻结和发布管线 —— 详见 [TODO.md](TODO.md) 与
[docs/release-criteria.md](docs/release-criteria.md)。

### 快速上手

在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/xiaosen11/DCRenderKit.git", from: "0.1.0")
]
```

最小示例 —— 给一张 `UIImage` 叠两个滤镜：

```swift
import DCRenderKit

let pipeline = Pipeline(
    input: .uiImage(myImage),
    steps: [
        .single(ExposureFilter(exposure: 20)),
        .single(ContrastFilter(contrast: 15, lumaMean: 0.5)),
        .multi(SoftGlowFilter(strength: 30)),
    ]
)

let resultTexture = try await pipeline.output()
```

相机预览 —— 将结果直接 encode 到 `MTKView` 的 drawable：

```swift
func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable else { return }
    let commandBuffer = try device.commandQueue.makeCommandBuffer()!

    let pipeline = Pipeline(
        input: .pixelBuffer(latestCameraFrame),
        steps: [
            .single(LUT3DFilter(cubeURL: presetURL)),
            .single(FilmGrainFilter(density: 0.3)),
        ]
    )
    try pipeline.encode(into: commandBuffer, writingTo: drawable.texture)

    commandBuffer.present(drawable)
    commandBuffer.commit()
}
```

### 滤镜目录（v0.1.0 范围）

| 滤镜 | 类别 | 算法 |
|---|---|---|
| `ExposureFilter` | 曝光 | 线性增益（负向）+ Reinhard 色调映射（正向） |
| `ContrastFilter` | 对比度 | DaVinci 对数斜率，以场景亮度均值为 pivot |
| `BlacksFilter` | 阴影 | Reinhard 带尺度趾（Filmic 趾） |
| `WhitesFilter` | 高光 | Filmic 肩（BlacksFilter 趾的代数镜像） |
| `WhiteBalanceFilter` | 白平衡 | YIQ 色调轴 + Kelvin 分段 warm overlay |
| `SaturationFilter` | 饱和度 | OKLCh 均匀 chroma 放缩，含色域夹紧 |
| `VibranceFilter` | 自然饱和度 | OKLCh 选择性饱和 + 肤色保护 |
| `HighlightShadowFilter` | 局部色调 | 5-pass Fast Guided Filter + Zone-system smoothstep 窗口 |
| `ClarityFilter` | 局部色调 | 5-pass Fast Guided Filter，残差细节放大 |
| `SoftGlowFilter` | 特效 | 分辨率自适应金字塔 bloom（Dual-Kawase 族） |
| `SharpenFilter` | 锐化 | 拉普拉斯反锐化 mask，按 `pixelsPerPoint` 缩放 |
| `FilmGrainFilter` | 特效 | sin-trick 伪随机 + 对称 SoftLight 混合 |
| `CCDFilter` | 特效 | 融合的色差 + 饱和度提升 + 噪声 + 锐化 |
| `PortraitBlurFilter` | 特效 | mask 驱动的两遍 Poisson-disc 模糊 |
| `LUT3DFilter` | 色彩 | 软件 trilinear `.cube` 采样器 |
| `NormalBlendFilter` | 混合 | Porter-Duff over（预乘 alpha） |

每个滤镜的算法选择都附带 `Model form justification` 段落，指向来源（论文 / 开源实现 / 工业报告），
杜绝"据称是行业标准"的无引用陈述。

### 环境要求

- iOS 18.0+
- Swift 6.0（严格并发）
- Xcode 16+

（macOS 15 仅作 `swift test` 宿主运行 Metal compute 单元测试，不对外发布 macOS 业务 API —
SDK 不含 `NSImage` loader，UIKit 相关路径都在 `#if canImport(UIKit)` 下。）

### 文档

- [TODO.md](TODO.md) —— 当前待办，按阶段分类
- [docs/architecture.md](docs/architecture.md) —— 完整设计叙事，
  含多 Pipeline 隔离（§4.17 / §4.18）
- [docs/multi-pipeline-cookbook.md](docs/multi-pipeline-cookbook.md) —— 多
  `Pipeline` 并发运行的食谱（相机 + 编辑器 + 导出 等场景的资源隔离方案）
- [docs/filter-development.md](docs/filter-development.md) —— 新增
  filter 的接入指南（算法选型、NodeKind 选择、融合兼容性、测试矩阵）
- [docs/contracts/](docs/contracts/) —— 每个 filter 的可测量行为契约
  （HighlightShadow / Clarity / SoftGlow / Saturation / Vibrance）
- [docs/known-issues.md](docs/known-issues.md) —— 已确认的非 SDK
  环境特定问题（CI 跳过的测试等）
- [docs/findings-and-plan.md](docs/findings-and-plan.md) —— 严谨化审计计划与 `.linear` 色彩空间结论
- [docs/session-handoff.md](docs/session-handoff.md) —— 多 session 接管文档

### 已知限制

- CI 在 `macos-15` runner 上跳过一个测试类（`MultiPassExecutorTests`），
  原因是 macOS 15.7.4 / Xcode 16.4 的 Metal driver bug。本地
  macOS 26 + Xcode 17 不复现；该测试的功能覆盖由其他测试类承担。
  详见 [docs/known-issues.md](docs/known-issues.md)。

### 许可证

MIT —— 详见 [LICENSE](LICENSE)。

---

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Contact

- Issues: [GitHub Issues](https://github.com/xiaosen11/DCRenderKit/issues)
- Discussions: [GitHub Discussions](https://github.com/xiaosen11/DCRenderKit/discussions)
