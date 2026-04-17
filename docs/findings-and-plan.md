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
