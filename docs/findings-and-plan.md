# DCRenderKit findings & P0–P4 execution plan

> 2026-04-17. DCRDemo 真机上线后，用户实测暴露 SoftGlow / HighlightShadow / Clarity
> 三条多 pass filter 有可见行为 bug。根因审出 5 项，用户逐项 challenge
> 验证后拍板 P0–P4 全部修。本文件是执行蓝本 + 压缩前 session 恢复锚点。

---

## 0. 恢复流程（压缩后重启必读）

1. `git log --oneline -20`（DCRenderKit 仓库）看最新状态
2. `swift test` 应该 202 tests 全绿 + 零 warning
3. TaskList：P0–P4 对应 task #17–21
4. 用户偏好：见 `~/.claude/projects/.../memory/user_preferences.md`
5. 本文件列了每项 P 的根因 + 文件 + 改动详情 + 测试

**关键上下文**：用户对 SDK 代码洁癖严格（方案 C 每次被否，逼到方案 A）。任何修复都要**先验根因、零模糊**才改代码。不要猜。

---

## 1. 五个 findings 及其根因验证

### F1 — MultiPassFilter 中间纹理精度丢失（用户实测已确认）

**症状**：
- SoftGlow：全图均匀过曝，没有"柔"、没有高光/暗部层次感
- HighlightShadow：正向滑杆 solo 无效，加前置 filter 就突然有效（但效果不对劲）
- Clarity：画面逐帧抖动

**根因**（7 处连锁，全部已验证）：

| # | 文件:行 | 问题 |
|---|---|---|
| 1a | `Pipeline.swift:374-387` | `executeMultiPass` 调 `MultiPassExecutor.execute` 不传 intermediatePixelFormat |
| 1b | `MultiPassExecutor.swift:67-74` | `execute(...)` 签名没这个参数 |
| 1c | `MultiPassFilter.swift:249-270` | `TextureSpec.resolve` 硬编码 `source.pixelFormat` |
| 1d | `MultiPassFilter.swift:96-100` | `TextureInfo(texture:)` 拷贝 `source.pixelFormat` |
| 1e | `Pipeline.swift:379` | `filter.passes(input:)` 只知道 source 格式 |
| 1f | `MPSDispatcher.swift:121-153` | `encodeMeanReduction` 输出 = 输入格式 |
| 1g | `ImageStatistics.swift:109-165` | `readLumaFromMean` 依赖上面，luma 被 8-bit 量化 |

**机制**：相机 source 是 bgra8Unorm（CVMetalTextureCache 输出）→ MultiPassExecutor 把所有中间 texture 都分配成 bgra8Unorm → SoftGlow 的 bloom 金字塔累加被 8-bit 截断饱和到 1.0 → screen blend 全白 → "全图过曝"。HighlightShadow 的 ratio 可到 1.85，8U 截到 1.0 → 正向无效。Clarity 的 a/b 系数在 1/255 步长下逐帧量化抖动 → 画面哆嗦。

**讽刺点**：`Pipeline.intermediatePixelFormat` 默认 `rgba16Float` 是 SDK 设计意图，但**只在单 pass 路径生效**（`Pipeline.executeSinglePass` 用了），多 pass 路径 `MultiPassExecutor` 忘了传 → SDK 自己违背自己的承诺。

### F2 — sRGB 语义契约不可见

**症状**：`TextureLoader` 用 `.SRGB: false` 加载 JPEG，是个魔法常量；ExposureFilter shader 里孤立出现 `pow(x, 2.2)`；"perceptual space 贯穿"是约定但表层不可见。

**根因验证**：
- Harbeth 默认就是 `.SRGB: false`（已 grep 确认 `Harbeth/Sources/Basic/Core/TextureLoader.swift`），DigiCam 跟随
- 17 个 filter shader 全审过，**全部一致设计为"输入是 perceptual-space"**
- ExposureFilter 内部 `pow(,2.2)` / `pow(,1/2.2)` 做自己的 linearize，是这个设计里唯一需要 linear math 的 filter
- Contrast/Whites/Blacks 的 cubic pivot、weighted parabola 在 gamma 空间拟合（对着 LR 导出 PNG 拟）

**不是 bug，是契约不可见**。用户的感受："强迫症难受"。

**我原本声称"17 个全要 refit"是错的**。实际：
- 5 个拟合参数化 filter（Exposure/Contrast/Whites/Blacks/WhiteBalance）：换空间需 refit
- 10 个手调 filter（Saturation/Vibrance/Sharpen/FilmGrain/CCD/SoftGlow/HighlightShadow/Clarity/PortraitBlur/NormalBlend）：数学上不需 refit，但"产品手感"会变，等于重新验收
- 2 个无参数（LUT3D/SaturationRec709）：不动

