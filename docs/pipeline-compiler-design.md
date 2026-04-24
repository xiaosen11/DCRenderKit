# DCRenderKit Pipeline Compiler — Phase 0 Design Document

**Status**: FINAL · 2026-04-24 · User signed off Q1/Q2/Q3/Q4

**目的**: 把 DCRenderKit 从"filter 数组 + 逐个 dispatch"升级为带 IR 的 pipeline compiler，实现 *"无论叠多少 filter，运行时开销都像一个 filter"* 的 SDK 契约。

**决策结论**:
- **Q1** (shader body 规范化) → **方案 B**：删除所有 production standalone kernel，只保留 body function；所有执行（含单 filter）都走 codegen uber kernel。Legacy kernel 临时保留在 test target 作为 Phase 1-7 的 parity reference。
- **Q2** (warm-up) → **SDK 提供** `PipelineCompilerWarmUp.preheat(...)`
- **Q3** (tail sink) → **激进版**：multi-pass filter final pass 可吸收下游 pixelLocal body
- **Q4** (public API) → 按 §9 的 6 条 additive 新增项过

---

## §1 目标与非目标

### §1.1 目标（功能/行为）

1. **跨 filter 自动 fusion** — 用户写 `[Exposure, Contrast, Saturation, WhiteBalance, LUT3D]` 应该和写一个单 filter 的 GPU 开销数量级相同（1 次 compute dispatch，0 或极少中间 texture）。
2. **Multi-pass 与 single-pass 跨层合并** — HS / Clarity / SoftGlow 等 multi-pass filter 的 final pass 能**吸收**它上下游紧邻的 pixel-local filter（激进 tail sink + head inline）。
3. **公共 pass 共享** — HS 和 Clarity 同时存在时，guided-filter 的 downsample pass 共享一次计算。
4. **TBDR / Tile memory 路径** — 连续 pixel-local 链通过 fragment shader + memoryless attachment 跑在 on-chip tile memory，intermediate 不写 device memory。
5. **Fusion 默认开**，`Pipeline.optimization = .none` 可关（见 §9 语义定义）。
6. **行为等价**：fusion 前后任意组合的输出应在 Float16 quantisation margin (≤ 0.005 per channel) 内 bit-close。
7. **SDK 契约不变**：`FilterProtocol` / `MultiPassFilter` / `AnyFilter` / `Pipeline` 既有 public API 保持 v0.1.0 freeze 状态；仅 additive 新增 §9 列的 6 条。

### §1.2 非目标

1. **不暴露 IR 类型** — Node / Optimizer pass / Codegen 都是 `internal`。第三方 filter 接入 fusion 通过 `FilterProtocol.fusionBody` opt-in property，不直接写 IR。
2. **不改 Tier 2 曲线**（user 冻结决策）— shader body 转成 "可 fuse" 形式时**严格保持逐像素输出等价**，参数/算法/补偿项一个都不动，由 legacy kernel parity test 守护。
3. **不追求编译期（AOT）生成所有 uber kernel 变体** — 用运行时 Metal source 拼接 + PSO cache + startup warm-up。
4. **不重写 non-pixel-local filter 的算法** — Sharpen / HS / Clarity / SoftGlow / PortraitBlur / FilmGrain / CCD 的内部逻辑保持现状；只把它们的 body 抽出来接入 codegen，让它们可被 compiler 调度、与邻居合并。
5. **Production binary 不保留 standalone kernel 路径**（方案 B 的直接后果）—— legacy kernel 只在 test target 编译，SDK shipping 产物里没有它们。

### §1.3 成功度量

| 度量 | Phase 5（compute fusion 上线） | Phase 7（TBDR 上线） |
|---|---|---|
| **8-filter 纯色调链 dispatch 数** | 8 → 1 | 8 → 1 |
| **intermediate rgba16Float texture 峰值**（4K） | ~500MB → ≤ 66MB | → ~0（memoryless） |
| **CPU 端 encode 时间** | O(N) → O(1) | O(1) + TBDR overhead |
| **真机 preview CPU %**（user baseline） | user 确认"叠 4 个不再卡" | user 确认"叠 8 个仍流畅" |
| **Legacy parity** | 16 filter × 代表性 slider 全部 bit-equal（margin ≤ 0.005） | 同上 + fragment path parity |

---

## §2 架构总览（5 层）

```
┌─────────────────────────────────────────────────────────────┐
│ Consumer                                                     │
│   Pipeline(input, steps: [AnyFilter]).output() → MTLTexture  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 1 — Lowering                                           │
│   AnyFilter / MultiPassFilter.passes → Node DAG (IR)         │
│   internal type: PipelineGraph                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 2 — Optimizer (6 passes, ordered)                      │
│   DCE → VerticalFusion → CSE → KernelInlining → TailSink →   │
│   ResolutionFolding                                          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 3 — Backend codegen                                    │
│   ComputeBackend (production default — uber compute kernel)  │
│   TBDRBackend    (Phase 7 — render pipeline + memoryless)    │
│   NativeBackend  (internal — 不可 fuse 的 Node, e.g.         │
│                   downsample / reduce / MPS-backed passes)   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 4 — Scheduling & caching                               │
│   · GraphSignature → PSO cache key                           │
│   · PipelineCompilerWarmUp.preheat(...)  (SDK API)           │
│   · 单 CommandBuffer 批处理整张图                            │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 5 — Resource allocator                                 │
│   · Lifetime-aware TextureAllocator (aliasing)               │
│   · Memoryless intermediates (TBDR path)                     │
│   · 现有 deferred enqueue 兼容                              │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
                      Metal GPU
```

