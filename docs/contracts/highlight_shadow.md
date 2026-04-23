# HighlightShadow 契约（§8.2 A+.1）

**Task binding**: 形式化 #21 · 验证 #25 · 实现：`HighlightShadowFilter` (既有；F3 修复 commit `2907b2b` 2026-04-22)

**Status**: draft 2026-04-23

---

## 1. Scope

本契约定义 `HighlightShadowFilter` 的可测量行为。匹配现有 guided-filter-based 实现（Fast Guided Filter, He & Sun 2015，commit `2907b2b` F3 修复后）。

**算法空间**:
- 输入 / 输出: linear sRGB
- 内部 smoothstep 窗口在 gamma 空间（baseLuma 从 linear 转 gamma 后做 smoothstep —— F3 修复的关键点）
- baseLuma: 经 guided filter 平滑后的局部亮度（Rec.709 加权）

**参数**:
- `highlights ∈ [-1.0, +1.0]`, identity 0
- `shadows ∈ [-1.0, +1.0]`, identity 0

**slider 约定（与 Adobe 不完全一致，沿袭 Harbeth C7HighlightShadow 血缘）**:
- **`highlights > 0` → 提亮高光区**（Adobe "Highlights" 正值是 *压暗* 高光；本实现沿袭 GPUImage/Harbeth 反向约定）
- `shadows > 0` → 提亮阴影区（与 Adobe 同方向）

### 为何不改成 Adobe 约定

当前 DigiCam 真机交付路径沿用 Harbeth slider 方向。改反向涉及 UI 端滑块反馈 + 已有用户习惯，属产品决策而非工程决策。HS 不在 2026-04-23 "Saturation/Vibrance 灰色升级" 清单里。本契约描述**实际实现的行为边界**，不是"假想的最佳版"。如未来决定对齐 Adobe，需单开 task 重写 + 契约重订。

---

## 2. 算法形式（对应 shader 契约，F3 修复后）

```
输入: linear sRGB 图像 I
1. baseLuma_linear = guided_filter(Rec.709_luma(I), ε, radius)    // 局部亮度
2. baseLuma_gamma  = linear_to_srgb_gamma(baseLuma_linear)        // F3: gamma 空间
3. h_weight = smoothstep(0.25, 0.85, baseLuma_gamma)² · (3 − 2·tVal)
              // 原 shader 用这个 eased smoothstep 把过渡更尖锐
4. s_weight = 1 − smoothstep(0.15, 0.75, baseLuma_gamma)           // 反向
5. ratio_gamma = 1 + highlights · h_weight · 0.35
                   + shadows     · s_weight · 0.50
6. output_linear = I · ratio_gamma                                  // apply in linear
7. (optional) saturation compensation clamp(0.8, 1.3) around ratio = 1
```

常数来源见 `findings-and-plan.md` §8.1 A.2 FIXME 注释与 commit `d5ea56a`（Tier 2 magic number，继承 Harbeth 谱系）。

---

## 3. 可测条款

### C.1 Identity (both sliders zero)

```
HighlightShadow(0, 0)(I) === I   within Float16 quantization (~0.2 %)
```

**容差**: `accuracy: 0.005` per channel。

**测法**: 任意 patch，两 slider 均 0，逐 channel 对比。

### C.2 方向性 (direction) — per slider

固定 patch P，固定一个 slider=0，扫另一个 slider ∈ {-1, -0.5, 0, +0.5, +1}：
- `highlights` slider: 对 Zone VII patch（linear Y ≈ 0.38, gamma Y ≈ 0.65），output Rec.709 Y **单调非递减** in `highlights`
- `shadows` slider: 对 Zone III patch（linear Y ≈ 0.052, gamma Y ≈ 0.25），output Rec.709 Y **单调非递减** in `shadows`