**用户决策**：加 `DCRColorSpace` 枚举，默认 `.linear`（语义正确版本），不 refit，用户自己试。不行再一行 flip 回 `.perceptual`。

### F3 — Pipeline public var properties

**问题**：
```swift
public final class Pipeline: @unchecked Sendable {
    public var steps: [AnyFilter]
    public var optimizer: FilterGraphOptimizer
    public var intermediatePixelFormat: MTLPixelFormat
}
```

**根因验证**：在 demo + SDK + tests 全部代码路径里，**没有任何地方 mutate 这三个**。都是 init 时配好就用。纯代码洁癖问题。

### F4 — TexturePool 跨 CB 复用的潜在 race

**问题**：`Pipeline.encode` 和 `MultiPassExecutor.execute` 在 CB 还在 encoding 阶段就 `texturePool.enqueue(texture)` 把中间 texture 还回池。如果另一个 CB（不同 queue）此时 dequeue 同 spec，就拿到了**还在被 GPU 使用**的 texture，跨 CB GPU 执行顺序不保证 → race。

**根因验证**：
- `Pipeline.swift` encode 循环第 189-191 行和 284-285 行：CB commit 前就 enqueue
- `MultiPassExecutor.swift:158-164`：同样
- Demo 实际场景：两个 MetalPreview coordinator 都走 MainActor.assumeIsolated，CPU encoding 串行 → demo 不触发
- **但 SDK 用户其他集成（视频处理、后台导出 + 前台预览并行）会触发**，是 SDK 正确性 bug

### F5 — AnyFilter @unchecked Sendable

**agent 诊断偏了**：`FilterProtocol: Sendable` 和 `MultiPassFilter: Sendable` 都**已经约束 Sendable**。`any FilterProtocol` existential 在 Swift 6 下理论应自动 Sendable，但编译器保守推导不出来，所以加了 `@unchecked`。

**验证**：语法补丁，不是安全漏洞。可能能清理（Swift 6 新语法 `any (Sendable & FilterProtocol)`）。

---

## 2. P0–P4 执行 plan

### P0 — 精度链修复（task #17）

**SDK 改动**：

1. `MultiPassFilter.swift`：
   - `TextureInfo.init(texture:, overridePixelFormat: MTLPixelFormat? = nil)` — 加 override 参数
   - `TextureSpec.resolve(source:, resolvedPeers:, overridePixelFormat: MTLPixelFormat? = nil)` — 所有 case 用 override 优先
   
2. `MultiPassExecutor.swift:67-74`：
   - `execute(..., intermediateFormat: MTLPixelFormat)` — 加参数，默认 `source.pixelFormat`（保持 caller 不传时不变）
   - 所有 `pass.output.resolve(...)` 传 `overridePixelFormat: intermediateFormat`
   
3. `Pipeline.swift:374-387` `executeMultiPass`：
   - 传 `intermediateFormat: self.intermediatePixelFormat`
   - `filter.passes(input: TextureInfo(texture: sourceTexture, overridePixelFormat: self.intermediatePixelFormat))`
   
4. `MPSDispatcher.swift:121-153` `encodeMeanReduction`：
   - 输出 texture 格式强制 `.rgba16Float`（不再随 source）
   
5. `ImageStatistics.swift:109-165` `readLumaFromMean`：
   - 删除 bgra8Unorm / rgba8Unorm / default 分支，只保留 rgba16Float 路径

**测试**：
- `MultiPassFilterTests` 加：`testHighlightShadowPositiveWithBgra8UnormSource` — 构造 bgra8Unorm source（模拟相机），跑 HighlightShadow(+100, 0)，验证中心像素值 > 原始值（正向有效）
- `MultiPassFilterTests` 加：`testClarityStableAcrossTwoIdenticalRuns` — 同 source 连跑 2 次 Clarity，输出必须 bit-identical（不抖）
- `MultiPassFilterTests` 加：`testSoftGlowPreservesSpatialGradient` — bloom 输出不全是 1.0（用 HDR 纹理验证中间值 > 1）

---

### P1 — TexturePool CB-safe enqueue（task #18）

**SDK 改动**：

