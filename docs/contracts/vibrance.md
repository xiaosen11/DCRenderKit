# Vibrance 契约（§8.2 A+.4）

**Task binding**: 形式化 #24 · 验证 #28 · 实现 #14（post-OKLCh refactor）

**Status**: draft 2026-04-23 — 待 #14 实现阶段用 Macbeth 实测数据填入参数窗口

---

## 1. Scope

本契约定义 `VibranceFilter` 的可测量行为，匹配 OKLCh-based Adobe 语义实现（#14 post-refactor）。

**算法空间**: OKLCh（Ottosson, 2020）
**Identity**: `vibrance = 0`
**Parameter range**: `vibrance ∈ [-1.0, +1.0]`

### 语义区别于 Saturation

- Saturation（see `saturation.md`）: 均匀 chroma 放缩，所有像素等权重
- Vibrance: **选择性**放缩，低饱和权重高、高饱和权重低；额外施加 **skin hue 保护**，暖色 skin range 权重压低

---

## 2. 算法形式（对应 shader 契约）

```
输入: linear sRGB
1. → OKLCh: L, C, h
2. w_lowsat = 1 - smoothstep(C_low, C_high, C)
3. w_skin   = 1 - skin_hue_gate(h) · skin_protect_strength
4. C' = C · (1 + vibrance · w_lowsat · w_skin)
5. gamut clamp C' 至 (L, C', h) → RGB ∈ [0, 1]³
6. → linear sRGB
```

参数：
- `C_low`, `C_high`：boost 曲线两端（OKLCh chroma 单位），初值待 #14 用 Macbeth 24-patch 测定
- `skin_protect_strength ∈ [0, 1]`：skin 保护强度系数，default `1.0`
- `skin_hue_gate(h)`：基于 `h_skin_center ± h_skin_halfwidth` 的 smoothstep gate

---

## 3. 可测条款

### C.1 Identity

`vibrance = 0` 时，output === input（容差 Float16 量化 ~0.2%，per `testing.md` Part 3）。

**测法**: 任意输入，`XCTAssertEqual(output, input, accuracy: 0.002)` 逐 channel。

### C.2 单调性

固定输入像素 P（非灰），output 的 OKLCh C 分量在 vibrance 参数上**单调非递减**（vibrance 从 -1 到 +1，C 从最低到最高，忽略 gamut clamp 平台期）。

**测法**: 扫 vibrance ∈ {-1, -0.5, 0, 0.5, 1}，对每个 test 像素记录 `C_out`，断言 `C_out` 单调（允许相邻两点相等当且仅当 gamut clamp 触发）。

### C.3 低饱和 vs 高饱和 boost 差异

同 hue 下，低饱和像素（`C = C_low`）的 boost magnitude 显著大于高饱和像素（`C = C_high`）：

```
ΔC(vibrance=+1, C=C_low)  /  ΔC(vibrance=+1, C=C_high)  ≥ 3.0
```

**测法**: 构造两个 OKLCh patch：`(L=0.6, C=C_low, h=H_test)` 和 `(L=0.6, C=C_high, h=H_test)`，H_test 选非 skin hue（例 200° 青蓝）。vibrance=+1 下测各自 ΔC，断言比值 ≥ 3。

### C.4 Skin-hue 保护

Macbeth ColorChecker #2 (Light Skin) + #3 (Dark Skin) 在 OKLCh 的 ΔC（vibrance=+1）显著小于等饱和度非 skin hue patch：

```
ΔC(skin patch)  /  ΔC(non-skin equiv-C patch)  ≤ 0.5
```

**依据**: Preferred skin hue cross-cultural center **≈ 49°** (CIELAB, [Preferred skin reproduction centres](https://library.imaging.org/admin/apis/public/api/ist/website/downloadArticle/cic/28/1/art00017))；观察 skin hue 分布 **25°–80°** (CIELAB)。OKLCh 中心角度需在 #14 实测 Macbeth patch 确定。

**测法**:
1. 实测 Macbeth Light/Dark Skin 在 OKLCh 的 `(L, C, h)`，记录 `h_skin_light`, `h_skin_dark`
2. 构造等 C、等 L、非 skin hue 的对照 patch（例 `h = h_skin_avg + 180°`）
3. vibrance=+1，断言 skin patch 的 ΔC ≤ 0.5 × 对照 patch 的 ΔC

### C.5 Gamut preservation

全 `vibrance ∈ [-1, 1]`、全输入（包括 Macbeth 24-patch + 原色 R/G/B/C/M/Y + 高 C 边缘色），output:
- 所有 channel ∈ `[0, 1]`（含 float 误差 ±1e-5）
- 无 NaN
- 无 inf

**测法**: 穷举 vibrance × 测试集 patch，遍历 output 每像素每通道断言。

### C.6 Hue / Lightness 保持（gamut clamp 前）

在 gamut clamp 未触发的像素（C' ≤ C_max(L, h)），output 的 OKLCh `L` 和 `h` 与 input 差 `< ε`：

```
|L_out - L_in| < 0.001
|h_out - h_in| < 0.5°
```

**测法**: 取低-中饱和度 patch（避开 gamut 边界），vibrance=+1，转 OKLCh 比对 L、h。

### C.7 Perceptually linear slider（soft contract，非强制）

相同输入下，`ΔC(vibrance=+0.5) / ΔC(vibrance=+1.0) ≈ 0.5`（容差 ±20%）。

**测法**: 低饱和非 skin patch 上扫 vibrance，计算 ΔC 斜率，断言 `[0.4, 0.6]` 区间。

---

## 4. 合成测试图

位置: `Tests/Contracts/VibranceContractTests.swift`

| Patch 类型 | 用途 | 对应条款 |
|---|---|---|
| ColorChecker 24-patch | 跨色域全面 | C.5, C.6 |
| Macbeth Light Skin (#2) + Dark Skin (#3) | skin protect | C.4 |
| 等 C 等 L 非 skin hue 对照 | skin protect 对照 | C.4 |
| Low-sat gradient（C ∈ [0, 0.1]） | 低饱和 boost | C.3 |
| High-sat gradient（C ∈ [0.2, 0.4]） | 高饱和 boost 压制 | C.3 |
| Neutral gray ramp | identity 验证 | C.1 |
| 6 个原色（R/G/B/C/M/Y） | gamut 边界 | C.5 |

---

## 5. Out of scope

- 外部 pixel-level parity（Lightroom/Photoshop/像素蛋糕等）：用户 2026-04-23 决定不做外部锚定，完全按 OKLCh + Adobe 语义学术派
- 视频时间域稳定性：当前 SDK image 域，视频属 Phase 2 parking lot
- HDR 输入：当前 SDK linear sRGB，HDR parking lot

---

## 6. 参考

- [Ottosson (2020) — A perceptual color space for image processing](https://bottosson.github.io/posts/oklab/)
- [OKLab Wikipedia](https://en.wikipedia.org/wiki/Oklab_color_space)
- [Preferred skin reproduction centres for different skin groups (IS&T 2020)](https://library.imaging.org/admin/apis/public/api/ist/website/downloadArticle/cic/28/1/art00017)
- [SLR Lounge — Vibrance vs Saturation](https://www.slrlounge.com/vibrance-vs-saturation-what-is-the-difference/)
- [Boris FX — Vibrance vs Saturation in Photography](https://borisfx.com/blog/vibrance-vs-saturation-in-photography/)
- [darktable Color Balance RGB (vibrance 在 perceptual 模式)](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/color-balance-rgb/)

---

## 7. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B，基于 #14 OKLCh Adobe 语义重构 |