每层职责严格分离，可独立测试：Lowering 不知道 codegen 怎么做、Optimizer 不知道 backend 是 compute 还是 TBDR、Codegen 不知道 allocator 策略。

---

## §3 IR 设计（Layer 1 产物）

### §3.1 Node 类型

```swift
// internal Sources/DCRenderKit/Core/PipelineGraph/Node.swift
internal enum NodeKind: Sendable {
    /// Per-pixel, same-coordinate function. 唯一可 vertical-fuse 的类型。
    case pixelLocal(
        body: ShaderBodyRef,           // 指向 filter 的 body function
        uniforms: FilterUniforms,      // 拍下的 uniform 值
        wantsLinearInput: Bool         // body 期望 linear 还是 gamma
    )

    /// 邻域读（Sharpen / Clarity detail / guided-filter / Poisson blur / ...）
    case neighborRead(
        body: ShaderBodyRef,
        uniforms: FilterUniforms,
        radiusHint: SpatialExtent,     // CSE / fusion 判断用
        additionalInputs: [NodeRef]    // mask / LUT / intermediate
    )

    /// 尺度变换（HS / Clarity / SoftGlow 的 downsample）
    case downsample(factor: Float, kind: DownsampleKind)
    case upsample(factor: Float, kind: UpsampleKind)

    /// 全图聚合（ImageStatistics.lumaMean）
    case reduce(op: ReduceOp)

    /// 二元合成
    case blend(op: BlendOp, aux: NodeRef)

    /// Optimizer 阶段产物：多个原始 pixelLocal Node 合成的 cluster
    /// 携带有序 body ref + 对应 uniforms 序列
    case fusedPixelLocalCluster(
        members: [FusedClusterMember],
        wantsLinearInput: Bool
    )
}

internal struct Node: Sendable, Identifiable {
    let id: NodeID                       // unique per graph, stable for testing
    let kind: NodeKind
    let inputs: [NodeRef]                // .source / .node(NodeID) / .additional(Int)
    let outputSpec: TextureSpec          // 复用现有 TextureSpec 枚举
    var debugLabel: String               // 比如 "Exposure#3"，调试用
}

internal enum NodeRef: Hashable, Sendable {
    case source
    case node(NodeID)
    case additional(Int)
}
```

**ShaderBodyRef** 指向 filter 的 body function 元信息，由 filter 在 lowering 时通过新 public property `FilterProtocol.fusionBody: FusionBodyDescriptor?` 提供。

### §3.2 Lowering 规则

| 来源 | 翻译 |
|---|---|
| `AnyFilter.single(ExposureFilter)` | 1 个 `pixelLocal` Node |
| `AnyFilter.single(SharpenFilter)` | 1 个 `neighborRead` Node（unsharp mask 需要 5 邻居） |
| `AnyFilter.single(LUT3DFilter)` | 1 个 `pixelLocal` Node，`additionalInputs = [lut3DTexture]` |
| `AnyFilter.multi(HighlightShadowFilter)` | 5 个 Node（downsample + 2 neighborRead + apply-ratio + final apply） |
| `AnyFilter.multi(SoftGlowFilter)` | N levels pyramid，每级 downsample + pixelLocal bright-gate，upsample + blend |
| `AnyFilter.multi(PortraitBlurFilter)` | mask as `.additional(0)`，2 次 neighborRead + pixelLocal composite |

**Lowering 完成后不变量**（`PipelineGraph.validate()` 检查，Phase 1 单测直接断言）：

1. 恰好一个 Node 被 `isFinal = true` 标记
2. 所有 `NodeRef.node(id)` 指向的 id 早于当前 Node 出现（拓扑序）
3. 所有 `NodeRef.additional(i)` 的 i 在 filter 的 `additionalInputs` 范围内
4. `outputSpec` 可解析（`TextureSpec.resolve()` 不返回 nil）
5. 没有 `fusedPixelLocalCluster` Node（fusion 是 Layer 2 产物，Layer 1 输出不含）

---

## §4 Shader Body 规范化（方案 B 实施方案）

### §4.1 Production shader 的新形态

每个 pixel-local filter 的 `.metal` 文件**删除原 kernel**，只保留 body function + uniform struct：

```metal
// Sources/DCRenderKit/Shaders/Adjustment/Exposure/ExposureFilter.metal
// (Phase 3 落地后形态)

#include <metal_stdlib>
using namespace metal;

// —— Uniform struct（保留）——
struct ExposureUniforms {
    float exposure;       // -1.0 ... +1.0
    uint  isLinearSpace;
};

// —— Helpers (mirrored)（保留）——
inline float DCRSRGBLinearToGamma(float c) { ... }
inline float DCRSRGBGammaToLinear(float c) { ... }

// —— Body function（唯一 production symbol）——
// @dcr:body-begin DCRExposureBody
inline half3 DCRExposureBody(half3 rgb, constant ExposureUniforms& u) {
    const float exposure = clamp(u.exposure, -1.0f, 1.0f) * 0.7f;
    const bool isLinear = (u.isLinearSpace != 0u);
    // ... (原 kernel for-ch loop 的内容原样搬进来) ...
    return result;
}
// @dcr:body-end
```

