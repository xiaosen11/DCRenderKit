# Clarity 契约（§8.2 A+.2）

**Task binding**: 形式化 #22 · 验证 #26 · 实现：`ClarityFilter` (既有；F3 修复 commit `2907b2b` 2026-04-22 同批)

**Status**: draft 2026-04-23

---

## 1. Scope

本契约定义 `ClarityFilter` 的可测量行为。匹配现有 guided-filter-residual 实现 —— 用 Fast Guided Filter（He & Sun 2015）提取 edge-preserving base，`detail = original − base`，正向放大 detail、负向混向 base。

**算法空间**: 操作在 gamma 空间（shader 内做 linear↔gamma 显式转换），输入输出 linear sRGB。

**参数**:
- `intensity ∈ [-1.0, +1.0]`, identity 0

**语义**:
- **正向 intensity**: 放大中频 detail（guided filter 移除的那部分），视觉上 "局部对比度上升、纹理更锐利"
- **负向 intensity**: 输出混向 edge-preserving base，视觉上 "平滑化、保留大尺度结构去除纹理"

**与 Lightroom "Clarity" 的关系**: 行为语义接近但实现不同。Lightroom Clarity 是闭源 adaptive local contrast (参考 [ExpertPhotography](https://expertphotography.com/clarity-tool/) / [digital-photography-school](https://digital-photography-school.com/lightrooms-clarity-slider-what-does-it-do/))；darktable "local contrast" 模块用 Local Laplacian Filter 或 bilateral filter ([darktable 4.6 manual](https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/local-contrast/))。本实现沿袭 Harbeth 的 guided filter residual 路径，是一个 pragmatic edge-preserving local contrast，非 Lightroom/darktable 精确克隆。Tier 3 不锚定外部 app；锚契约即可。

---

## 2. 算法形式（对应 shader 契约）

```
输入: linear sRGB 图像 I
1. guidedLowRes_a, b = fast_guided_filter(Rec.709_luma(I), ε, radius)  // 1/4 分辨率 a, b
2. upsample a, b → full res (bilinear)
3. baseLuma = a · luma(I) + b
4. baseRGB = I · (baseLuma / luma(I))                                  // keep chroma

5. 工作转 gamma 空间:
   origGamma = linear_to_srgb_gamma(I)
   baseGamma = linear_to_srgb_gamma(baseRGB)
   detail    = origGamma − baseGamma

6. 应用:
   - intensity ≥ 0: outGamma = origGamma + detail · (intensity · 1.5)
   - intensity < 0: outGamma = mix(origGamma, baseGamma, −intensity · 0.7)

7. clamp to [0, 1], output = srgb_gamma_to_linear(outGamma)
```

常数来源（`findings-and-plan.md` §8.1 A.2, commit `d5ea56a` FIXME）:
- product compression `× 1.5 positive` / `× 0.7 negative` — Harbeth 血缘，未独立验证"perceptually linear slider"宣称
- guided filter `ε = 0.005`, `p = 0.019` (radius 相对 quarterRes short side)

---

## 3. 可测条款

### C.1 Identity (intensity = 0)

```
Clarity(0)(I) === I   within Float16 quantization (~0.2 %)
```

**容差**: `accuracy: 0.005` per channel. Shader 有 `abs(intensity) ≤ 0.001` 的 early return，identity 是直接通路。

**测法**: 任意 patch，intensity=0，逐 channel 对比。

### C.2 Local variance monotonicity (positive intensity)

固定 patch P (texture-rich, e.g., checker or Macbeth #6 Bluish Green)，扫 intensity ∈ {0, +0.5, +1.0}，测 output 的 local variance（或 luma 标准差）**单调非递减**。

**测法**:
1. 输入 64×64 patch 含高频纹理（checker 8px 或 sinusoidal Y ± 0.1）
2. Output 的 luma = Rec.709 Y
3. `local_variance = sum((luma_i − mean_luma)²) / N`
4. 断言 `var(0) ≤ var(0.5) ≤ var(1.0)`（容差 0.002 在 ±1 方向）

### C.3 Low-frequency preservation

平滑渐变输入（horizontal linear ramp 0→1，无纹理），Clarity +1 下 output 接近 input。

**依据**: guided filter 在平滑区域 `a → 0, b → mean`，所以 `baseLuma ≈ original luma` → `detail ≈ 0` → 放大 detail 不改变 output。这是 "Clarity 不影响整体 tone" 的数学保证。

**测法**:
1. 64×64 horizontal ramp: `input.r[y,x] = input.g[y,x] = input.b[y,x] = x / 63`
2. `ClarityFilter(intensity: +1)` 处理
3. 断言 `mean(|output − input|) < 0.02`（允许 Float16 + guided filter 边缘噪声）
4. 断言 `max(|output − input|) < 0.05`（局部极值仍在可接受范围）

### C.4 Mid-frequency amplification

Synthetic mid-freq texture 作输入，Clarity +1 下 output amplitude > input amplitude。

**依据**: guided filter 把中频纹理吸收进 base（因为不是大尺度渐变也不是 sharp edge），detail 捕捉这部分。正向放大 detail = 放大中频。

**测法**:
1. 64×64 checker pattern at 8×8 px scale，alternating gamma-Y = 0.4 and 0.6（避开 gamut 边）
2. `input_amplitude = max(input.luma) − min(input.luma)` ≈ 0.2
3. Process with intensity = +1.0
4. `output_amplitude = max(output.luma) − min(output.luma)`
5. 断言 `output_amplitude > input_amplitude · 1.2`（至少放大 20%）

### C.5 Edge preservation (no Gibbs ringing)

Sharp edge 输入，Clarity +1 下 overshoot/undershoot 受限。

**依据**:
- Gibbs phenomenon ([Wikipedia](https://en.wikipedia.org/wiki/Gibbs_phenomenon)) 在 FFT 硬截断 band-pass 下产生约 9% 固定 overshoot
- 本实现用 guided filter 不是 FFT band-pass，边缘被 `a → 1` 保留在 base 中 → detail at edge ≈ 0 → 放大后仍无 overshoot
- Trentacoste et al. 2012 ([halo paper](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1467-8659.2012.03056.x)) 感知无害阈值 ~3%

**测法**:
1. 64×64 sharp vertical step: left half Y=0.2, right half Y=0.8
2. Process with intensity = +1.0
3. 定义 edge 区 = 中心列 ± 2 px；edge 区外 10-30 px 为测量带
4. Peak overshoot = `max(output.luma in right band − 0.8)` 应 `< 0.05`（5% step）
5. Peak undershoot = `max(0.2 − output.luma in left band)` 应 `< 0.05`

**容差说明**: 比 HS 的 3% 阈值 (C.5) 宽，因为 Clarity intensity 显式放大 detail，即使 guided filter 在边缘保护好，Float16 量化 + bilinear upsample + 放大 ×1.5 会累积小 overshoot。5% 是 Trentacoste 论文报告的 "acceptable sharpening halo" 上限。

### C.6 Dynamic range preservation

任何 patch，intensity ∈ [-1, +1]，output max-min 不显著超出 input max-min：

```
max(output.luma) − min(output.luma)
  ≤ (max(input.luma) − min(input.luma)) · 1.5 + 0.05
```

1.5 系数对应正向 product compression；+0.05 吸收 Float16 + edge-artifact 噪声。

### C.7 Gamut preservation

所有 `intensity ∈ {-1, -0.5, 0, +0.5, +1}` × 11 代表 patch（同 HS C.6），output channel ∈ `[0, 1] ± 1/1024`, finite, 非 NaN。

---

## 4. 合成测试图

位置: `Tests/Contracts/ClarityContractTests.swift`

| Patch 类型 | 构造 | 对应条款 |
|---|---|---|
| Uniform Zone V | 64×64 linear Y=0.169 | C.1 |
| Checker texture | 64×64, 8 px blocks, gamma Y=0.4 / 0.6 | C.2, C.4 |
| Horizontal ramp | 64×64, x/(W−1) 线性 | C.3 |
| Vertical sharp step | 64×64, left 0.2 / right 0.8 | C.5 |
| Macbeth + primaries | 12 patches × 5 intensity | C.6, C.7 |

**尺寸要求**: 64×64 必需 —— 小于此 guided filter 的 1/4 下采样会退化到 4×4 系数图，边缘 fringe 占比过大。

---

## 5. Out of scope

- 外部 pixel-level parity (Lightroom Clarity / darktable local-contrast)：Tier 3 不锚定外部
- FFT 频域谱测量：spatial-domain checker + gradient + step 已能区分频率组，FFT 带入额外依赖 (Accelerate / vDSP) 且对 Float16 gamma-space 信号计算 FFT 边界条件复杂，暂不做
- Weber-Fechner slider linearity：shader 注释里的 "perceptually-linear slider response" 宣称未经独立测量，属 Tier 2 spot-check (findings-and-plan §8.6 Tier 2) 不在本契约范围
- Local Laplacian Filter 对照：LLF 已在本项目多次尝试失败（见 `findings-and-plan.md` §7.3 + `engineering-judgment.md` §3），guided filter 是 pragmatic trade-off
- HDR / video: Phase 2 parking lot

---

## 6. 参考

- [He & Sun 2015 — Fast Guided Filter](https://arxiv.org/abs/1505.00996)
- [Trentacoste et al. 2012 — Unsharp Masking, Countershading and Halos](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1467-8659.2012.03056.x)
- [Gibbs phenomenon — Wikipedia](https://en.wikipedia.org/wiki/Gibbs_phenomenon)
- [darktable local contrast module (4.6)](https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/local-contrast/)
- [Lightroom Clarity behavior — ExpertPhotography](https://expertphotography.com/clarity-tool/)
- F3 修复 commit `2907b2b` (baseLuma gamma-wrap 在 HS + Clarity 同批)
- FIXME at `ClarityFilter.metal:143` (product compression 常数 Harbeth 血缘记录)

---

## 7. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B，锚定 guided-filter-residual 实现 |
