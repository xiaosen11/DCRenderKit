# CLAUDE.md

DCRenderKit — 商用级 Metal 图像处理 SDK（iOS 15+/macOS 12+）。独立开源项目，零外部依赖。

## 项目定位

这是一个**开源 SDK**，不是 App。最终形态必须满足：

1. 可作为独立 SPM package 被任何 iOS/macOS 项目集成
2. 零外部依赖（只依赖系统 framework：Metal/MetalKit/CoreImage 可选/Vision 可选）
3. Public API 一旦冻结即有 SemVer 契约，不允许"先暴露再改"
4. 面向全球开源社区，README 中英双语，文档 DocC 可生成

## 关联决策文档

**开始任何工作前必读**：

| 文档 | 路径 | 作用 |
|------|------|------|
| **架构设计** | `../wayshot-pm-agent/Digi-Cam/docs/harbeth-architecture-audit.md` | 引擎架构完整决策（Harbeth 审计 + 自建方案） |
| **实施计划** | `../wayshot-pm-agent/Digi-Cam/docs/metal-engine-plan.md` | Phase 1-3 任务分解（V2 收敛版） |
| **Phase 1 进度** | `../wayshot-pm-agent/Digi-Cam/docs/phase1-progress.md` | 每个 Round 完成的关键决策记录 |

> 这些文档暂住在原 Digi-Cam 项目里，Phase 3 时可能迁入 DCRenderKit/docs/。

## 交互规范

- **必须使用简体中文**回复、commit message、PR 描述
- 代码注释和 SwiftDoc 用**英文**（面向国际社区）
- 错误信息 / 文档正文 / README 可中英双语

## 🔴 商用级质量红线（硬性要求）

**从第一个 commit 就按可发布质量写代码，不存在"先做 MVP 再完善"的阶段**。

| 维度 | 硬性要求 |
|------|---------|
| **正确性** | 边界情况必须处理（空输入、零参数、极值、NaN、负数、超大分辨率）。不允许 `TODO: 处理 edge case` |
| **稳定性** | 零 crash、零 leak。所有资源必须正确释放，async 操作必须可取消 |
| **API 稳定性** | Public API 暴露即有契约，内部细节用 `internal` 严格隐藏 |
| **文档** | 所有 `public` 符号必须有 SwiftDoc（参数 / 返回值 / 异常 / 示例） |
| **错误处理** | 必须抛出具体类型的 error（禁止 `throw NSError`、禁止 `fatalError` 用于可恢复错误） |
| **代码审查** | 无 `TODO` / `FIXME` / `HACK` 注释留到 merge（必须 resolved 或开 issue 追踪） |
| **命名** | 遵循 Swift API Design Guidelines |
| **无依赖污染** | `Package.swift` 的 `dependencies` 必须为空数组 |

每个 sub-phase 结束时 checklist：
- [ ] 所有新增 public API 有 SwiftDoc
- [ ] `swift build` 零 warning
- [ ] `swift test` 全绿
- [ ] 零 TODO/FIXME
- [ ] 边界情况已覆盖（测试或文档化）

不满足任一条 = sub-phase 不通过，不进入下一个。

## 🔴 Metal Shader 约束

YOU MUST follow these rules when writing or modifying Metal shaders:

### 禁止贪心降级
不得以"先让它能跑"为由降低效果质量。效果不对就不提交，不存在"先看看行不行"。

### 参数必须验算
写任何像素级参数前，必须回答以下三个问题并在注释中写明：
1. 这个值在 1080p 和 4K 下分别是多少像素？
2. 这个像素数在视觉上意味着什么？（占画面百分之几？覆盖多大区域？）
3. 这个值是否应该跟图像尺寸成比例？如果是，必须用 `textureWidth/Height` 动态计算，禁止写死常量

### Typed uniform buffer 对齐
DCRenderKit 用 `FilterUniforms` 绑定 typed 结构体到 `buffer(0)`。Shader 必须用：
```metal
kernel void MyKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant MyUniforms& u [[buffer(0)]],  // ← typed struct，不是散列 float
    uint2 gid [[thread_position_in_grid]])
```

结构体的 Swift 和 Metal 内存布局必须一致（手动对齐 stride 和 alignment）。

### Computed property 无副作用
`uniforms`、`passes(input:)` 等每帧求值的 property 里禁止 `random()`、`Date()`、`UUID()` 等每次结果不同的表达式。实时预览每帧重建 filter，不稳定的值会导致闪烁。

### Bounds check 强制
所有 compute kernel 入口必须有：
```metal
if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
```

漏掉这行在非 2^n 分辨率上会读越界。

## 🔴 Filter 开发规则

写任何新 filter 前必须先走 `.claude/rules/filter-development.md` 的 4 步流程：

1. **维度分类**（1D 逐像素 / 2D 邻域 / 多尺度）
2. **列 ≥2 个原理派算法候选**（不能是纯经验公式）
3. **WebSearch 至少 1 个业界参考**（论文 / 开源 / 官方）
4. **Doc comment 必须写模型形式理由**：
   ```swift
   /// Model form justification:
   ///   - Type: [classification]
   ///   - Algorithm: [name + reference]
   ///   - Alternative: [why not X]
   ```

