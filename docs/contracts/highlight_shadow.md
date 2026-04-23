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
- `highlights ∈ [-100, +100]`, identity 0（shader 内部除以 100 得 slider 分数）
- `shadows ∈ [-100, +100]`, identity 0

**slider 方向**:
- `highlights > 0` → 提亮高光区（shader `ratio = 1 + h·h_weight·0.35`，h>0 使 ratio>1）
- `shadows > 0` → 提亮阴影区（同上，使用 `s_weight · 0.50`）

对照 Adobe 等商用产品的方向差异不在本契约 scope（需独立 fetched 调研验证后才能断言）。本契约描述**实际实现的行为**，不预设"某 Adobe app 一定是 X 方向"。

---

## 业界对照 (§8.4 Audit.5，commit session B)

local tone mapping 家族里 "edge-preserving base + region-gated tone curve" 是标准范式（[Eilertsen et al. 2017 TMO survey](https://www.cl.cam.ac.uk/~rkm38/pdfs/eilertsen2017tmo_star.pdf)；[Edge-preserving smoothing survey arXiv 1503.07297](https://arxiv.org/abs/1503.07297)）。具体 base extractor 选择:

| 实现 | Edge-preserving smoother | 源 |
|---|---|---|
| **DCR HS (本实现)** | Fast Guided Filter (He & Sun 2015) | Harbeth-inherited |
| darktable "local contrast" | **Local Laplacian Filter** (Paris 2011) 或 unnormalized bilateral | [darktable manual](https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/local-contrast/) |
| Drago / Durand / Reinhard-local (classic TMO) | Bilateral / anisotropic diffusion | Eilertsen 2017 survey §4 |
| Hu 2024 近期工作 | "improved guided filter + adaptive gamma" | [Hu IET 2024](https://ietresearch.onlinelibrary.wiley.com/doi/full/10.1049/ipr2.12978) |

**诚实结论**:
- ✓ 算法族（edge-preserving base + region-gated tone curve）是业界标准
- ⚠ 具体滤镜选择 —— LLF 是 darktable default 被认为是**halo 最可控**的选项；bilateral 是经典选项；guided filter 是更新的高效选项，有已知 halo 局限
- ✓ DCR 的 guided filter + gamma-window smoothstep + linear apply-ratio 路径在学术上合法（Hu 2024 为近期代表）
- **trade-off 记录**: LLF 本项目多次尝试失败（见 `engineering-judgment.md §3`），guided filter 是 pragmatic 非 optimal 的合法 fallback。契约 C.4 halo 阈值 3% 对应 Trentacoste 2012 感知阈值，把 guided filter halo 局限**转为可测条款**。

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

常数来源与依据（§8.1 A.2 FIXME + B-series 反推 commit session B）:

**Guided filter `ε = 0.01` (B.2 derivation)**:
- [MATLAB `imguidedfilter` default](https://www.mathworks.com/help/images/ref/imguidedfilter.html): `0.01 × diff(range)² = 0.01` for `[0,1]` double images — **精确 match DCR HS 选值**
- He & Sun 原论文 step-edge 示例也用 ε = 0.01 ([Guided Filter Wikipedia](https://en.wikipedia.org/wiki/Guided_filter))
- 语义: variance 阈值分开 "flat patch" (< ε 被 smooth) vs "high-variance patch" (> ε 保留)
- **硬依据**: 此 ε 值是学术 + 工业 default，不需 further justification

**Guided filter radius `p = 0.012` (fraction of quarter-res short side)**:
- 1080p → quarter-res 270 px → 3.2 px radius → ~13 px full-res radius → 1.2% of 短边
- 原论文 step-edge 示例 r=7 at 256×256 ≈ 2.7% of 短边
- DCR 选择比论文示例更小的半径 — **empirical Harbeth-inherited，无独立 derivation**。可能偏速度 (smaller r = less compute)，也可能偏局部 base 精度
- **tech debt**: 如果未来证明 0.012 过小造成 base 欠平滑，可以往论文 2-3% 方向调

**Smoothstep 窗口 `[0.25, 0.85]` / `[0.15, 0.75]`**:
- 继承 Harbeth，无独立 derivation
- 契约 C.3 Zone targeting 已将这套窗口转为可测条款 —— 任何修改需重跑 C.3 验证

**Product compression `× 0.35 highlight` / `× 0.50 shadow` (B.1 findings)**:
- **Weber-Fechner** ([Wikipedia](https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law)) 给 qualitative log-linear 关系 + 1% JND，**不提供具体数值系数推导**
- 无已发表论文给出"高光补偿 × 0.35, 阴影补偿 × 0.50"的理论支持 —— 这些是 Harbeth 血缘 aesthetic choice
- 与 Clarity ×1.5/×0.7 同档位 tech debt
- **tech debt 状态**: 已知 empirical; 建议未来加 Tier 4 snapshot tracking 锁定当前值，避免悄悄漂移

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

两 slider 各自在目标 zone 的响应显著强于中间 zone。度量用**ratio 偏离 1 的幅度**（剥离 input 亮度大小对绝对 ΔY 的影响）：

```
ratio_at_zone = output.Y / input.Y    (uniform grey patch assumption)
```

- **highlights 选择性** (at highlights = +100):
  ```
  (ratio_at_Zone_VII − 1)  /  (ratio_at_Zone_V − 1)  ≥ 2.5
  ```
- **shadows 选择性** (at shadows = +100):
  ```
  (ratio_at_Zone_III − 1)  /  (ratio_at_Zone_V − 1)  ≥ 1.5
  ```

**依据 (shader-grounded)**: smoothstep 窗口 `[0.25, 0.85]` (highlights) / `[0.15, 0.75]` (shadows) 在 gamma 空间 baseLuma 上取权重。手算：
- Zone V 对应 gamma baseLuma ≈ 0.45。h_weight(0.45) ≈ 0.26，s_weight(0.45) ≈ 0.50。
- Zone VII 对应 gamma baseLuma ≈ 0.65。h_weight(0.65) ≈ 0.74。h_weight 比 ≈ 2.85。
- Zone III 对应 gamma baseLuma ≈ 0.25。s_weight(0.25) ≈ 0.92。s_weight 比 ≈ 1.83。

因此 shadows selectivity 天然弱于 highlights —— smoothstep 窗口宽度相同但 shadows 窗底缘在 Zone II-III 附近并非陡峭截断。阈值 `≥ 1.5` 对应 shader 实际能保证的边界。

### C.4 Halo-free at soft edge

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

### C.5 Gamut preservation

对于以下组合，output 每 channel ∈ `[0, 1] ± 1/1024`（margin 为 Float16 quantization 留余）：

- 所有 `(highlights, shadows) ∈ {-1, 0, +1}²` (9 组合)
- 11 个测试 patch（Zone 0, III, V, VII, X + 6 原色 R/G/B/C/M/Y + Macbeth skin）

**测法**: 枚举断言 output channel 在 margin 内，finite，非 NaN。

### C.6 (Soft) Perceptually linear slider

对 Zone VII patch 在 `highlights ∈ {+50, +100}` 下（shader 内分数 0.5 vs 1.0）:

```
|ΔY(highlights=+50)| / |ΔY(highlights=+100)| ∈ [0.35, 0.65]
```

**Soft** 因为 shader 的 `h_weight` smoothstep 与 slider 值是非线性耦合（slider 是线性乘子，但 eased smoothstep 把权重曲线非对称化）；±15% 容差覆盖这层非线性。

**依据**: Weber-Fechner ([Wikipedia](https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law)) 要求感知变化 ∝ log(stimulus)，但在 normalised slider 下 linear in slider 是常见近似。本条款是 soft contract，失败不阻 merge 但需分析非线性源头。

---

## 4. 合成测试图

位置: `Tests/Contracts/HighlightShadowContractTests.swift`

| Patch 类型 | 构造 | 对应条款 |
|---|---|---|
| Zone III patch | uniform linear Y = 0.052 | C.2 shadows, C.3 |
| Zone V patch | uniform linear Y = 0.169 | C.3 denominator |
| Zone VII patch | uniform linear Y = 0.382 | C.2 highlights, C.3, C.6 |
| Soft-edge step | half-plane + Gaussian blur | C.4 |
| ColorChecker + primaries | Macbeth skin + R/G/B/C/M/Y | C.5 |
| Identity baselines | any patch at (0, 0) | C.1 |

**Removed from previous draft**: the "midtone stability" clause (linear Y ∈ [0.15, 0.25] receives < 20 % of full-slider effect). That clause was conceptually backwards: the F3 fix in commit `2907b2b` *increased* midtone activation by moving the smoothstep from linear to gamma-indexed baseLuma, so that Zone IV / V pixels actually register a partial highlight-slider response (e.g., F3 regression test `linear 0.133 midtone must be activated by HS slider`). Asserting midtone stability < 20 % contradicts the F3 intent. The Zone targeting condition (C.3) already captures the "shadows/highlights register more strongly than midtones" claim correctly.

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
- [Eilertsen et al. 2017 — A Comparative Review of Tone-Mapping Algorithms for HDR](https://www.cl.cam.ac.uk/~rkm38/pdfs/eilertsen2017tmo_star.pdf) (local TMO 家族综述 — §8.4 Audit.5)
- [arXiv 1503.07297 — A Brief Survey of Recent Edge-Preserving Smoothing Algorithms](https://arxiv.org/abs/1503.07297) (bilateral / guided / LLF 对比)
- [Hu 2024 — Natureness-preserving TMO based on improved guided filter + adaptive Gamma](https://ietresearch.onlinelibrary.wiley.com/doi/full/10.1049/ipr2.12978) (近期 guided filter TMO 论文，证明该路径学术活跃)
- F3 修复 commit: `2907b2b` (baseLuma gamma-wrap)
- LLF 考察失败记录: `findings-and-plan.md` §7.3, `engineering-judgment.md` §3

---

## 7. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B，锚定 post-F3 implementation |