**不再存在** `kernel void DCRExposureFilter(...)` 的声明。所有运行时 kernel（包括单 filter 场景）都由 ComputeBackend / TBDRBackend 在运行时生成。

Body 函数两侧的 `// @dcr:body-begin <name>` / `// @dcr:body-end` 是 **codegen 的源抽取 marker**—— runtime 读 `.metal` 文件、按 marker 截出 body 文本，与其他 filter 的 body 拼接成 uber kernel。

### §4.2 Codegen 生成的 uber kernel（例）

`Exposure + Contrast + Saturation` 三 filter fusion：

```metal
// UberKernel_<hash>  — runtime generated by ComputeBackend
#include <metal_stdlib>
using namespace metal;

// helpers (按需去重注入 — sRGB / OKLab / ...)
inline float DCRSRGBLinearToGamma(float c) { ... }
inline float DCRSRGBGammaToLinear(float c) { ... }
inline float3 DCRLinearSRGBToOKLab(float3) { ... }
inline float3 DCROKLabToLinearSRGB(float3) { ... }
// ... (按 cluster 成员的依赖集合注入) ...

// uniform structs (按出现顺序)
struct ExposureUniforms   { float exposure; uint isLinearSpace; };
struct ContrastUniforms   { float contrast; float lumaMean; uint isLinearSpace; };
struct SaturationUniforms { float saturation; };

// bodies (从各 .metal 文件 runtime 抽出)
inline half3 DCRExposureBody(half3, constant ExposureUniforms&)   { ... }
inline half3 DCRContrastBody(half3, constant ContrastUniforms&)   { ... }
inline half3 DCRSaturationBody(half3, constant SaturationUniforms&) { ... }

kernel void DCR_Uber_abc123(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant ExposureUniforms&    u0 [[buffer(0)]],
    constant ContrastUniforms&    u1 [[buffer(1)]],
    constant SaturationUniforms&  u2 [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    half4 c = input.read(gid);
    half3 rgb = c.rgb;
    rgb = DCRExposureBody(rgb, u0);
    rgb = DCRContrastBody(rgb, u1);
    rgb = DCRSaturationBody(rgb, u2);
    output.write(half4(rgb, c.a), gid);
}
```

**单 filter 场景**走同样的路径——只是 cluster 只有 1 个 body，kernel 退化成调用 1 次 body。

### §4.3 Legacy kernel 在 test target 的临时保留（Phase 1-7 生命周期）

方案 B 的风险是"production 无独立 kernel fallback"。Mitigation：

**Phase 1 伊始**，把现有 16 个 production kernel **逐字迁移** 到：

```
Tests/DCRenderKitTests/LegacyKernels/
  ├─ LegacyExposureFilter.metal
  ├─ LegacyContrastFilter.metal
  ├─ ...
  └─ LegacyLUT3DFilter.metal
```

- 仅在 test target 编译（通过 `project.yml` / `swift test` 资源配置），**不进 SDK shipping bundle**
- Kernel 名前缀改为 `DCRLegacy<Filter>Filter` 避免与 runtime 生成的 uber kernel 重名
- 逐字不动的原 shader code —— 任何 shader 改动都在 production body function 上做
- Phase 3 的 parity test 以这些 legacy kernel 输出为 ground truth 对照 codegen 生成的 uber kernel 输出

**删除时机**：Phase 7 真机终验通过 + `LegacyKernelParityTests` 在 main 上稳定跑过 ≥ 1 周（gate 由 user 最终 sign-off） → 提交单独的 "chore(test): remove legacy kernels after compiler stabilisation" commit。

### §4.4 `FilterProtocol.fusionBody` 新增 public property

```swift
public protocol FilterProtocol: Sendable {
    // … 现有成员不变 …

    /// Metadata enabling this filter to participate in compiler-driven
    /// fusion. SDK-built-in filters ship a non-nil descriptor; third-
    /// party filters can opt in by the same convention.
    ///
    /// Starting v0.2.0 (this work), returning nil means the filter is
    /// executed as a 1-member cluster (no fusion with neighbours), NOT
    /// a standalone kernel (standalone kernels have been retired).
    var fusionBody: FusionBodyDescriptor { get }   // 注意：非 optional
}

public struct FusionBodyDescriptor: Sendable {
    public let functionName: String            // "DCRExposureBody"
    public let uniformStructName: String       // "ExposureUniforms"
    public let kind: FusionNodeKind            // .pixelLocal / .neighborRead(radius:)
    public let wantsLinearInput: Bool
    public let sourceMetalFile: URL            // runtime body 源抽取入口
}

public enum FusionNodeKind: Sendable {
    case pixelLocal
    case neighborRead(radius: Int)
    case multiPassTerminal       // MultiPassFilter 内部 pass 用
}
```