1. `Pipeline.swift:170-200` `encode(into commandBuffer:)`：
   ```swift
   var pendingEnqueue: [MTLTexture] = []
   for (index, step) in optimizedSteps.enumerated() {
       ...
       if currentInput !== sourceTexture, currentInput !== output {
           pendingEnqueue.append(currentInput)  // 不 enqueue，收集
       }
       ...
   }
   
   let texturesToEnqueue = pendingEnqueue
   let poolRef = texturePool
   commandBuffer.addCompletedHandler { _ in
       for tex in texturesToEnqueue { poolRef.enqueue(tex) }
   }
   ```

2. `MultiPassExecutor.swift:158-164`：同样 — 收集到 `pendingEnqueue`，在 `execute` 返回前挂 `addCompletedHandler`

**测试**：
- 新文件 `Tests/DCRenderKitTests/ConcurrencyStressTests.swift`
- `testTwoPipelinesConcurrentEncodingDoesNotShareTextures` — 两个 Pipeline 各自独立 queue + CB，并发 encode 1000 次同 spec 的链，用 outputTexture identity set 验证无交叉

---

### P2 — Pipeline immutable（task #19）

**改动**（`Pipeline.swift`）：
- `public var steps: [AnyFilter]` → `public let steps: [AnyFilter]`
- `public var optimizer: FilterGraphOptimizer` → `public let`
- `public var intermediatePixelFormat: MTLPixelFormat` → `public let`
- 加 `public let colorSpace: DCRColorSpace`（P4 同时引入）
- 删除 L42-47 的"不能并发调用"段（现在真的可以了）

验证 `swift test` 全绿，无破坏。

---

### P3 — AnyFilter Sendable 清理（task #20）

**改动**（`AnyFilter.swift`）：

先试：
```swift
public enum AnyFilter: Sendable {  // 去掉 @unchecked
    case single(any FilterProtocol)
    case multi(any MultiPassFilter)
}
```

Swift 6 能推出来就保留。推不出保留 `@unchecked` 加 justification 注释：
```swift
/// Swift 6 doesn't automatically recognize `any P` as Sendable even when
/// `P: Sendable` is declared. Both FilterProtocol and MultiPassFilter
/// require Sendable conformance, so every concrete case payload IS
/// Sendable — the @unchecked is a syntax workaround, not a safety lie.
```

---

### P4 — ColorSpace 契约（task #21，默认 .linear）

**新文件 `Sources/DCRenderKit/Core/DCRColorSpace.swift`**：
```swift
public enum DCRColorSpace: Sendable {
    case perceptual
    case linear
    
    public var recommendedDrawablePixelFormat: MTLPixelFormat {
        switch self {
        case .perceptual: return .bgra8Unorm
        case .linear:     return .bgra8Unorm_srgb
        }
    }
}
```

**`DCRenderKit.swift`**：
```swift
public enum DCRenderKit {
    public static let version = "0.1.0-dev"
    public static let channel = "dev"
    
    /// 默认色彩空间。一行 flip 开关 — 改成 .perceptual 即可切回
    /// Harbeth 风格的 gamma-space pipeline + DigiCam parity。
    public static let defaultColorSpace: DCRColorSpace = .linear
}
```

**`Pipeline.swift`**：
- `init(..., colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace)`
- 存为 `public let colorSpace`

**`TextureLoader.swift`**：
- `makeTexture(from cgImage: CGImage, usage:, storageMode:, colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace)`
- `.linear` → `.SRGB: true`（GPU 自动 linearize 读入）
- `.perceptual` → `.SRGB: false`
- CVPixelBuffer 路径类似处理

**`ExposureFilter.swift` + `.metal`**：
```swift
struct ExposureUniforms {
    var exposure: Float
    var isLinearSpace: UInt32  // 1 if .linear, 0 if .perceptual
}
```

shader 分支：
```metal
if (u.isLinearSpace == 0u) {
    // Perceptual 路径（当前行为）
    float linear = dcr_perceptualToLinearApprox(c);
    float mapped = gained * (1 + gained/white2) / (1 + gained);
    color[ch] = dcr_linearToPerceptualApprox(clamp(mapped, 0, 1));
} else {
    // Linear 路径（输入已经 linearized）
    float mapped = max(c, 0.0) * gain;
    mapped = mapped * (1 + mapped/white2) / (1 + mapped);
    color[ch] = clamp(mapped, 0, 1);
}
```

`ExposureFilter.swift` 的 `uniforms` 读 `DCRenderKit.defaultColorSpace`（或通过 Pipeline 注入，需要设计接入点）。**设计待定**：最简单 Pipeline 在 executeSinglePass 时注入 colorSpace，或 filter 自己读全局默认。

