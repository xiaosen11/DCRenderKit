# SoftGlow 契约（§8.2 A+.3）

**Task binding**: 形式化 #23 · 验证 #27 · 实现：`SoftGlowFilter` (既有；Dual-Kawase-style pyramid bloom)

**Status**: draft 2026-04-23

---

## 1. Scope

本契约定义 `SoftGlowFilter` 的可测量行为。匹配现有 Dual Kawase-style pyramid bloom 实现：bright-threshold gate → 2× box downsample 金字塔 → 9-tap tent upsample 累加 → Screen blend composite。

**算法空间**: 整个 bloom 链工作在 linear sRGB（`.linear` 下 bloom 是光学可加性，是 `findings-and-plan.md` §7.2 A "linear 下更好" 名单里唯一不需 wrap 的 effect-类 filter）。

**参数**:
- `threshold ∈ [0.0, 1.0]`, default 0 (maximally permissive per 2026-04-22 commit `ede4361`)
- `strength ∈ [0.0, ~1.0]`, product-compressed to ≤ 0.35 post commit `eb606d8`
- `radius ∈ (0, ~1.0]`, pyramid depth proxy (deeper pyramid ↔ wider spread)

**语义**:
- Bright pixels (luma > threshold + 0.1) 向 neighbourhood 发光
- 发光经金字塔向外传播（半径随 radius 参数扩张）
- Screen-blend 合成，自动避免高光 clip

**业界对照**（§8.4 Audit.1 调研 commit session B）:

DCR SoftGlow 属**pyramid bloom 族**（downsample → pyramid → upsample 累加），但**不是** Marius Bjørge 2015 的 Dual Kawase。具体差异：