方案 B 下 `fusionBody` 是**必须**提供的（非 optional），因为没有 fallback 到 standalone kernel 的路径。SDK 内置 16 filter 全部实现；第三方 filter 作者必须提供 body function（SDK documentation + `docs/custom-filter-authoring.md` 给明确示例）。

---

## §5 Optimizer Passes（Layer 2）

按固定顺序跑 6 个 pass。每个 pass 是 `fn (PipelineGraph) -> PipelineGraph` 的纯变换，fixture-driven 单测。

### §5.1 Pass 1 — DeadCodeElimination

删除产出不被任何 Node 读取（直接 + 间接）且非 final 的 Node。典型触发：identity 参数、CSE 后的 duplicate、tail sink 后的 orphan。

### §5.2 Pass 2 — VerticalFusion

扫描连续 `pixelLocal` Node 序列，合成一个 `fusedPixelLocalCluster`。合并条件：
1. 类型都是 `pixelLocal`
2. 前一个的输出是后一个的唯一输入（无 fan-out）
3. 所有 Node 的 `outputSpec == .sameAsSource`
4. `wantsLinearInput` 一致

### §5.3 Pass 3 — CommonSubexpressionElimination

`kind` + `uniforms` + `inputs` 完全相等的两个 Node 合成一个。典型触发：HS 和 Clarity 共享 guided downsample。

### §5.4 Pass 4 — KernelInlining (head fusion)

`neighborRead` Node N 的唯一 primary input 是一个 `pixelLocal` Node P 且 P 无其他 consumer 时，把 P 的 body 内联到 N 的每个 sample call 点。

**成本估算**：Optimizer 用预定义 body cost table（简单 tone/color body ≈ 1 ops；OKLab 转换 ≈ 20 ops；LUT3D 查表 ≈ 3 ops + 1 tex read）。若 `P.cost × N.sampleCount > dispatch_threshold`，放弃 inline。

### §5.5 Pass 5 — TailSink（激进版，Q3 决策）

两种 sink 场景都做：

**场景 A — pixelLocal 到 pixelLocal cluster 下游**：
已由 Pass 2 VerticalFusion 处理，这里兜底 Pass 2 后未合的边界情况。

**场景 B — multi-pass filter final pass 吸收下游 pixelLocal body**（激进版独有）：

条件：
1. multi-pass filter 的 final Node F（kind 可能是 `neighborRead`, `blend`, 或直接 `pixelLocal`）
2. F 的下游紧邻一个 pixelLocal Node P
3. F 无其他 consumer
4. `P.outputSpec == F.outputSpec`（同分辨率）

动作：
- 把 P 的 body 内联到 F 的 **write 点之前**（F 计算 result 后、write 前插入 `result = P.body(result, P.uniforms)`）
- P Node 删除，下游 reference 指向 F
- F 的 Node 标成 "has-trailing-body-sink"（codegen 时读这个标记，把 sink body 拼到 F 的 kernel 里）

**代码实现角度**：F 已经是某个 multi-pass filter 的内部 pass，它的 body 已规范化为 `DCR<Filter>FinalApplyBody(...)`；tail sink 只是在 codegen 时把 P 的 body 再串一下：

```metal
// codegen 生成的 F 的 kernel （已 sink 了 P 的 body）
kernel void DCR_HS_Final_SinkedSaturation_<hash>(...) {
    ...
    half3 hsResult = DCRHighlightShadowFinalApplyBody(...);   // F 的 body
    half3 sinked   = DCRSaturationBody(hsResult, pUniforms);   // P 的 body 被 sink 进来
    output.write(half4(sinked, alpha), gid);
}
```

**风险 & mitigation**:
- Sink 进 multi-pass final pass 可能改变 Tier 3 filter 的 output（因为多了一步 in-place 变换）
- Phase 5 Gate 的 parity test **必须包含所有 Tier 3 contract test 在 fusion=on / fusion=off 两状态下全绿**；任一退化都要修好才过 gate
- 上游 filter 的契约（halo-free / Zone targeting / ...）本质上是 "F 的输出对原图呈现什么关系"，P.sink 后 F 的输出变了 → 用户感知到的 "HS 效果 + Saturation 效果的串联" 在数学上与 fusion off 时一致（两者都是 `saturate(HS(I))`），所以契约应**仍成立**。Parity test 守护。

### §5.6 Pass 6 — ResolutionFolding

等分辨率/format 的连续 intermediate，lifetime 分析后标记 "可 alias" —— Layer 5 allocator 基于此标记分配物理 texture。

---

## §6 Backend Codegen（Layer 3）

### §6.1 ComputeBackend — 唯一 production 路径（除 TBDR 和 NativeBackend 内部情况外）

输入：Node（`fusedPixelLocalCluster` / 单 `pixelLocal` / `neighborRead` / `multiPassTerminal`）。

输出：生成的 Metal source + PSO，执行时 encode dispatch。

算法：
1. 搜集参与 filter 的 body + uniform struct + 依赖的 helpers
2. 按依赖去重注入 sRGB / OKLab / 等 shared helper
3. 从每个 filter 的 `.metal` 文件按 `// @dcr:body-begin` / `// @dcr:body-end` marker 抽 body 文本（Swift 侧新 `ShaderSourceExtractor`）
4. 拼接完整 Metal source（上文 §4.2 示例）
5. `device.makeLibrary(source: options: nil)` 编译
6. `device.makeComputePipelineState(function:)` 生成 PSO
7. 按 signature 缓存（§8）