**其他 16 个 filter 不动**（接受 .linear 下曲线偏移）。

**文档**：

1. `DCRenderKit.swift` 顶部加：
```swift
/// ## Color Space Convention
///
/// DCRenderKit supports two operating color spaces:
///
/// - `.linear` (default): Textures are loaded with GPU-side sRGB→linear
///   conversion; intermediate textures store linear float values;
///   filters' math is mathematically correct for linear space.
///   Drawable must be `.bgra8Unorm_srgb` for correct display.
///
/// - `.perceptual`: Textures are loaded as-is (sRGB gamma encoding);
///   filters' math runs on gamma-encoded values. Matches DigiCam /
///   Harbeth behavior. Drawable should be `.bgra8Unorm`.
///
/// Switch via `DCRenderKit.defaultColorSpace`.
```

2. `README.md` 加一段 Color Space。

3. `ExposureFilter` 的 pow(,2.2) 提取成 `dcr_perceptualToLinearApprox` helper + 注释解释为什么是 2.2 近似（和 DigiCam 参数拟合配套）。

**Demo 改动**：
- `MetalImagePreview.makeUIView` 和 `MetalCameraPreview.makeUIView`：
  ```swift
  view.colorPixelFormat = DCRenderKit.defaultColorSpace.recommendedDrawablePixelFormat
  ```

---

## 3. 切换代价

切回 `.perceptual` 就改一行：
```swift
public static let defaultColorSpace: DCRColorSpace = .perceptual
```

重编 SDK + demo，跑起来全 DigiCam parity。零代码改动，零 refit。

---

## 4. 工作量估算

| P | SDK 代码 | Demo 代码 | 测试 | 文档 |
|---|---|---|---|---|
| P0 | ~40 行 | - | 3 | - |
| P1 | ~30 行 | - | 1 | - |
| P2 | ~5 行 | - | - | - |
| P3 | ~1 行 | - | - | - |
| P4 | ~60 行 | ~5 行 | 1 smoke | ~50 行 |

总 ~140 行 SDK + 10 个新测试。~2 小时工作。

---

## 5. 验收标准

- [ ] `swift test` 全绿（≥ 210 tests）
- [ ] `swift build -Xswiftc -warnings-as-errors` 零 warning
- [ ] HighlightShadow 正向 solo 有效（用户实测）
- [ ] Clarity 画面稳定（用户实测）
- [ ] SoftGlow 有层次感（用户实测）
- [ ] `.linear` 默认下 demo 正常渲染，照片 / 相机都不崩
- [ ] `DCRenderKit.defaultColorSpace = .perceptual` 改一行后 demo 也正常（一行 flip 验证）

---

## 6. 后续（Phase 2 视觉评估后决定）

如果 `.linear` 默认效果好：就是新基线，DigiCam parity 作为 optional fallback 保留。

如果 `.linear` 默认效果不如 perceptual：切回 `.perceptual` 默认，等 Phase 2 有时间再 refit 那 5 个参数化 filter。

**不 block Phase 2 其他工作**。

---

## 7. 2026-04-22 audit: .linear 隐性漂移清单

P4 + Phase C/D 后的补充审计。已修复的 fitted filter wrap（5个）+ LUT3D wrap 覆盖了**曲线类 + 色彩映射类**，但有若干 filter 的参数默认值 / 阈值 / 空间假设仍锚定 gamma 空间，`.linear` 下会有漂移——分级：

### 7.1 已修复 (commit 24b9784 + 7c5b608)

- Exposure（pos 原生 + neg wrap）
- Contrast（wrap + lumaMean 转 gamma 做 pivot 查）
- Whites（两分支 wrap + Swift LUT 转 gamma 查 anchor）
- Blacks（wrap）
- WhiteBalance（wrap 整个 YIQ→tint→warm-overlay pipeline）
- LUT3D（wrap 输入输出，cube 在 gamma 空间查）

### 7.2 `.linear` 漂移重审（2026-04-22 基于真机反馈 + 原理复查）

**纠正**：初版 §7.2 把所有 "linear 下行为偏离 perceptual" 全部当作"漂移 = 要修"，这是错的。

**关键判据**（用户真机 SoftGlow 反馈反向验证后收敛）：

- **光学 / 发光 / 模糊 / 物理混合**类 → linear **物理正确**，保留不 wrap（wrap 反而破坏"更好"）
- **gamma 分段阈值 / 窗口 / 依赖"人眼感知"数学**类 → linear **打破设计意图**，必须 wrap
- **纯色彩运算（非曲线/阈值）** → 两空间都合法，仅"手感"微异，可接受

