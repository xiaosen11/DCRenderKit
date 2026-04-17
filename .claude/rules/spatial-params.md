---
description: 编写或修改 Metal shader 中涉及像素距离、采样步长、颗粒大小等空间参数时自动加载
globs:
  - "**/*.metal"
  - "**/Pipeline/**/*.swift"
---

# 空间参数适配规则

## 三类参数，三种适配方式

### 1. 视觉纹理参数 — `basePt × pixelsPerPoint`

**适用于**：用户感知为"屏幕上的纹理"的参数（胶片颗粒大小、锐化边缘宽度、CCD 噪点大小）

**原则**：不管处理的图有多大，在屏幕上看到的纹理永远是固定 pt 大小。

**pixelsPerPoint** = 处理纹理中多少像素对应屏幕 1pt：
- 相机预览（Metal → MTKView 1:1 blit）：`UIScreen.main.scale`（3x 屏 = 3.0）
- 编辑预览（全图 → UIImage → 缩显到 view）：`imageWidth / viewWidthPt`
- 导出：同编辑预览默认缩放（保持纹理相对整图的比例）

**公式**：`参数像素值 = basePt × pixelsPerPoint`

**实现**：参数从 Swift 传入 shader buffer，由 `EditParameters.pixelsPerPoint` 统一驱动。Filter 本身不感知显示上下文。

**用户 pinch-zoom**：不影响 pixelsPerPoint。grain 已 bake 进图，zoom 时自然跟随放大缩小。

**示例**：
- FilmGrain grainSize：`1.5pt × pixelsPerPoint`
- Sharpen step：`round(1.0pt × pixelsPerPoint)`

### 2. 图像结构参数 — 按纹理维度比例

**适用于**：效果作用在图像内容上，用户感知为"图像被怎样处理"的参数（guided filter radius、模糊半径、色差偏移）

**原则**：保持参数占图像的比例恒定。不同分辨率的同一场景，处理效果一致。

**实现**：
- 在 shader 内从纹理尺寸直接计算（`shortSide × 比例` 或 `quarterW × 比例`）
- 或从 Swift 根据 `source.width / source.height` 算好传入
- **不需要 pixelsPerPoint**

**注意**：如果 box filter 是正方形的，横纵用同一个比例常量分别乘各自维度（`radiusX ∝ width`, `radiusY ∝ height`），避免极端宽高比下覆盖率失衡。

**示例**：
- HighlightShadow radiusX/Y：`quarterW × 0.012`, `quarterH × 0.012`
- PortraitBlur maxRadius：`shortSide × 0.025`

### 3. 逐像素参数 — 不需要适配

**适用于**：纯色彩/色调运算，无空间维度（曝光增益、对比度曲线、LUT 查表、饱和度）

**原则**：不涉及像素距离，三场景天然一致。

## 判断流程

写新参数时先问三个问题：

1. **这个参数是像素距离/偏移/大小吗？** → 不是 → 逐像素，不适配
2. **用户感知的是"屏幕上的纹理"还是"图像被怎样处理"？**
   - 屏幕纹理（颗粒、锐化边缘、噪点）→ 视觉纹理，用 pixelsPerPoint
   - 图像处理（频率分离、模糊、色差）→ 图像结构，按纹理比例
3. **参数通道开了吗？** → 视觉纹理参数必须从 Swift 传入（通过 buffer），不能在 shader 里写死常量

## 三场景视觉一致性验证

适配完成后，用以下场景验证：

| 场景 | pixelsPerPoint | 预期 |
|------|---------------|------|
| 相机预览 3x 屏 | 3.0 | grain 1.5pt、锐化 1pt |
| 编辑 4K@390pt view | ~10.3 | 缩显后 grain 仍 1.5pt、锐化仍 1pt |
| 编辑 720p@390pt view | ~3.3 | 同上 |
| 导出 4K | 同编辑 | 手机查看导出图，效果与编辑预览一致 |

## 禁止事项

- **禁止在 shader 中写死像素常量用于视觉纹理参数**（如 `const float grainScale = 1.5;`）。必须从 buffer 读取。
- **禁止用 `shortSide / 某个分辨率` 做适配**。这是写死了参考分辨率，换设备就错。用比例常量。
- **禁止假设屏幕倍率**。pixelsPerPoint 由调用方注入，filter 不 import UIKit。