Texture 绑定：output=0, source=1, additional inputs 按出现顺序从 2 起。
Uniform 绑定：每个 filter 自己的 `buffer(N)`，全走 `setBytes`（< 64 bytes/filter，DCR 所有 filter 都满足；cluster 最大 20 个 filter 远低于 Metal 31 slot 上限）。

### §6.2 TBDRBackend — fragment shader + memoryless（Phase 7）

Phase 7 上线。仅对连续 ≥ 3 个 `pixelLocal` 的 cluster 启用（短 cluster compute 路径已经足够快）。

算法：
1. 用同样的 body + uniform struct 生成 `vertex + fragment` shader
2. 创建 `MTLRenderPassDescriptor`，若 cluster 中间级的下游仅在同一 render pass 内，attachment storage mode 设 `.memoryless`
3. cluster 末尾 attachment 根据下游决定：下游是 drawable / render attachment → 可继续 render path；下游是 compute 读 → 本 cluster 末尾物理化

### §6.3 NativeBackend — 不可 fuse 的 Node 走自有 dispatch

处理：`reduce`（ImageStatistics mean）/ `downsample` / `upsample`（非 fused）/ MPS-backed 操作。复用现有 `ComputeDispatcher` / `MPSDispatcher`，但现在作为 compiler 调度层的 backend 之一，而非用户代码直达入口。

与 ComputeBackend 的区别：NativeBackend 使用已有的 `DCRGuidedDownsampleLuma` 等 kernel（这些 kernel 没有 body function 的 "可 fuse" 形态 —— 它们是多 input 多 output / 多 pass graph 内部的 infra，不适合 vertical fusion）。这些 production kernel **不走 legacy kernel 迁移**，它们始终存在于 production bundle。

### §6.4 Warm-up API（Q2 = SDK 提供）

```swift
/// Compile uber-kernel PSOs for the given filter combinations ahead of
/// first use. Typical call site: app launch (after first frame is drawn).
public enum PipelineCompilerWarmUp {
    public static func preheat(
        combinations: [[AnyFilter]],
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float
    ) async throws
}
```

内部：对每个组合走 Layer 1-3，生成 PSO，存入 cache，但不执行。Runtime 再用同组合就是纯 cache hit。

Consumer usage pattern（文档示例）：

```swift
// In your AppDelegate or scene-launch hook, after first frame:
Task.detached(priority: .utility) {
    try? await PipelineCompilerWarmUp.preheat(combinations: [
        [.single(ExposureFilter()), .single(ContrastFilter()), .single(SaturationFilter())],
        [.single(LUT3DFilter(...)), .single(FilmGrainFilter())],
        // ... your app's common filter combinations
    ])
}
```

每个 uber kernel 首次编译 ~100-200ms。4 个典型组合预热 ~600-800ms，后台线程执行。

---

## §7 Resource Allocator（Layer 5）

### §7.1 Lifetime analysis

IR 建好后跑一次：每个 Node 的输出 texture 从 Node.id 开始 live，到最后一个读它的 Node.id 结束。

### §7.2 Aliasing

同分辨率/format/usage、lifetime 不重叠的 Node 共享一个物理 MTLTexture。实现：

- 新 `LifetimeAwareTextureAllocator` 类，接口接近 `TexturePool` 但带 `allocate(for: Node, lifetime: Range<NodeID>)`
- 内部贪心算法：按 lifetime 起点排序，每次优先从"已分配但 lifetime 已结束"的 texture 里挑能 reuse 的；否则 fallback 到 `TexturePool.dequeue`
- 覆盖测试（Phase 4）：构造合成 IR with 已知 lifetime → allocator 产出 texture 数 = 图论下界

### §7.3 与现有 `TexturePool` 的关系

`TexturePool` 不废弃，作为 `LifetimeAwareTextureAllocator` 的后端存储层。pool 提供物理 texture 复用；allocator 提供**同一 graph 执行期间的 texture 共享**（更细粒度）。

### §7.4 Memoryless (Phase 7)

Allocator 识别 "cluster 内部 intermediate 且 consumer 是同一 render pass" 时，给那个 intermediate 标 `.storageMode = .memoryless`。这种 texture 没有 device memory backing，物理上是 tile memory。

---

## §8 PSO Cache 扩展

现 `PipelineStateCache.computePipelineState(forKernel: String)` 按 kernel name 查。uber kernel 的 "name" 是生成的 signature hash（例：`DCR_Uber_{fnv1a_hex}`）。

扩展：
- Cache key 类型 `ComputeCacheKey` = `.builtin(name: String) | .uberKernel(signature: UberKernelSignature)`
- `UberKernelSignature` 包含：filter body ref 序列、uniform layout 序列、color space flag、target pixel format、tail-sink marker
- 不含 uniform 数值—— value 不影响 PSO，只影响 bind（setBytes 每次重做）
- 签名纯函数稳定（FNV-1a over 确定性字节序列），跨进程可缓存

---

## §9 Public API 影响