#### A. 保留 — `.linear` 下更好 / 更物理正确

| Filter | 原因 | 真机反馈 |
|---|---|---|
| **SoftGlow** | bloom 是光学叠加；光在 linear 才物理正确相加；threshold 偏移使 bloom 更选择性（只真亮部发光→更像真实镜头眩光） | "很好" |
| **NormalBlend** | alpha compositing 的 Porter-Duff over 数学定义在 linear 空间 | 未测 |
| **PortraitBlur** | 景深模糊本质是光学模糊；mask 来自 Vision 空间无关 | F2 不工作（独立 bug） |
| **Sharpen** | Laplacian 在 linear 捕捉真实光子梯度 | "还可以" |
| **FilmGrain** | 暗部颗粒更重 = 真实胶片特性；linear 意外对齐模拟胶片手感 | 未报问题 |
| **CCD（整体）** | LUT 已 wrap / 锐化 linear 更对 / 颗粒同 FilmGrain / CA 空间无关 | 未报问题 |

**这些不要 wrap**。

#### B. 必修 — `.linear` 打破设计意图（F3 的主要修复路径）

| Filter | 为什么必修 | 修法 |
|---|---|---|
| **HighlightShadow** | smoothstep 窗口 `[0.25, 0.85]` / `[0.15, 0.75]` 按 gamma 空间精确锚在"中亮到高亮"、"阴影到中亮"。`.linear` 下 baseLuma=0.25 对应 gamma 0.53 → **"高光窗口"只在真高亮区触发**、中亮区完全不响应 → **F3 "缺层次感 / 对高光暗部不够敏感"的直接原因** | shader 里 `baseLuma_gamma = dcr_linearToGamma(baseLuma_linear)` 再做 smoothstep |
| **Clarity** | 同架构（guided filter base）。"局部对比度"设计目的是感知对比度，**只在 gamma 空间才匹配人眼感受** | 同 HS：residual 计算用 gamma-space base |

#### C. 灰色 — 认知偏移但非 bug

| Filter | 偏移性质 |
|---|---|
| **Saturation** | Rec.709 luma 在 linear 是物理 luminance, gamma 是感知近似。零饱和"灰"微异，视觉都合格 |
| **Vibrance** | max-mean 色度代理幅度不同,相对响应特性一致 |

不改代码,文档化"linear 下色彩感觉略不同"。

### 7.3 未修复的纯拟合 tech debt（原理派替代）

三个 filter 当前用 MSE 选的经验公式：

- **Contrast**: cubic pivot `y = x + k·x·(1-x)·(x-pivot)` — MSE=52.1 的优选
- **Blacks**: `y = x·(1 + k·(1-x)^a)` — MSE=0.63 vs weighted-parab / power-law
- **Exposure 负向**: 复合 `A·x^γ + B·x` — 非原理派（正向 Reinhard 是原理派）

**原理派候选**（log-space / filmic 家族）：
- **Contrast**: log-space 线性变换 = linear 空间的 power curve 锚在 pivot，`y = pivot·(x/pivot)^slope`。DaVinci Resolve primary contrast 的数学形式。
- **Blacks**: Filmic toe function（有论文引用），或 gamma 参数化。
- **Exposure 负向**: 负 EV offset + 阴影 toe（对称于正向 Reinhard 架构）。

**为什么不立即替换**：
- 所有 5 个 fitted filter 是**以 Lightroom 导出图为 ground truth** 拟的
- 替换 = 换了套 UI 手感（"相同 slider 值看起来不一样"）
- **产品决策不是工程决策**
- 建议 Phase 2 重新采集 LR 参考数据时一起做

### 7.5 F3 修复完成（2026-04-22，commit 2907b2b）

HighlightShadow + Clarity 的 baseLuma 空间错位已修：shader 中 baseLuma 在
smoothstep 前转 gamma；apply 步骤的 ratio-multiply 也整体 gamma-wrap。
加 3 个 parity 测试 + F3 直接回归测试（linear 0.133 midtone 必须被 HS
slider 激活）。248 tests 全绿。

---

### 7.4 `.linear` 漂移的正确认知（两次迭代后的最终版）

三次说法：

1. **P4 时**：「其他 16 个 filter 不动，math 自动作用新空间」 — **错**
2. **§7.2 初版**：「11 个都有漂移，严重度从低到高」 — **过度激进**
3. **§7.2 重审（本版）**：「光学类 linear 更好、曲线/阈值类必修、纯色彩类可接受」 — **基于 SoftGlow 真机反馈反向验证的收敛结论**

