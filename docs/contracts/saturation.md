# Saturation 契约（§8.2 A+.5）

**Task binding**: 形式化 #78 · 验证 #79 · 实现 #77（post-OKLCh refactor）

**Status**: draft 2026-04-23

---

## 1. Scope

本契约定义 `SaturationFilter` 的可测量行为，匹配 OKLCh-based 均匀 chroma 放缩实现（#77 post-refactor）。

**算法空间**: OKLCh（Ottosson, 2020）
**Identity**: `saturation = 1.0`
**Parameter range**: `saturation ∈ [0.0, 2.0]`

### 语义区别于 Vibrance

- Saturation（本契约）: **均匀** chroma 放缩，所有像素等权重，无 hue protect
- Vibrance（see `vibrance.md`）: 选择性 + skin hue 保护

**与旧 Rec.709 luma-anchor 实现的差异**：
- 旧：`mix(vec3(luma), rgb, s)`，`luma = 0.2125R + 0.7154G + 0.0721B`，灰轴锚 Rec.709 物理 luma
- 新：OKLCh 中 `C' = C · s`，灰轴锚 OKLab `L`（感知 lightness）
- 数值上 `s = 0` 的灰略有差别（Rec.709 Y ≠ OKLab L，差值典型 < 0.05 in linear），但都是"perceptually 合理"的灰
- Breaking change noted in #77 task description

---

## 2. 算法形式（对应 shader 契约）

```
输入: linear sRGB
1. → OKLCh: L, C, h
2. C' = C · saturation
3. gamut clamp C' 至 (L, C', h) → RGB ∈ [0, 1]³
4. → linear sRGB
```

参数：
- `saturation: Float`：identity `1.0`；`0.0` → 灰；`2.0` → 强放大

---

## 3. 可测条款

### C.1 Identity

`saturation = 1.0` 时，output === input（容差 Float16 量化 ~0.2%）。

**测法**: 任意输入，`XCTAssertEqual(output, input, accuracy: 0.002)` 逐 channel。

### C.2 Zero saturation → 感知 grayscale

`saturation = 0.0` 时：
- output 所有像素 OKLCh 的 `C` 分量 < `1e-3`（数值灰）
- output 每像素 OKLCh 的 `L` 与 input 的 OKLCh `L` 差 `< 0.001`（感知亮度保持）

**关键差异于旧实现**: 旧实现保持 Rec.709 `Y`；新实现保持 OKLab `L`。两者对同一像素给出略不同的灰值。

**测法**: ColorChecker 24-patch + skin patches，`s = 0`，转 OKLCh 断言 `C ≈ 0` 且 `L_out ≈ L_in`。

### C.3 均匀 chroma scaling

在 gamut clamp 未触发的像素（`C · s ≤ C_max(L, h)`），output 的 OKLCh `C` 与 input 的比值 ≈ saturation：

```
C_out / C_in ≈ s，容差 ±1%
```

**测法**: Low-sat ColorChecker patch（避开 gamut 边界），扫 `s ∈ {0.2, 0.5, 1.0, 1.5}`，断言比值误差 < 1%。

### C.4 单调性

固定输入像素 P（非灰），output 的 OKLCh C 在 saturation 参数上**单调非递减**。

**测法**: 扫 `s ∈ {0, 0.5, 1, 1.5, 2}`，每 step 记录 `C_out`，断言单调（允许 gamut clamp 平台期）。

### C.5 Hue / Lightness 保持（gamut clamp 前）

gamut clamp 未触发的像素：
- `|L_out - L_in| < 0.001`
- `|h_out - h_in| < 0.5°`

**测法**: 同 C.3 的测试 patch，额外断言 L、h 不变。

### C.6 Gamut preservation

全 `s ∈ [0, 2]`、全输入，output 所有 channel ∈ `[0, 1]`（含 float ±1e-5），无 NaN，无 inf。

**测法**: 穷举 `s` × 测试集 patch，遍历 output。

### C.7 无 skin protect（与 Vibrance 区分）

同 hue 下，Macbeth Light/Dark Skin patch 和等 `(L, C)` 非 skin hue patch，在 `s = 2.0` 下的 ΔC 差异 `< 5%`（即 Saturation 不区分 skin）：

```
|ΔC(skin) - ΔC(non-skin_equiv)|  /  ΔC(non-skin_equiv)  < 0.05
```

**为何列此条**: 作为 Vibrance 契约 C.4 的**对照条款**，双向锚定两个 filter 的行为边界。如果 Saturation 意外 protect 了 skin（例如实现错误引入 hue 依赖），此条款会抓住。

---

## 4. 合成测试图

位置: `Tests/Contracts/SaturationContractTests.swift`

| Patch 类型 | 用途 | 对应条款 |
|---|---|---|
| ColorChecker 24-patch | 跨色域全面 | C.1, C.3, C.5, C.6 |
| Macbeth Light/Dark Skin | 无 skin protect 验证 | C.7 |
| 等 (L, C) 非 skin hue 对照 | 对比 Vibrance | C.7 |
| Low-sat gradient | 均匀放大比例 | C.3 |
| Neutral gray ramp | identity + zero-sat 灰一致性 | C.1, C.2 |
| 6 个原色 | gamut 边界 | C.6 |

---

## 5. Out of scope

- 外部 pixel-level parity：按用户 2026-04-23 决定完全按 OKLCh 学术派
- 视频时间域稳定性：Phase 2
- HDR 输入：parking lot

---

## 6. 参考

- [Ottosson (2020) — A perceptual color space for image processing](https://bottosson.github.io/posts/oklab/)
- [OKLab Wikipedia](https://en.wikipedia.org/wiki/Oklab_color_space)
- [darktable Color Balance RGB — perceptual saturation in JzAzBz（本项目选 OKLCh 为等效路径）](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/color-balance-rgb/)

---

## 7. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B，基于 #77 OKLCh 重构 |