| 新增 | 位置 | 可见性 | 备注 |
|---|---|---|---|
| `FilterProtocol.fusionBody: FusionBodyDescriptor`（**非 optional**） | `Core/FilterProtocol.swift` | public | 方案 B 下必选；第三方 filter 作者必须提供 |
| `FusionBodyDescriptor` struct | `Core/FilterProtocol.swift` | public | |
| `FusionNodeKind` enum | `Core/FilterProtocol.swift` | public | |
| `Pipeline.optimization: PipelineOptimization`（默认 `.full`） | `Pipelines/Pipeline.swift` | public | |
| `PipelineOptimization` enum (`.full / .none`) | `Pipelines/Pipeline.swift` | public | `.none` = 不做 fusion（每 filter 单 Node cluster 独立 codegen），**不回退**到 pre-compiler 路径 |
| `PipelineCompilerWarmUp.preheat(combinations:)` | `Pipelines/PipelineCompilerWarmUp.swift`（新建） | public | |

**所有 IR / Node / Optimizer / Backend 类型严格 internal**。

**既有 public API 的 breaking 变化**（Phase 5 上线时登记 `CHANGELOG.md [Unreleased]`）：
- `FilterProtocol.fusionBody` 新增为**必须实现**的 member——凡是自写 FilterProtocol 实现的 consumer 需要提供该 property。SDK 内置 16 filter 全部实装（Phase 3 完成）。为降低冲击，同时提供一个 `.unsupported` sentinel 默认值：

```swift
extension FilterProtocol {
    public var fusionBody: FusionBodyDescriptor { .unsupported }
}
```

`.unsupported` 的 filter 走 ComputeBackend 的 "opaque" 分支 —— 这要求 consumer 自己提供一个包含自定义 kernel 的 `.metal`（通过 `ShaderLibrary.register(...)`）。若 consumer 也没 register，pipeline 抛 `PipelineError.filter(.noFusionBody(...))`。这确保老代码默认不崩，但使用 SDK 内置 filter 的 consumer 零感知。

---

## §10 Testing Strategy

继承 `.claude/rules/testing.md` §1 五类断言 + §2.2 三路对比。

### §10.1 Phase 1 — Lowering + Legacy kernel 迁移

- 16 个 filter 的 `.metal` 迁移至 `Tests/DCRenderKitTests/LegacyKernels/`，kernel 名加 `Legacy` 前缀
- `LegacyKernelAvailabilityTests`：确认 16 个 legacy kernel 在 test bundle 的 Metal library 里可被 `ShaderLibrary.function(named:)` 找到
- `LoweringTests`：16 filter 单链 + 3 multi-pass + 1 八-filter realistic chain，每个 lower → 打印的 IR 满足不变量 + 与人工期望 fixture 相符

### §10.2 Phase 2 — 每 Optimizer pass 单测

每个 pass ≥ 5 个 test case：基本功能、空 graph、单 Node graph、不适用条件、与前序 pass 组合。

Pass 5 TailSink 额外：HS/Clarity/SoftGlow 各一个 case 验证 sink 进 multi-pass final pass 后 IR 结构符合预期。

### §10.3 Phase 3 — Codegen + Legacy parity（方案 B 的关键门槛）

- 每个 pixel-local filter × 代表性 slider（-100 / -50 / 0 / +50 / +100）× 2 color space → `runLegacyKernel(filter, input)` vs `runUberKernel(filter, input)` bit-equal（margin 0.005 per channel）
- OKLab 依赖 filter（Saturation / Vibrance）额外：helper 注入正确性（source 里只出现一次）
- 2/3/5-filter 组合的 uber kernel：与 "逐个跑 legacy kernel 串起来" 的结果 bit-equal（margin 0.005 per channel per stage → 累计 < 0.025 严格匹配）
- PSO cache：同 signature 两次 gen 只编译一次

### §10.4 Phase 4 — Allocator 单测

- 合成 IR with 已知 lifetime → allocator 产出 texture 数 = 图论下界（染色数）
- Aliasing 正确性：共享 texture 的两个 Node lifetime 编译期可证严格不交
- 与 deferred enqueue 兼容：最终 output texture 不被回收到 pool

### §10.5 Phase 5 — 集成 + benchmark gate（user gate）

- 全 filter × 全 slider sweep regression（`LinearPerceptualParityTests` 的 fusion 版本）
- 全 Tier 3 contract test 在 fusion=on / fusion=off 两种状态下全绿（激进 tail sink 不退化 Tier 3）
- 全 Tier 4 snapshot test 维持（framework 已备）
- `PipelineBenchmark.measureChainTime` 跑 4 个典型组合，fusion on vs off 对比
- 真机 benchmark：user iPhone 14 Pro Max 跑 user 提供的典型 chain，CPU% / memory peak before/after 报表

### §10.6 Phase 6 — Compute/Fragment parity

每个 pixel-local filter：compute body vs fragment body 同输入同 uniform 的 pixel-by-pixel 等价（Float16 margin ≤ 0.005）。

### §10.7 Phase 7 — TBDR smoke + 终验（user gate）

- 逐 filter 组合在 TBDR path 上跑通
- 与 compute uber kernel 输出 parity
- 真机终验：长链 preview CPU / memory / bandwidth

### §10.8 Smoke test（交付前全覆盖）

新文件 `Tests/DCRenderKitTests/PipelineCompilerSmokeTests.swift`：