真机反馈是关键的反证据：**如果审计判据无法解释"SoftGlow 反而更好"，判据就是错的**。修正后的判据可以统一解释所有真机观察。

**当前状态**：最大的两处（5 个 fitted + LUT3D）已 wrap，**其余见 7.2** 列为 Phase 2/3 tech debt。`.linear` 默认仍可用，但用户真机体验会有以上 table 描述的偏移。

---

## 8. 彻底严谨化 audit plan（2026-04-22，上下文告急前持久化）

基于 session 里三层反复收敛的教训：
1. "激进/保守"不是质量判据（`.claude/rules/engineering-judgment.md §1`）
2. 横切关注点改动必然迭代（§2）
3. 替换算法前问历史（LLF 教训，§3）
4. 过去 Claude 推荐的"业界通用做法"可能是合成，需 fetched URL 重新验证（§4）
5. Perception-based 不是不可形式化的挡箭牌（§5）

### 8.1 Autonomous — 我独立可做（~12h）

- [ ] **A.1 pow(,2.2) 换真 sRGB 曲线**（IEC 61966-2-1 分段式）。6-7 个 .metal helper 替换 + parity 测试 tolerance 调整（从 0.05→~0.02）
- [ ] **A.2 Tier 2 magic number 全部 FIXME 注释** + origin 追溯尝试。完整清单：
  - HS: smoothstep 窗口 `[0.25, 0.85]` / `[0.15, 0.75]`
  - HS: product compression `× 0.35 highlight`、`× 0.50 shadow`
  - HS / Clarity: guided filter `ε = 0.01 / 0.005`, `p = 0.012 / 0.019`
  - HS / Clarity: ratio clamp `[0.3, 3.0]`、saturation compensation `clamp(0.8, 1.3)`
  - Clarity: product compression `× 1.5 positive`、`× 0.7 negative`
  - SoftGlow: `log2(shortSide / 135)` 金字塔深度锚
  - SoftGlow: `× 0.35 strength` 压缩
  - Sharpen: `× 1.6` product compression
  - WhiteBalance: warm target `(0.93, 0.54, 0.0)`、Kelvin 斜率 `0.0004 / 0.00006`、Q 轴 clamp `× 0.5226 × 0.1`
  - Exposure: `EV_RANGE = 4.25`、Reinhard white point × `0.95`
  - FilmGrain: 压缩 `× 0.144`
  - CCD: 步骤顺序 "CA → saturation → noise → sharpen"、CA `caMaxOffset`、锐化 `× 0.96 (60% of Sharpen)`
- [ ] **A.3 FilmGrain sin-trick 4K pattern 验证**。构造 4096×4096 uniform patch，dump 输出观察有无网格/条纹。如有 → 换 PCG hash 或 Wyvill hash
- [ ] **A.4 CCD 步骤顺序文献溯源**（"CA → sat → noise → sharpen" 是否有 sensor 物理依据）。找到 → 加 citation；找不到 → 声明 "artistic choice, not sensor simulation"
- [ ] **A.5 PortraitBlur 代码审 + F2 根因调查**。读 implementation + shader + mask pipeline。找到失效原因。（与 color space 独立）
- [ ] **A.6 测试 tolerance 错误预算显式建模**。pow(,2.2) ≈ 2% / op，2 ops 累积 ~4%；Float16 量化 ~0.2%；guided filter 噪声 ~2%。加 rules/testing.md 条目
- [ ] **A.7 Vibrance 换 CIELAB C* chroma**。改 shader，实现 `chroma = √(a² + b²)` 作为饱和代理。有标准公式可查（CIE 1976）

### 8.2 Contract formalization — Perception-based filter 行为契约（~12-18h）

每个 filter 写 1-2 页 contract + 构造合成测试图：

- [ ] **A+.1 HighlightShadow 契约**：
  - halo-free: edge-step 过冲 < Δ%（待测定 Δ）
  - Weber-linear slider: effect magnitude 在 log-luma 单位线性
  - Zone 系统 targeting: Zone VII+ (gamma ≥0.7) = full highlight 响应
  - midtone 稳定性: baseLuma ∈ [0.4, 0.6] 下 slider 效果 < 5% 满量程