**红旗信号**：如果理由写"因为 MSE 最低"、"试出来效果最好" → 必须重新回到第 2 步。

像素级拟合（`pixel-fitting` skill）是**验证工具**，不是**选型工具**。详见 `.claude/rules/filter-development.md`。

## 🔴 空间参数适配规则

写空间参数（像素距离、偏移、大小）前必须先走 `.claude/rules/spatial-params.md`：

1. 这个参数是像素距离/偏移/大小吗？不是 → 逐像素，不适配
2. 用户感知的是"屏幕纹理"还是"图像处理"？
   - 屏幕纹理（颗粒/锐化/噪点）→ `basePt × pixelsPerPoint`
   - 图像处理（模糊/色差）→ 按纹理维度比例
3. 参数通道开了吗？视觉纹理参数必须从 Swift 传入 buffer，不能在 shader 里写死常量

## 编码约束

- **Swift tools version**: 5.9
- **最低部署**: iOS 15.0 / macOS 12.0
- **Sendable 全覆盖**: async/await 并发安全基础
- **async/await**: 所有异步 API 用原生语法，禁止 completion handler（`@escaping closure`）
- **trailing comma**: 强制使用（多行参数列表）
- **let 优先**: 能用 `let` 就不用 `var`
- **日志**: 统一用 `DCRLogging.logger`，禁止 `print`/`NSLog`/`os_log` 直接调用
- **断言**: 用 `Invariant.require/check/unreachable`，禁止 `assert()` 直接调用
- **单文件行数**: ≤500 行（多 pass filter 可放宽到 800）
- **单方法行数**: ≤80 行

## 测试规范

每个 filter 必须有：
- **Identity 测试** — 零参数等于原图
- **极值测试** — ±100 或最大范围不崩溃、不 NaN
- **Reference 测试**（Phase 3）— 与 Lightroom/参考实现对比 pixel MSE

每个核心类（Pipeline、TexturePool、Dispatcher）必须有 smoke test（Round 12 交付，Phase 3 补齐覆盖率）。

## Git 规范

Commit message 格式：
```
<type>(<scope>): <中文描述>
```

类型：`feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `perf` / `style`
Scope 示例：`core` / `dispatcher` / `filter` / `pipeline` / `ci`

示例：
```
feat(dispatcher): 新增 ComputeDispatcher 支持 typed uniform buffer

- PSO 缓存集成
- threadgroup 大小自适应
- typed buffer 零分配绑定

Co-Authored-By: Claude <noreply@anthropic.com>
```

分支策略：
- `main` → 稳定分支（只接受 merge，不直接 push）
- `feat/*` / `fix/*` / `docs/*` → 功能分支

**禁止**：直接 push main、强制 push 任何分支、amend 已 push 的 commit。

## 开源项目特有约束

- **所有面向社区的文档用英文**（README、CONTRIBUTING、CODE_OF_CONDUCT）
- **提交注释中的 issue/PR 引用用完整 URL**（国际贡献者友好）
- **不提交任何公司/项目专有信息**（业务 ID、Paper 设计、内部 URL 等）
- **Release tag 严格 SemVer**（v0.1.0 / v1.0.0-rc.1 / v1.2.3）
- **CHANGELOG.md** 每次 release 更新

## 开发后验收

每个 Round 完成时：
1. 对照本轮任务清单逐项验证
2. 跑 `swift build`（零 warning）
3. 跑 `swift test`（全绿）
4. 检查零 TODO/FIXME/HACK
5. 更新 `../wayshot-pm-agent/Digi-Cam/docs/phase1-progress.md` 记录关键决策
6. 更新 TaskList 状态

## 关联 Skills

虽然 skills 原定义在 Digi-Cam/.claude/skills/，以下几个在 DCRenderKit 上下文中依然适用：

| Skill | 适用场景 |
|-------|---------|
| `diff` | 分支对比 |
| `pixel-fitting` | Round 10/11/Phase 2 滤镜输出数值验证 |
| `review` | 每个 Round 结束的代码审查 |
| `debug` | 调试 Metal shader 和管线问题 |

**不适用的 skills**（Flutter/Riverpod/业务专用，忽略）：
- `design-to-code`（Paper → Flutter）
- `architecture`（四层分层 app → features → shared → core）
- `state-management`（Riverpod）
- `a11y`（Flutter 无障碍）
- `perf`（Flutter 性能分析）
- `native-ios`（原 Harbeth 相关，多数已废弃；Swift/Metal 部分并入本 CLAUDE.md）
- `ci-cd`（项目 CI；DCRenderKit 用独立 CI）

---

**核心哲学**：这是一个会被很多项目依赖的开源 SDK。每一行代码都有长期维护义务，不能留坑。商用级标准是最低要求，不是最高目标。