1. 单 filter 链 fusion=on/off 等价 × 16 filter
2. 典型多 filter 组合 × 4 种，fusion=on/off 等价
3. multi-pass + pixel-local 混合链 fusion=on/off 等价（激进 tail sink 主战场）
4. 空 pipeline、identity filter 链 short-circuit
5. Warm-up 列表正确生效（PSO cache 首次 hit）
6. Legacy kernel parity 全覆盖 sentinel（Phase 3 门槛的 smoke 重测）

### §10.9 Legacy kernel 删除前的终验 gate

Phase 7 结束后，user 在 main 稳定观察 ≥ 1 周 + 真机确认，我方提交 "remove legacy kernels" commit。此 commit 仅删 `Tests/DCRenderKitTests/LegacyKernels/` 和相关 parity test；其余 smoke / snapshot / contract test 保持 —— 它们依赖的是 "fusion on vs off 内部一致" 而非 legacy kernel。

---

## §11 每 Phase 验收清单

每 phase 结束要过以下门槛，否则不进下一个（继承 `.claude/rules/commit-verification.md`）：

| Phase | `swift build` 零 warning | `swift test` 全绿 | 新增 test count | 文档同步 | User gate |
|---|---|---|---|---|---|
| 0 | N/A | N/A | 0 | 本文档 | ✅ signed off |
| 1 | ✅ | ✅ | +25 (lowering + legacy migrate) | IR 类型 SwiftDoc | — |
| 2 | ✅ | ✅ | +35 (optimizer) | 每 pass SwiftDoc + 示例 | — |
| 3 | ✅ | ✅ | +30 (codegen + 16 filter legacy parity) | 生成 Metal source 示例 + body marker convention | — |
| 4 | ✅ | ✅ | +15 (allocator) | 算法注释 | — |
| 5 | ✅ | ✅ | +1 smoke file (≥10 tests) | CHANGELOG + arch doc §4.14 | ✅ **benchmark** |
| 6 | ✅ | ✅ | +10 parity × 9 filter | 每 filter fragment body SwiftDoc | — |
| 7 | ✅ | ✅ | +8 TBDR smoke | arch doc TBDR 说明 | ✅ **终验** |
| Post-7 | ✅ | ✅ | −16 (legacy removed) | cleanup commit | ✅ "legacy remove" sign-off |

**每 commit**（不只每 phase）走 `.claude/rules/commit-verification.md` — `swift build` + `swift test` 无豁免。

---

## §12 工程量 & 节奏（Q3 + B 更新后）

| Phase | 工作内容 | 日历天 |
|---|---|---|
| 0 | 本稿 + review + sign-off | done |
| 1 | IR 类型 + Lowering + legacy kernel 迁移 + 25 test | 2-3 |
| 2 | 6 optimizer passes (含激进 tail sink) + 35 test | 5-6 |
| 3 | ComputeBackend codegen + body 抽取器 + PSO cache 扩展 + 16 filter legacy parity | 5-6 |
| 4 | LifetimeAwareTextureAllocator + 15 test + scheduling | 2-3 |
| 5 | 接通 Pipeline + fusion on/off smoke + 真机 benchmark | 3-4 |
| 6 | 9 个 pixel-local filter 的 fragment body + parity | 4 |
| 7 | TBDRBackend + memoryless + 终验 | 4-5 |
| Post-7 | Legacy kernel 删除 commit | 0.5 |
| **合计** | | **~26-32 工作日 / 5.5-6.5 周**（含 CR overhead） |

---

## §13 风险与 Mitigation

| 风险 | 影响 | Mitigation |
|---|---|---|
| runtime Metal 编译失败（拼接 source 语法错） | uber kernel 不可用 | 每 combination 单测覆盖；失败时 **不 silent fallback**（方案 B 无退路）——抛 `PipelineError.pipelineState(.uberKernelCompilationFailed)`，消费端收到明确错误 |
| shader body marker 抽取脆弱（.metal 格式漂移） | codegen 读不到 body | marker 语法严格规范；`ShaderSourceExtractor` 单测覆盖（给样本 .metal 验抽取正确性）；CI lint 可选加（验所有 body function 有 marker 包裹） |
| 激进 tail sink 退化 Tier 3 契约 | HS/Clarity/SoftGlow 表现变差 | Phase 5 gate 包括**全 Tier 3 contract test 在 fusion=on 下全绿**；任一 contract 失败 → tail sink 在该 filter 上自动禁用（per-filter `allowsTailSink = false` 声明），而非全局禁用 |
| uniform slot 爆炸（Metal 限 31 个 buffer slot） | long chain 编不过 | fusion cluster 长度 hard cap = 20；超过切段成多个 sub-cluster |
| Float16 累计误差 | fusion 后 body 之间不经过 rgba16Float 中转 | 实际上 fusion 后精度 **更高**（中间值在 register，不经 texture write/read 截断）；parity 测试保底 |
| TBDR 路径导致 drawable pixel format 不兼容 | 预览黑屏 | Phase 7 先仅对 intermediate 用 memoryless；drawable 仍走 compute 最后一步写出 + MPS lanczos |
| **方案 B 无 standalone kernel fallback** | Production bug 无处退路 | 1) Phase 1-7 期间 legacy kernel 在 test target 作 parity gate；2) Phase 7 终验 ≥ 1 周稳定 + user sign-off 才删 legacy；3) `Pipeline.optimization = .none` 作为 "最小化 compiler 行为"（仍走 codegen 但每 filter 1 个 Node）供 debug 用 |
| 第三方 filter 因 `fusionBody` 非 optional 而编译失败 | 老代码迁移阻力 | 提供 `.unsupported` sentinel + 默认实现（§9 末尾），老代码零改动编过；真要运行时 resolve，抛明确 `noFusionBody` 错误 |