- [ ] **A+.2 Clarity 契约**：
  - spectral band 选择性: FFT 在 [ω_lo, ω_hi] 放大 >6dB，两侧衰减 >6dB
  - edge preservation: 无 Gibbs ringing（主瓣外 sidelobe < 3dB）
  - dynamic range preservation: max-min 在 ε 内
- [ ] **A+.3 SoftGlow 契约**：
  - additivity: bloom(a+b) = bloom(a) + bloom(b) 在 linear 空间
  - threshold-gated energy: ∫bloom = K·∫{I > threshold}·I·p(I)

### 8.3 Contract verification — 按契约测实现（~15-25h）

**每个 filter 进入 A++ 前先问 Design History**（见 rules §3）：

- [ ] 我进入 filter X 的契约化前，先 dump 我回忆的历史 → 你补充/更正 → 才决定 patch vs document vs 重写
- [ ] **A++.1 HighlightShadow**：测 halo 实际边界；LLF 历史文档化（尝试过 N 次失败，guided filter 作为 trade-off）
- [ ] **A++.2 Clarity**：FFT 验证 spectral selectivity
- [ ] **A++.3 SoftGlow**：光学 additivity + 能量守恒测

### 8.4 Industry claim audit — 重新调研 7 个算法选择（~10-15h）

**硬约束**：只能引 fetched URL / DOI，不能引记忆（`rules/engineering-judgment.md §4`）。

- [ ] **Audit.1 SoftGlow Dual Kawase** — 查 Unity HDRP / Unreal Bloom / darktable / Blender 实际实现
- [ ] **Audit.2 Clarity guided filter residual** — 查 Adobe ACR / darktable / RawTherapee
- [ ] **Audit.3 Vibrance max-avg proxy** — 查 Adobe / Capture One / darktable
- [ ] **Audit.4 CCD 步骤顺序** — 查 sensor noise modeling 论文 / VSCO 类 filter 实现参考
- [ ] **Audit.5 HighlightShadow guided filter** — LLF 不可得情况下的主流替代
- [ ] **Audit.6 FilmGrain sin-trick** — 是 shadertoy 做法还是主流胶片模拟（AgX / darktable / VSCO）
- [ ] **Audit.7 Tone curve families** — Contrast/Blacks/Exposure-neg 是否有 OCIO / ACES / Filmic Blender / AgX 的标准曲线可参考

**建议顺序**：先 3 个（SoftGlow / Clarity / Vibrance） → 看 LLM-fabrication rate
- 2+ 个是编的 → 全审
- 基本靠谱 → 按需

### 8.5 需要用户决策 (B)

- [ ] **B.1 Tier 3 纯拟合替换**是否接受 slider 手感变化？具体替换候选：
  - **Contrast**: 当前 cubic pivot `y = x + k·x·(1-x)·(x-pivot)` → 候选 log-space 线性（= linear 空间的 power curve 锚 pivot）`y = pivot·(x/pivot)^slope`（DaVinci Resolve primary contrast 数学形式）
  - **Blacks**: 当前 `y = x·(1 + k·(1-x)^a)` → 候选 Filmic toe function（Blender Filmic / AgX 的 toe 公式）
  - **Exposure 负向**: 当前复合 `A·x^γ + B·x` → 候选 "负 EV offset + 阴影 toe"（对称于正向 Reinhard 架构）或 inverse Reinhard
  - **Vibrance**: 当前 `max - avg` 色度代理 `× -3.0` → 候选 CIELAB C* = √(a²+b²) 作为饱和度代理（CIE 1976 标准）
- [ ] **B.2 EV_RANGE=4.25** 保留 Harbeth parity 还是对齐 Lightroom 标准（Lightroom 典型 ±5 EV）？
- [ ] **B.3 Saturation/Vibrance 在 linear 下的微偏**是否接受？
- [ ] **B.4 真 sRGB 曲线引入后，既有 parity 测试 tolerance 从 0.05 调到 0.02** 可接受？
- [ ] **B.5 Harbeth port 后的算法"业界通用"声明可信度**：若 §8.4 发现 2+ 个是过去 Claude 合成的 pseudo-consensus，是否全量重新调研 7 个？

### 8.6 需要用户数据 (C)

- [ ] **C.1** 1-2 张 RAW 或 16-bit TIFF 源图 + 每个 slider ±50/±100 的 Lightroom 导出图。导出配置：**Linear 色彩空间，16-bit TIFF**（需要 LR 的 ProPhoto Linear 或 AdobeRGB Linear）
- [ ] **C.2** 完成 C.1 后：用真 Lightroom ground truth 对比 DCRenderKit 的 linear pipeline，**重拟合** 5 个 fitted filter（取代继承的 Harbeth 常数）

