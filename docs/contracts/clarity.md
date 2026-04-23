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

**业界对照**（§8.4 Audit.2 调研 commit session B）:

| 实现 | 边缘保持滤镜 | 源 |
|---|---|---|
| **DCR (本实现)** | Fast Guided Filter (He & Sun 2015) | 独立 Swift/Metal 实现 |
| Adobe ACR / Lightroom Clarity | 闭源专有算法，Adobe 从 Pixmantec 收购后并入 ACR；社区描述为 "large-radius unsharp mask-like" | [Adobe community 讨论](https://community.adobe.com/t5/photoshop/what-exactly-is-clarity/m-p/8957985) |
| darktable "local contrast" | **Local Laplacian Filter (default)** 或 unnormalized bilateral filter；工作在 Lab L 通道 | [darktable 4.6 manual](https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/local-contrast/) |
| RawTherapee local adjustments | Laplacian operator + Poisson equation 迭代 | [RawPedia Local Adjustments](https://rawpedia.rawtherapee.com/Local_Adjustments) |

**诚实结论**:
- ✓ **算法族**（"detail = orig − smooth_base, 放大 detail" unsharp-mask-like 路径）和 Adobe Clarity 的社区描述匹配
- ⚠ **具体滤镜**（guided filter）**不是业界首选** —— darktable 用 LLF default，RawTherapee 用 Laplacian。Adobe 保密，但 Adobe 收购 Pixmantec 时机和社区描述暗示也是 Laplacian-family
- ✓ **Guided filter 用于图像 contrast 增强是学术公认方法** —— 多篇论文 (e.g. [ResearchGate: Effective Guided Image Filtering for Contrast Enhancement](https://www.researchgate.net/publication/327333001)，[arXiv 2310.10387 Enhanced Edge-Perceptual GIF](https://arxiv.org/abs/2310.10387))
- ⚠ Guided filter 的**已知局限是 halo artifacts near edges**（"weighted guided filter" 是学术变体 addressing that）—— 对应契约 C.5 设 5% 阈值的合理性

**trade-off 记录**: 本项目 LLF 考察 N 次失败（见 `findings-and-plan.md` §7.3 + `engineering-judgment.md` §3），guided filter 是 engineering-judgment §6 "pragmatic 而非 optimal" 的合法选择。Tier 3 不锚定外部 app —— 契约 (C.1-C.7) 可测行为 + LLF 失败文档 = 完整 trade-off 记录。

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

常数来源与依据（§8.1 A.2 FIXME + B-series 反推 commit session B）:

**Guided filter `ε = 0.005` (B.2 derivation)**:
- 工业/学术 ε 范围 0.001–0.1 ([Guided Filter Wikipedia](https://en.wikipedia.org/wiki/Guided_filter))；[MATLAB `imguidedfilter` default](https://www.mathworks.com/help/images/ref/imguidedfilter.html) 0.01 for `[0,1]`
- DCR Clarity 选 0.005 = MATLAB default 一半 = **更强边缘保持** (less smoothing)
- **硬依据**: 设计意图是 "base 只抓大尺度结构，让更多中频 detail 留在 residual 给 amplify"。较小 ε 正好服务此意图。对比 HS (ε=0.01) 也合逻辑 —— HS 要 broader base，Clarity 要 sharper base
- 此值在论文推荐范围内，语义正向

**Guided filter radius `p = 0.019` (fraction of quarter-res short side) (B.4 findings)**:
- 1080p → ~20 px full-res radius → 1.9% 短边
- 4K → ~40 px full-res → 1.9% 同
- 8K → ~80 px full-res → 1.9% 同
- **分辨率自适应**，同 HS radius 但比例更大
- **硬依据**: Cambridge in Colour 给出的 "local contrast enhancement radius **30-100 pixels**" 经验范围 ([Cambridge Local Contrast Enhancement](https://www.cambridgeincolour.com/tutorials/local-contrast-enhancement.htm))。DCR Clarity 映射如下：
  - 1080p: 20 px —— 低于 Cambridge 30 px 下限，属 "tight Clarity"
  - 4K: 40 px —— 落入 30-100 范围，standard local contrast
  - 8K: 80 px —— 在 range 内
- **为什么比 HS (1.2%) 大**: Clarity 要 "broader base / 更大 residual detail" 以获取 mid-freq 成分；HS 要 "tighter base 做 local tone correction"。两个 radius 的相对大小关系有明确设计 rationale
- **trade-off 记录**: 1080p 下 20 px 低于 Cambridge 经验下限，可能视觉上偏 "subtle Clarity"。若未来觉得 1080p 手机相机场景不够强，可将 p 提升至 0.028（给 30 px@1080p），但会破坏契约 C.3-C.4 的当前测量基线，需重跑验证

**Product compression `× 1.5 positive` / `× 0.7 negative` (B.1 findings)**:
- **Weber-Fechner** ([Wikipedia](https://en.wikipedia.org/wiki/Weber%E2%80%93Fechner_law)) 给 qualitative log-linear 关系 + 1% JND，**不提供具体数值系数推导**
- **Unsharp mask amount** ([Wikipedia](https://en.wikipedia.org/wiki/Unsharp_masking)) 在所有主流实现中都是 user-taste 参数，**无理论最优值**（MATLAB imsharpen default amount=0.8）
- ×1.5 / ×0.7 是 empirical aesthetic choice，**无文档化 user 验证**
- shader 注释中原有 "perceptually-linear slider response" 宣称已删除（fabricated，违反 engineering-judgment §4）
- **tech debt 状态**: 已知 empirical; 建议未来加 Tier 4 snapshot tracking 锁定当前值，避免悄悄漂移

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

- [He & Sun 2015 — Fast Guided Filter](https://arxiv.org/abs/1505.00996) (算法主源)
- [ResearchGate — Effective Guided Image Filtering for Contrast Enhancement (2018)](https://www.researchgate.net/publication/327333001) (guided filter 用于 contrast 学术路径)
- [arXiv 2310.10387 — Enhanced Edge-Perceptual Guided Image Filtering](https://arxiv.org/abs/2310.10387) (weighted guided filter 对 halo 改进)
- [Trentacoste et al. 2012 — Unsharp Masking, Countershading and Halos](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1467-8659.2012.03056.x)
- [Gibbs phenomenon — Wikipedia](https://en.wikipedia.org/wiki/Gibbs_phenomenon)
- [darktable local contrast module (4.6)](https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/local-contrast/) (业界 LLF-first 对照)
- [darktable local laplacian pyramids blog (2017)](https://www.darktable.org/2017/11/local-laplacian-pyramids/)
- [Adobe Community — "What exactly is Clarity"](https://community.adobe.com/t5/photoshop/what-exactly-is-clarity/m-p/8957985) (Adobe 社区对 Clarity 行为描述)
- [Lightroom Clarity behavior — ExpertPhotography](https://expertphotography.com/clarity-tool/)
- F3 修复 commit `2907b2b` (baseLuma gamma-wrap 在 HS + Clarity 同批)
- FIXME at `ClarityFilter.metal:143` (product compression 常数 empirical record)

---

## 7. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B，锚定 guided-filter-residual 实现 |