---

## §14 Open Questions —— 已全部解决

1. ~~方案 A vs B~~ → **B**（signed off）
2. ~~Warm-up 归属~~ → **SDK 提供**（`PipelineCompilerWarmUp.preheat`）
3. ~~Tail sink 保守 vs 激进~~ → **激进**（multi-pass final 吸收下游 pixelLocal body）
4. ~~Public API 新增清单~~ → **按 §9 的 6 条 additive 通过**

---

## §15 附录 — 受影响文件清单

### 新增（internal）
- `Sources/DCRenderKit/Core/PipelineGraph/Node.swift`
- `Sources/DCRenderKit/Core/PipelineGraph/PipelineGraph.swift`
- `Sources/DCRenderKit/Core/PipelineGraph/Lowering.swift`
- `Sources/DCRenderKit/Core/PipelineGraph/OptimizerPass.swift` + 6 个 pass 文件
- `Sources/DCRenderKit/Core/PipelineGraph/SignatureHash.swift`
- `Sources/DCRenderKit/Core/PipelineGraph/ShaderSourceExtractor.swift`
- `Sources/DCRenderKit/Dispatchers/ComputeBackend.swift`
- `Sources/DCRenderKit/Dispatchers/TBDRBackend.swift`（Phase 7）
- `Sources/DCRenderKit/Dispatchers/NativeBackend.swift`
- `Sources/DCRenderKit/Resources/LifetimeAwareTextureAllocator.swift`
- `Sources/DCRenderKit/Pipelines/PipelineCompilerWarmUp.swift`

### 新增（public — §9 列的）

`FusionBodyDescriptor` / `FusionNodeKind` / `PipelineOptimization` / `FilterProtocol.fusionBody` / `Pipeline.optimization` / `PipelineCompilerWarmUp`。

### 修改（production）
- 16 个 `.metal` 文件：**删除 production kernel，规范化 body function**（加 `// @dcr:body-begin/end` marker），保留 uniform struct 和 helpers
- 16 个 Filter Swift 文件：实现 `fusionBody` property
- `Pipelines/Pipeline.swift`：接通 compiler 路径，`optimization` 开关
- `Pipelines/FilterGraphOptimizer.swift`：废弃 (0.2.0 内部走新 compiler，保留空实现作 deprecation shim，0.3.0 删)
- `Resources/PipelineStateCache.swift`：`ComputeCacheKey` schema 扩展
- `Shaders/Foundation/SRGBGamma.metal` / `OKLab.metal`：helper 注入的 canonical source

### 新增（tests — Phase 1-7 期间保留）
- `Tests/DCRenderKitTests/LegacyKernels/*.metal`（16 个 filter 的原 kernel 逐字迁移，前缀 `DCRLegacy...`）
- `Tests/DCRenderKitTests/PipelineCompiler/LegacyKernelAvailabilityTests.swift`
- `Tests/DCRenderKitTests/PipelineCompiler/LoweringTests.swift`
- `Tests/DCRenderKitTests/PipelineCompiler/OptimizerTests.swift`（每 pass 独立 file 或 split）
- `Tests/DCRenderKitTests/PipelineCompiler/ComputeBackendTests.swift`
- `Tests/DCRenderKitTests/PipelineCompiler/LegacyParityTests.swift`（Phase 3 核心 gate）
- `Tests/DCRenderKitTests/PipelineCompiler/LifetimeAwareAllocatorTests.swift`
- `Tests/DCRenderKitTests/PipelineCompiler/PipelineCompilerIntegrationTests.swift`
- `Tests/DCRenderKitTests/PipelineCompilerSmokeTests.swift`
- `Tests/DCRenderKitTests/PipelineCompiler/FragmentBodyParityTests.swift`（Phase 6）
- `Tests/DCRenderKitTests/PipelineCompiler/TBDRBackendTests.swift`（Phase 7）

### 删除（Post-Phase-7 final cleanup commit）
- `Tests/DCRenderKitTests/LegacyKernels/*.metal` × 16
- `LegacyKernelAvailabilityTests.swift`
- `LegacyParityTests.swift`

### 文档更新
- `docs/architecture.md` 新增 §4.14 "Pipeline Compiler"（Phase 5）
- `docs/custom-filter-authoring.md` 新建（Phase 3）—— 说明第三方 filter 作者如何实现 `fusionBody` + body marker 约定
- `CHANGELOG.md [Unreleased]` 登记新增 public API + `FilterProtocol` member additive change（Phase 5）
- `README.md` Performance 一节新增 fusion / TBDR 段（Phase 7）
- `docs/pipeline-compiler-design.md`（本稿）—— Phase 实施中持续更新决策变更