### 8.7 本质上限的诚实改写（原 D → D'）

"本质上限" 是我之前用来逃避的说法。每项实际**都可形式化**，只是我需要做功：

- "HS/Clarity 层次感" → §8.2 contract
- "bloom 更物理正确" → §8.3 A++.3 additivity 测
- "商用级" → 定义 PSNR/SSIM vs reference 在 Δ 内（要求 §8.5 产品决策）

### 8.8 当前持久化在哪

- **规则**：`.claude/rules/testing.md`（测试严谨性）+ `.claude/rules/engineering-judgment.md`（方法论，新加）
- **本 plan**：本文件 §8
- **memory**：`~/.claude/projects/.../memory/project_dcrenderkit.md`

### 8.10 超出当前审计 scope 的未来阶段项（不要忘）

以下是"商用级开源 SDK"目标所需但**不属于当前 rigor audit**，在 §8.1–8.6
完成后应单独规划：

**Phase 2 性能与稳定性**：
- [ ] 性能 benchmark（当前未量化；4K 典型链 ~0.2ms/filter 是预测不是实测）
- [ ] 内存 profile（TexturePool 行为、峰值占用）
- [ ] 真机功耗（GPU utilization、散热）
- [ ] 视频管线（per-frame 场景，当前 SDK 未跑过）

**Phase 2 平台覆盖**：
- [ ] macOS 路径验证（当前所有测试在 macOS 跑但 Demo 只在 iOS 跑）
- [ ] Catalyst 兼容性未测
- [ ] tvOS / visionOS 未规划

**Phase 2 开源发布**：
- [ ] README（中英双语）
- [ ] CONTRIBUTING.md
- [ ] CODE_OF_CONDUCT.md
- [ ] CHANGELOG.md + SemVer 起跳
- [ ] DocC 文档生成
- [ ] LICENSE 明确（已选 MIT）
- [ ] Package.swift 最终化（当前 dev，需要冻结 API）
- [ ] GitHub Actions CI（swift test + swift build warnings-as-errors）
- [ ] 发布 0.1.0-dev → 0.1.0 决策

**Phase 2 API 稳定性**：
- [ ] 所有 public API 标 `@available` 版本号
- [ ] 内部类型改为 `internal` 严格（当前部分混乱）
- [ ] 弃用标记机制（`@deprecated` 用于后续重命名）

**Phase 2 Harbeth port 完整性**：
- [ ] 每个 filter 对照原 Harbeth 源码，验证 "ported from" 注释声明与实际
      行为一致（当前是 spot-check，不是系统性审）
- [ ] 遗漏 feature 清单（Harbeth 有而 DCRenderKit 没有的）
- [ ] DigiCam 迁移影响评估（哪些 DigiCam 代码要改）

---

### 8.11 核心未解决的**方法论**问题

已经识别但没有解法：

- **循环验证问题**：当前所有 `.linear` parity 测试用 pow(,2.2) 做 shader 和断言两端，只证明"我跟我自己一致"。**突破需要 §8.6 C 的真 Lightroom linear 导出**。没有它，所有"matches Lightroom" 声明永远未验证。
- **闭源竞品验证**：Lightroom / Capture One / DaVinci 的具体公式不可见。我们只能用开源等价物（darktable / RawTherapee / Blender Filmic）作参考。接受"商用级 ≠ 像素级匹配 Adobe"的定义。
- **Magic number origin 失传**：Harbeth 的拟合脚本已丢失。即使 §8.1 A.2 加了 FIXME 注释，真正要"溯源"必须**重新建立 fitting pipeline**，这是 §8.6 C 的延伸工作。

---

### 8.9 Resume prompt（压缩后启动用）

```
继续 DCRenderKit 的彻底严谨化 audit。先读：
1. DCRenderKit/docs/findings-and-plan.md §8（完整 TODO）
2. DCRenderKit/.claude/rules/engineering-judgment.md（6 条方法论）
3. DCRenderKit/.claude/rules/testing.md（测试严谨性）
4. ~/.claude/projects/.../memory/project_dcrenderkit.md

当前完成：P0–P4、Phase A、Phase C（5 fitted wrap）、LUT3D wrap、F3 fix
(HS+Clarity)。248 tests 全绿。

下一步按 §8.1 A.1–A.7 顺序，或 §8.4 Audit.1–.3 先启动。
进入 §8.3 前先问 Design History（§8.3 顶规则）。
```
