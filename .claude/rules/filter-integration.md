---
description: 新 filter 接入框架的性能和正确性规则。算法选型由 filter-development.md 覆盖；本规则聚焦于"如何丝滑融入 pipeline 而不造成性能劣化"
globs:
  - "**/Filters/**/*.swift"
  - "**/Filters/**/*.metal"
---

# Filter 框架集成规则

## 核心问题：NodeKind 选错 = 性能劣化无法恢复

DCRenderKit 的 VerticalFusion optimizer 自动把相邻的 `pixelLocal` 节点合并成一个
fragment cluster pass（零额外 GPU encoder overhead）。选错 NodeKind 会截断 fusion，
每多一个 pass 多 ~300 µs CPU encoder 开销 + 一次 texture round-trip。

## §1 NodeKind 选择规则（写 shader 前必须回答）

| NodeKind | 能读什么 | Fusion | 何时用 |
|----------|---------|--------|--------|
| `pixelLocal` | 仅当前 (x, y) 像素 | ✅ 自动融合 | 纯逐像素色彩/色调运算 |
| `neighborRead` | 任意邻域像素 | ❌ 截断 fusion | 需要邻居像素（锐化、模糊、边缘检测） |
| `nativeCompute` | 任意纹素，任意 dispatch | ❌ 截断 fusion | 复杂算法（pyramid、guided filter） |
| `multiPass` | DAG 内部纹理依赖 | N/A — MultiPassFilter 管 | 多 pass，内部有纹理传递 |

**判断方式**：如果 shader 只 `read(gid)` 不做任何邻域采样 → 必须是 `pixelLocal`，不允许
降级到 `nativeCompute`（"能跑就行"的降级是禁止的，见 CLAUDE.md 红线）。

## §2 Fusion 截断的四个硬条件

以下任一条件满足时，该节点**不可能**与前后节点融合，这是不可改变的架构约束，
不是 bug，不要尝试绕过：

1. **NodeKind 是 `neighborRead` / `nativeCompute`** — compute dispatch 无法进 fragment cluster
2. **节点有 fan-out（多个下游消费者）** — 中间值必须保持可观测，不能内联
3. **输出分辨率与输入不同** — 需要新纹素，无法合并到当前 cluster
4. **pass 设置了 `final = true`** — 标记为终态管理步骤，下游不能 fuse 进来

写新 filter 时如果发现必须用 `neighborRead`/`nativeCompute`，接受这个代价，不要改成
`pixelLocal` 然后试图用 workaround 读邻居（这会产生错误结果）。

## §3 Uniform struct 设计规则

1. **用 `Float` 不用 `Double`** — Metal buffer 不支持 double，混用会 corrupt 内存布局
2. **显式 padding 对齐** — `float4` 成员需要 16-byte 对齐，用 `var _pad: Float = 0` 显式填充
3. **struct 控制在 64 bytes 以内** — 所有 bytes 每帧都会被 hash 作为 fingerprint
4. **`uniforms` computed property 里禁止非确定性值** — `random()` / `Date()` / `UUID()` 放 `init` 里作为 `let` 常量；放 computed property 里会每帧重建时产生不同值 → 预览闪烁

## §4 纹理别名安全规则

`TextureAliasingPlanner` 可能把你的输出纹理分配到一个会被后续 pass 复用的 slot。
filter 作者必须遵守：

- **不能**在 pass 结束后持有中间纹理的强引用（它可能被下一帧的另一个 pass 覆写）
- **不能**在 pass 完成后继续读 `Pass.input` 纹理（aliasing planner 认为该纹理的生命周期已结束）
- `MultiPassFilter` 内部通过 `PassInput.additional(_:)` 传递的纹理是调用方管理的，不参与 aliasing，是安全的

## §5 空间参数接入

写任何像素距离参数前，先走 `spatial-params.md` 的判断流程：
- 视觉纹理（颗粒/锐化边缘）→ `basePt × pixelsPerPoint`，必须从 Swift 注入
- 图像结构（模糊半径/色差偏移）→ `shortSide × ratio` 或 `quarterW × ratio`
- 纯色彩/色调 → 不适配

**禁止**：在 Metal shader 里写死像素常量（`const float grainSize = 3.0`）。

## §6 当前框架性能边界（必须了解，不要盲目优化）

以下代价**不可消除**，不要试图"用 hack 绕开"：

| 代价 | 为什么不可消除 |
|------|--------------|
| 每个非融合 dispatch ~300 µs CPU | Metal encoder setup 是固定成本 |
| GPU shader 执行时间 | 这就是 filter 的实际算力成本 |
| 每个 `neighborRead`/`nativeCompute` 一次完整 dispatch | 无法 fuse |
| 第一帧 O(N compile) | 缓存后恢复，但首帧必须付 |

**14 filters + 4 multi-pass ≈ 29 dispatches ≈ 5-10 ms CPU encode = 正常**。

新增一个 `pixelLocal` filter 如果能融合 → 边际成本 ≈ 0。
新增一个 `neighborRead`/`nativeCompute` → +~300 µs CPU + 一次 texture round-trip。
这是设计决策，不是问题，在 PR 里用数据写清楚。

## §7 接入新特效的完整 checklist（commit 前逐项验证）

算法层：
- [ ] 按 `filter-development.md` 完成维度分类 + ≥2 原理派候选 + 业界参考
- [ ] doc comment 写了模型形式理由（类型 + 算法 + 为什么不用替代方案）

框架层：
- [ ] NodeKind 是能满足需求的最弱选择（能 `pixelLocal` 就不用 `nativeCompute`）
- [ ] Uniform struct 用 `Float`，有显式 padding，无非确定性值，≤ 64 bytes
- [ ] Metal kernel 有 bounds check（`if gid.x >= width || gid.y >= height return;`）
- [ ] 空间参数按 `spatial-params.md` 适配（无硬编码像素常量）

测试层：
- [ ] Identity / 极值 / 方向性 / 数值 / 契约 五类测试覆盖
- [ ] `bgra8Unorm` 和 `rgba16Float` 两种 source 格式都有测试
- [ ] `swift build` 零 warning，`swift test` 全绿

代码质量：
- [ ] 所有 public 符号有 SwiftDoc
- [ ] 零 TODO / FIXME / HACK

## 为什么这套规则存在

Stream B（VerticalFusion + TextureAliasingPlanner + CompiledChainCache）是在
Phase 6–11 经过反复迭代才达到的架构状态。它能自动做的事情（fusion、aliasing、
cache）filter 作者不需要手动干预；但它**无法**帮你修正 NodeKind 选错、uniform
非确定性、或者空间参数硬编码——这些都是 filter 作者的责任。

详细背景见：
- `docs/filter-development.md` — 完整开发指南（算法 + 框架 + 测试）
- `docs/architecture.md §4.14–4.16` — Cache / Phase 11 / Frame Graph 详细设计