| 实现 | 下采样 | 上采样 | 来源 |
|---|---|---|---|
| **DCR (本实现)** | 2×2 box (4-tap, 均权 1/4) | 9-tap tent (1-2-1/2-4-2/1-2-1 / 16) | Harbeth-inherited 血缘 |
| Dual Kawase (Bjørge 2015) | 5-tap (center×4 + 4 corners ±1 texel ×1) | 8-tap (4 cardinal ±1 ×1/12 + 4 diagonal ±0.5 ×2/12) | [Bjørge SIGGRAPH 2015](https://community.arm.com/cfs-file/__key/communityserver-blogs-components-weblogfiles/00-00-00-20-66/siggraph2015_2D00_mmg_2D00_marius_2D00_notes.pdf) |
| Unreal Engine / COD AW (Jimenez 2014) | 13-tap custom | 9-tap custom + firefly fix | [Jimenez iryoku.com](http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/) |
| Unity HDRP (default Gaussian) | pyramid + 9×9 Pascal binomial Gaussian | same | [Unity HDRP Bloom](https://docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@14.0/manual/Post-Processing-Bloom.html) |

**诚实结论**: DCR 的 kernel 是 pyramid bloom 族中相对**简单**的变体 —— 4-tap box 下采样弱于 Dual Kawase 的 5-tap 和 UE 的 13-tap；9-tap tent 上采样接近 Unity HDRP Gaussian 质量。**pyramid bloom 作为算法类是业界标准**，具体 kernel 选择属 engineering-judgment §6 "pragmatic trade-off"，满足契约 C.4 扩散范围即可，不需要为"升级到 Dual Kawase"而重写。

**Tier 3 不锚定外部 app** — 不追精确 PSF 或 bloom shape 匹配。

---

## 2. 算法形式（对应 shader 契约）

```
输入: linear sRGB 图像 I

第 1 级 (bright downsample):
  avg = 2×2 box(I)
  luma = Rec.709(avg)
  bright = smoothstep(threshold − 0.1, threshold + 0.1, luma)
  pyramid[0] = avg · bright

第 2..N 级 (downsample):
  pyramid[k] = 2×2 box(pyramid[k-1])

第 N..1 级 (upsample accumulate):
  tent = 9-tap (1-2-1 / 2-4-2 / 1-2-1) / 16 with offset = radius·shortSide
  pyramid[k-1] += tent_upsample(pyramid[k])

最终 bloom = pyramid[0] 放大回原分辨率

Composite (Screen blend at strength):
  screened = 1 − (1 − I) · (1 − bloom)
  output   = mix(I, screened, strength)
```

常数来源与依据（§8.1 A.2 FIXME + B-series 反推 commit session B）:

**Pyramid depth anchor `135` (B.3 derivation)**:
- Formula: `levels = max(3, floor(log2(shortSide / 135)))`
- 反算: 1080 / 2³ = 135 → "1080p 下 3 级 pyramid" 的反推常数
- Industry 对照: 自适应 pyramid depth with resolution 是业界标准做法（否则"高分辨率下 bloom 显得小"，见 [Unity 社区讨论](https://discussions.unity.com/t/bloom-effect-requires-adjustments-for-any-supported-screen-resolution/805148)）。具体 level 数由产品决策，非感知 / PSF 定理
- 用户真机反馈（2026-04-22 session A）确认当前 bloom 范围 "looks right"，证明 "3 levels @ 1080p" 是**用户验证过的美学选择**
- **等价干净替代**: 常数改成 `128` (= 2⁷) 在 1080p / 4K 下行为**完全相同**（两者都 give 3 / 4 levels），但数学更整洁。后续 refactor 可采纳但不影响 1.0 行为
- 替代 `256` 会让 4K 降到 3 levels（现 4 levels）— **功能性 break**，不建议

**Strength 压缩 `× 0.35` (B.1 findings)**:
- 来源: commit `eb606d8` (session A 2026-04-22) 真机反馈 "太强" → 压缩比例实测调到 0.35
- **依据**: user-feedback-driven empirical tuning
- **Weber-Fechner 推导尝试 (B.1)**: 失败 —— Weber-Fechner 给 qualitative log-linear 关系 + 1% JND，**不提供具体数值系数**。没有理论可导出 0.35 这个值
- **相对最强 empirical evidence**: 三个 filter 里唯一有 session 真机反馈支持，比 HS × 0.35/0.50 (无用户反馈) 和 Clarity × 1.5/0.7 (shader 注释已移除 fabricated claim) 档次更高
- **tech debt 状态**: user-validated empirical; 建议 Tier 4 snapshot tracking 锁定

**Smoothstep 宽度 `± 0.1` (threshold ± 0.1 = 0.2-wide gate)**:
- 来源: Harbeth 血缘，无独立 fit 过程
- 依据: 未验证；可能是 "足够宽让过渡平滑，足够窄让 gate 有效果" 的 empirical 选择

**Tent kernel `1-2-1 / 2-4-2 / 1-2-1 / 16`**:
- 来源: 2D binomial Gaussian approximation (Pascal 三角行 `1 2 1`)。教科书标准 (e.g. Unity HDRP Gaussian filter 用 Pascal 第九行，本实现用第三行简化版)
- 依据: **硬依据** (二项式分布 → 高斯近似，见 [Unity HDRP Bloom Gaussian 描述](https://docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@14.0/manual/Post-Processing-Bloom.html))

---

## 3. 可测条款

### C.1 Identity (strength = 0)

```
SoftGlow(strength=0)(I) === I   within Float16 quantization (~0.2 %)
```

**依据**: `DCRSoftGlowComposite` 有 `strength < 0.001` early return。

**测法**: 任意 patch，strength=0，逐 channel 对比，`accuracy: 0.005`.

### C.2 Threshold gate (below-threshold produces no bloom)

固定 patch Y_pixel < threshold − 0.1（完全低于 smoothstep 下沿），任意 strength：

```
|output − input| < ε   (ε = 0.01 absorbing Float16 + pyramid floor)
```

**依据**: `bright = smoothstep(threshold − 0.1, threshold + 0.1, luma)` 在 `luma < threshold − 0.1` 时为 0 → pyramid 0 level 被 0 × avg 抹掉 → bloom = 0 → Screen blend 不改变 input。

**测法**:
1. Uniform patch at linear Y = 0.2, threshold = 0.5 → Y < threshold − 0.1 = 0.4 ✓
2. strength = 1.0 (压缩后 0.35)
3. 断言 output ≈ input

### C.3 Above-threshold contribution

Uniform patch Y_pixel > threshold + 0.1，bloom 贡献应体现：

```
output.luma > input.luma + 0.01   at strength = 1.0, threshold = 0.3, Y_pixel = 0.5
```

**依据**: `bright = smoothstep(..., ..., 0.5)` at thresh=0.3 → smoothstep(0.2, 0.4, 0.5) = 1.0 → full pyramid contribution. Screen blend `1 − (1−0.5)·(1−bloom)` raises output 当 bloom > 0.

### C.4 Spatial spread (pyramid bloom behaviour)

Centre-bright synthetic image：
- 64×64, 中心 4×4 block at Y = 0.9, rest at Y = 0.0
- threshold = 0.5, strength = 1.0

断言：
- 中心 output > 0.5（bloom 加到 spot 本身，预期 Y 与原 Y=0.9 相当）
- **距中心 8 px 处** output luma > 3·10⁻³（pyramid 近场传播）
- **距中心 16 px 处** output luma > 3·10⁻⁴（pyramid 中场衰减）
- 极远 (≥ 28 px) output 近 0（radius 有限）

**依据**: Dual Kawase / box-pyramid bloom 特性 —— 每级 2× 下采样 + upsample tent 扩散 radius 呈指数（金字塔深度越深扩散越远）。具体扩散距离由 Harbeth-inherited depth anchor `log2(shortSide / 135)` 决定；在 64×64 下 `max(3, ⌊log₂(64/135)⌋) = 3` 级，pyramid 8×8 为最深。

**阈值来源（数值推导）**: 4×4 spot 的 linear luma 能量 ≈ 16 · 0.9 · 0.35 (strength 0.35 product compression) ≈ 5.0。pyramid 做的 tent upsample 近似一个 σ ≈ 8-10 px 的 Gaussian（3 级累加）。在 16 px 距离（~1.6σ），Gaussian 密度 ≈ `exp(-1.6²/2) / (2π·σ²) ≈ 4·10⁻⁴`。经实测（commit session B 中）观察值 5·10⁻⁴，阈值 `3·10⁻⁴` 保持 real signal 可检测且留 Float16 噪声 floor 余地。8 px 距离 (0.8σ) Gaussian 密度高一个量级，阈值 `3·10⁻³` 对应实测 >7·10⁻³。

### C.5 Monotonicity in strength

固定 bright input（e.g., Zone VII），扫 `strength ∈ {0, 0.3, 0.7, 1.0}`：

```
output.luma 单调非递减 in strength
```

**依据**: Screen blend `1 − (1−I)·(1−bloom)` 对 I, bloom 都单调非递减；mix 权重从 0 到 1 线性。

### C.6 Gamut preservation

所有 `(threshold, strength) ∈ {0.2, 0.5, 0.8} × {0, 0.5, 1.0}`，11 patch，output ∈ `[0, 1] ± 1/1024`, finite, 非 NaN。

**依据**: Screen blend 输出上界是 1（因为 `(1-I)·(1-bloom) ≥ 0`），不需要额外 clamp。shader 有显式 `clamp(result, 0, 1)` 作保险。

---

## 4. 非契约（刻意排除）

### 为何不写 "additivity" / "energy conservation"

原 `findings-and-plan.md` §8.2 A+.3 草稿列了:
- `bloom(a+b) = bloom(a) + bloom(b)` in linear
- `∫bloom = K·∫{I > threshold}·I·p(I)`

**放弃理由**:
1. **Threshold gate 破坏 additivity**: smoothstep 在 threshold 附近是非线性；两个 subthreshold 输入的和可能跨过 threshold 而触发 bloom，`bloom(a)+bloom(b)=0` 但 `bloom(a+b)>0`。反例简单：I_a = I_b = threshold/2，则 I_a+I_b = threshold，bloom(a+b) > 0 = bloom(a)+bloom(b)。**契约应描述实际行为，不是理论 wishlist**。
2. **Energy integral ill-defined**: `∫bloom` 需要定义 "bloom component"；实际 output 是 Screen blend 结果 `= 1 − (1−I)·(1−bloom)`，要分离 bloom 部分需 `1 − (1−output)/(1−I)`，当 `I → 1` 时发散。无稳定的 closed-form integral。

遵循 `engineering-judgment.md §5`："契约可测量 → 测试脚本验证"。不能写成可靠测试的条款不是契约，是愿望。

### 为何不写 PSF 精确形状

Dual Kawase PSF 理论上是 binomial approximation to Gaussian。但 shader 里金字塔深度随图像尺寸动态，测试图 64×64 的有效 PSF 和 4K 输入的不同。"PSF 形状精确匹配理论 Gaussian" 是实测回归类条款（Tier 4 snapshot），不是 Tier 3 契约。C.4 用"定性扩散范围"代替。

---

## 5. 合成测试图

位置: `Tests/Contracts/SoftGlowContractTests.swift`

| Patch 类型 | 构造 | 对应条款 |
|---|---|---|
| Uniform Zone V / VII | 64×64 linear Y | C.1, C.3 |
| Below-threshold | 64×64 linear Y=0.2 (< threshold 0.3) | C.2 |
| Centre bright spot | 64×64 with 4×4 Y=0.9 centre, 0 rest | C.4 |
| Macbeth + primaries | 12 patches × 9 (threshold, strength) | C.6 |

---

## 6. Out of scope

- 外部 pixel-level parity (Unreal / Unity bloom shaders)：Tier 3 不锚定
- PSF 精确 Gaussian 形状: Tier 4 snapshot 范围
- HDR 输入：Phase 2 parking lot（本实现假设 `.linear` 但值仍 clamp 到 [0,1]）
- Video 时间域稳定性：Phase 2
- Additivity / energy 精确数学（见 §4 "非契约" 理由）

---

## 7. 参考

- [Marius Bjørge SIGGRAPH 2015 — "Bandwidth-Efficient Rendering"](https://community.arm.com/cfs-file/__key/communityserver-blogs-components-weblogfiles/00-00-00-20-66/siggraph2015_2D00_mmg_2D00_marius_2D00_notes.pdf) (definitive Dual Kawase kernel spec; DCR uses simpler box + tent variant)
- [Jorge Jimenez 2014 SIGGRAPH Advances — "Next Generation Post Processing in Call of Duty: Advanced Warfare"](http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/) (production pyramid bloom inspiring UE approach)
- [Unity HDRP Bloom documentation](https://docs.unity3d.com/Packages/com.unity.render-pipelines.high-definition@14.0/manual/Post-Processing-Bloom.html) (supports Gaussian / Kawase / Dual filter options)
- [Dual Kawase Blur kernel implementation (Medium article extraction)](https://medium.com/@uwa4d/dual-blur-and-its-implementation-in-unity-c2cd77c90771) (5-tap down / 8-tap up with exact weights, matches Bjørge 2015)
- `findings-and-plan.md` §7.2 A (SoftGlow 在 `.linear` 下更好 — 用户 2026-04-22 真机反馈)
- `findings-and-plan.md` §8.1 A.2 (FIXME 常数溯源)
- `ede4361` commit — threshold default 50 → 0 (maximally permissive)
- `eb606d8` commit — strength × 0.35 product compression
- `fd08a52` commit — 重构为 Dual Kawase 7-dispatch pyramid

---

## 8. 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-04-23 | draft | 初版 from session B；刻意排除 additivity/energy 等不可测量条款 |