**依据**:
- Zone System gamma 映射 per Norman Koren ([Simplified Zone System](https://www.normankoren.com/zonesystem.html)):
  Zone III ≈ 64/255 gamma，Zone V ≈ 115/255 gamma，Zone VII ≈ 166/255 gamma
- sRGB linear values via IEC 61966-2-1 inverse gamma

**测法**: 构造 uniform patch at linear Y，扫 slider 记 output luma。

### C.3 Zone targeting (selectivity)

两 slider 各自只在目标 zone 有强响应，在中间 zone 衰减：

- **highlights 选择性**:
  ```
  |ΔY_at_Zone_VII| / |ΔY_at_Zone_V| ≥ 3.0
  ```
- **shadows 选择性**:
  ```
  |ΔY_at_Zone_III| / |ΔY_at_Zone_V| ≥ 3.0
  ```

ΔY = `output.Y − input.Y` under slider value +1，sample point 是对应 zone 的 gamma 中点。

**依据**: HS 的设计意图是"局部 tone 修正"，slider 影响应集中在目标 zone 而非全图 gain。这条是 F3 修复的正面表述 —— 中间 zone 不该被高光/阴影 slider 显著影响。

### C.4 Midtone stability (F3 regression guard)

baseLuma 在 `[linear 0.15, linear 0.25]` (approx Zone IV-V 边缘) 的 patch，slider 值 +1 下：

```
|ΔY_midtone| / |ΔY_max_zone| < 0.20
```

即中间亮度像素 ΔY 不超过最大响应区 ΔY 的 20%。

**F3 历史（2026-04-22 commit `2907b2b`）**: baseLuma 在 shader 里原本直接用 linear 值做 smoothstep，导致 linear 0.15 在 gamma 空间是 0.42（完全落在 highlights 窗 [0.25, 0.85] 内），所以中间亮度也吃 highlights slider。修复后 baseLuma 转 gamma 再做 smoothstep，linear 0.15 → gamma 0.42 → smoothstep 输出 0.12（显著小于高光区的 ~1.0）。本条款是 F3 regression guard。

### C.5 Halo-free at soft edge

构造 soft edge-step 输入：
- 左半图 uniform at `linear Y_low = 0.05` (Zone III)
- 右半图 uniform at `linear Y_high = 0.38` (Zone VII)
- 过渡 Gaussian blur σ = 2px

应用 `HighlightShadow(highlights: +1, shadows: 0)`。在**边缘之外** 10-30 px 的带状区：

```
peak_overshoot  / step_magnitude < 0.03   // output 超出 Y_high 的百分比
peak_undershoot / step_magnitude < 0.03   // output 低于 Y_low 的百分比
step_magnitude = Y_high − Y_low
```

**依据**: Trentacoste et al. 2012 ([*Unsharp Masking, Countershading and Halos: Enhancements or Artifacts?*](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1467-8659.2012.03056.x)) 指出感知无害 halo 阈值约为 step 的 3-5%。本契约取 3% 作为 halo-free 基线。Guided filter 的边缘保持性（`a` 系数在边缘附近贴近 1）应让 ratio 不产生 overshoot，除了 Float16 量化和 bilinear upsample 噪声。

**Trade-off 记录**: 理论上 Local Laplacian Filter (Paris et al. 2011) halo 控制更强，但本项目尝试 N 次未解决 remapping function continuity + pyramid blend 问题，guided filter 是 pragmatic trade-off。见 `engineering-judgment.md §3` + `findings-and-plan.md §7.3`。

### C.6 Gamut preservation

对于以下组合，output 每 channel ∈ `[0, 1] ± 1/1024`（margin 为 Float16 quantization 留余）：

- 所有 `(highlights, shadows) ∈ {-1, 0, +1}²` (9 组合)
- 11 个测试 patch（Zone 0, III, V, VII, X + 6 原色 R/G/B/C/M/Y + Macbeth skin）

**测法**: 枚举断言 output channel 在 margin 内，finite，非 NaN。

### C.7 (Soft) Perceptually linear slider

对 Zone VII patch 在 `highlights ∈ {0.5, 1.0}` 下:

```
|ΔY(highlights=0.5)| / |ΔY(highlights=1.0)| ∈ [0.35, 0.65]
```

**Soft** 因为 shader 的 `h_weight` smoothstep 与 slider 值是非线性耦合（slider 是线性乘子，但 eased smoothstep 把权重曲线非对称化）；±15% 容差覆盖这层非线性。

**依据**: Weber-Fechner ([Wikipedia](https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law)) 要求感知变化 ∝ log(stimulus)，但在 normalised slider 下 linear in slider 是常见近似。本条款是 soft contract，失败不阻 merge 但需分析非线性源头。

---

## 4. 合成测试图

位置: `Tests/Contracts/HighlightShadowContractTests.swift`

| Patch 类型 | 构造 | 对应条款 |
|---|---|---|
| Zone III patch | uniform linear Y = 0.052 | C.2 shadows, C.3, C.4 |
| Zone V patch | uniform linear Y = 0.169 | C.3 denominator |
| Zone VII patch | uniform linear Y = 0.382 | C.2 highlights, C.3, C.7 |
| Midtone patch | uniform linear Y ∈ [0.15, 0.25] | C.4 |
| Soft-edge step | half-plane + Gaussian blur | C.5 |
| ColorChecker + primaries | Macbeth skin + R/G/B/C/M/Y | C.6 |
| Identity baselines | any patch at (0, 0) | C.1 |

**注意点**:
- Soft-edge 图 Gaussian σ=2px 避开 guided filter 的 box-radius（guided filter 4× 下采样 + 小半径）— 如果 step 过 sharp，guided filter 自身会 soften，测出的 "halo" 其实是 guided filter 正常边缘平滑，不是真 halo。
- Zone VII patch Y=0.382 落在 gamma ~0.65，smoothstep(0.25, 0.85, 0.65)=0.844，eased 后 h_weight≈0.71。ratio 上限 ≈ 1 + 0.71·0.35 = 1.25。output linear Y ≈ 0.477，距离 Zone VIII (0.519) 还有空间，不 clamp。

---

## 5. Out of scope

- 外部 pixel-level parity (Lightroom / 像素蛋糕等)：用户 2026-04-23 决定 Tier 3 不做外部锚定
- Adobe slider 方向对齐：见 §1 "slider 约定"，属产品决策
- HDR 输入：Phase 2 parking lot
- Video time-domain stability：Phase 2 parking lot

---

## 6. 参考

- [Norman Koren — A Simplified Zone System for Making Good Exposures](https://www.normankoren.com/zonesystem.html)
- [Zone System — Wikipedia](https://en.wikipedia.org/wiki/Zone_System) (Ansel Adams 1981)
- [Weber–Fechner law — Wikipedia](https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law)
- [Trentacoste et al. 2012 — Unsharp Masking, Countershading and Halos: Enhancements or Artifacts?](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1467-8659.2012.03056.x) (Computer Graphics Forum)
- [He & Sun 2015 — Fast Guided Filter](https://arxiv.org/abs/1505.00996)
- F3 修复 commit: `2907b2b` (baseLuma gamma-wrap)
- LLF 考察失败记录: `findings-and-plan.md` §7.3, `engineering-judgment.md` §3

---

## 7. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B，锚定 post-F3 implementation |
