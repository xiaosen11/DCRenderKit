# DCRenderKit

[![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-lightgrey)](https://developer.apple.com/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/xiaosen11/DCRenderKit/actions/workflows/ci.yml/badge.svg)](https://github.com/xiaosen11/DCRenderKit/actions/workflows/ci.yml)

> A commercial-grade Metal-based image processing SDK for iOS and macOS.
> 专为 iOS 和 macOS 打造的商用级 Metal 图像处理引擎。

---

## 🌏 English

### Overview

DCRenderKit is a high-performance, zero-dependency Metal image processing SDK that provides:

- **Compute, Render, Blit, MPS** four-backend dispatch system
- **Multi-pass pipeline** with declarative DAG execution and automatic texture lifecycle
- **Filter chain auto-optimization** — framework-level fusion of compatible filters
- **16-bit float precision** by default — no banding from chained 8-bit quantization
- **Production-ready rendering pipelines** for camera preview, image editing, and video processing
- **Full Swift Concurrency** (async/await) support

### Quick Start

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/xiaosen11/DCRenderKit.git", from: "0.1.0")
]
```

Then in your code:

```swift
import DCRenderKit

// Camera preview
let preview = PreviewPipeline(mtlView: myMTKView)
preview.activeFilters = [
    ExposureFilter(exposure: 20),
    ContrastFilter(contrast: 15),
]

// Image editing
let edit = EditPipeline(image: myUIImage)
try await edit.prepareContext()
let result = try await edit.process(filters: [...])
```

### Requirements

- iOS 15.0+ / macOS 12.0+
- Swift 5.9+
- Xcode 15+

### Documentation

- [Architecture](docs/Architecture.md) — Engine internals
- [Custom Filters](docs/CustomFilter.md) — How to write your own filter
- [API Reference](docs/API.md) — Full public API documentation

### License

MIT — see [LICENSE](LICENSE).

---

## 🇨🇳 中文

### 概述

DCRenderKit 是一个高性能、零外部依赖的 Metal 图像处理 SDK，提供：

- **Compute / Render / Blit / MPS** 四后端分派系统
- **多 Pass 声明式管线** — DAG 执行 + 自动纹理生命周期管理
- **滤镜链自动优化** — 框架级相邻可融合滤镜合并
- **默认 16-bit 浮点精度** — 长滤镜链不累积 8-bit 量化色带
- **生产级渲染管线** — 相机预览、图片编辑、视频处理
- **原生 Swift Concurrency**（async/await）支持

### 快速上手

在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/xiaosen11/DCRenderKit.git", from: "0.1.0")
]
```

使用示例：

```swift
import DCRenderKit

// 相机预览
let preview = PreviewPipeline(mtlView: myMTKView)
preview.activeFilters = [
    ExposureFilter(exposure: 20),
    ContrastFilter(contrast: 15),
]

// 图片编辑
let edit = EditPipeline(image: myUIImage)
try await edit.prepareContext()
let result = try await edit.process(filters: [...])
```

### 环境要求

- iOS 15.0+ / macOS 12.0+
- Swift 5.9+
- Xcode 15+

### 文档

- [架构设计](docs/Architecture.md) — 引擎内部
- [自定义滤镜](docs/CustomFilter.md) — 如何编写自定义滤镜
- [API 参考](docs/API.md) — 完整 public API 文档

### 许可证

MIT — 详见 [LICENSE](LICENSE)

---

## Status

🚧 **Work in Progress** — targeting v0.1.0 first release.

| Phase | Status |
|-------|--------|
| Phase 1 (Core engine + SDK + pipelines) | 🟡 In Progress |
| Phase 2 (New effects: stickers, lens correction, fisheye, distortion, vignette) | ⚪ Pending |
| Phase 3 (Testing + docs) | ⚪ Pending |

See [Roadmap](docs/Roadmap.md) for details.

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

## Contact

- Issues: [GitHub Issues](https://github.com/xiaosen11/DCRenderKit/issues)
- Discussions: [GitHub Discussions](https://github.com/xiaosen11/DCRenderKit/discussions)
