# DCRenderKit — Pending Work

**权威 todo 源** — repo 根目录显眼处。每 session 结束更新一次。

完整 task 历史（含已完成）在 `~/.claude/tasks/<session-uuid>/*.json`（Claude Code 内部存储）。此文件是**人类可读快照**。

**最后更新**: 2026-04-27（Session E 收敛后，Phase 5 source-tap codegen 落地 / Sat/Vib 黑斑根因修复 / 优化器+dispatcher 防御加固 / 视觉纹理参数重命名 / SDK 输出契约硬约束机制化；558 tests pass，剩余约 8 条主要是真机阻塞项 + release tag）

---

## 已确认完成项（不再列 —— 见 git log 与 CHANGELOG.md `[Unreleased]`）

Session B：Tier 3 五 filter 完整闭环（契约 → impl → 验证 → 算法/参数依据） · §8.1 A.1-A.7 · §8.2 A+.1-A+.5 · §8.3 A++.1-A++.5 · §8.4 Audit.1-7 · B.1-B.4 参数级依据。

Session C：#74 typed Error enum hierarchy · #73 Package.swift 空依赖守护 · Tier 1.3 四 fitted filter 全部替换为原理派（Contrast→DaVinci log-slope / Blacks→Reinhard toe / Whites→Filmic shoulder / Exposure-neg→linear gain） · #75 PortraitBlur two-pass Poisson 架构 · IEC sRGB Foundation helper · LinearPerceptualParityTests · Snapshot regression framework（#36） · PipelineBenchmark（#40） · README / CONTRIBUTING / CODE_OF_CONDUCT / CHANGELOG（#53/#54/#55/#56） · GitHub Actions CI（#60） · Issue/PR templates（#68） · v0.1.0 GA criteria（#64） · macOS 业务层剥离（iOS-only） · Harbeth lineage descriptor 清理。

Session D：#66 PortraitBlur mask routing integration tests（`Tests/DCRenderKitTests/IntegrationTests/`，3 tests synthetic-source / half-split-mask 覆盖 Demo→SDK 路径） · #70 Maintainer SOP + SECURITY.md（`docs/maintainer-sop.md` PR review / release cut / breaking-change 登记 checklist + `SECURITY.md` 漏洞报告 scope / 支持版本 / 响应 SLA） · #69 GitHub Discussions 指南（`docs/discussions-guide.md` — 4 分区 Q&A / Show-and-tell / Ideas / General + 启用 checklist） · Foundation capability baseline（`docs/foundation-capability-baseline.md` — 18 条架构能力 claim + evidence + rationale，分 5 category：依赖/平台、正确性架构、色彩/算法基础、验证门槛、out-of-scope 不保证项） · #72 零 warning 审（修 ResourceManagementTests 非 Sendable self capture / SmokeTests + ColorGradingFilterTests + ToneAdjustmentFilterTests 的 `#file` → `#filePath` 签名对齐 / MultiPassAndLoaderTests unused var；CI 加 `-Xswiftc -warnings-as-errors` 把审计锁成持久 gate） · #71 零 TODO/FIXME 审（2 个 false positive 清理：CCDFilter.metal `FIXME` 引用字样去词 / PackageManifestTests.swift 字符串内 `TODO.md` 改引用形式；所有 19 条 FIXME/TODO 已带 `(§…)` 或 `(#…)` reference，皆指向 findings-and-plan.md 已 archived section，作为 Tier 4 snapshot 锁定前的 accepted empirical tech debt） · #59 SwiftDoc 完整性审（16 filter 的 protocol conformance members + init + PipelineBenchmark.Result 6 properties 全部补 doc，infra types 的 member doc 密度已达标） · #48 internal/fileprivate 严格审（保守降级 `MultiPassExecutor` public → internal — 只有 Pipeline.executeMultiPass 调用，consumer 通过 `.multi(filter)` 间接触达；其他 public types 作 FilterProtocol conformance params / Pipeline injection deps 保留 public） · #49 Public API freeze review（`docs/api-freeze-review.md` — 8 类 public surface 每类 Stable/Evolving/Experimental 分层 + 全量 `[Unreleased]` breaking changes 对账 + deprecation workflow + 0.x 适配承诺） · #47 `@available(iOS 18.0, *)` 覆盖 64 条 public top-level declaration（3 个 PortraitBlurMaskGenerator 内部 `@available(iOS 17.0, *)` 升到 18 匹配 SDK deploy target） · #58 `docs/architecture.md`（13 条关键架构决策各配 choice/rejected/why/origin 四段，补上 layered overview ASCII 图 + 5 条 design principles + data flow，与 foundation-baseline 形成 narrative vs. capability 互补） · #57 DocC catalog（`Sources/DCRenderKit/DCRenderKit.docc/{DCRenderKit,GettingStarted,Architecture}.md` — landing page 全量 topic 分区 + getting-started 集成走查 + architecture TL;DR；CONTRIBUTING 补 local preview 说明；刻意不加 swift-docc-plugin 维持零依赖） · #61 DocC GitHub Pages deploy workflow（CI `docs` job 用 `xcodebuild docbuild` + `docc process-archive transform-for-static-hosting` + `actions/deploy-pages` —仅 main branch） · #62 Release automation workflow（`.github/workflows/release.yml` tag push → swift test 验证 → CHANGELOG section 提取 → `gh release create` 创建 GitHub Release；pre-1.0 / -suffix tag 自动 mark prerelease；maintainer 按 SOP §2 手动 tag 后触发） · #93 CCD 结构性单测补 4 个（CA 隔离 R/B 水平 offset / saturationBoost 对灰度 identity / 噪点 block 量化 / strength mix 线性性） · #94 `PipelineErrorTests.swift` 独立 15 tests（5 domain × 24+ cases 描述覆盖 / pattern-match / Invariant trigger / LUT3DFilter fail path）。

Session E（2026-04-27，commit `fe64d4a`）：

- **Phase 5 source-tap codegen** — `KernelInlining` (head fusion) + `TailSink` (tail fusion) 经过 `Node.tailSinkedBody` / `inlinedBodyBeforeSample` 字段的"silent drop"修复进入正式生产路径。Sharpen / FilmGrain / CCD body 改成 `template <typename Tap>`，codegen 注入 `DCRRawSourceTap` 或 `DCRFusedTap_<P>` 控制 sample 行为。fragment chain 的 `.neighborReadWithSource` 路径同步注入 tap，修复 `testRealisticEditChainProducesInGamutOutput` 的 SIGABRT。配套 `FusionRuntimeParityTests` 用 `.full` vs `.none` 输出差锁住 codegen ↔ binding 的 slot 一致性。`KernelInlining` 加 multi-input precondition + slice rewrite，`TailSink` 加显式 `producer.isFinal == false` 防御对称，`VerticalFusion.canMerge` 加 `canFuseAsPixelLocalMember` 防 LUT3D-LUT3D cluster 编译错误。
- **Sat/Vib 黑斑根因修复**（编辑预览）— Sat / Vib 是 12 个滤镜里**唯一两个没有 `colorSpace` 参数**的，假设输入永远 linear，但 perceptual 模式下源纹理装的是 gamma-encoded bytes，OKLab 在 gamma 上跑产出错误的 L → gamut clamp 收敛到错误的小 L → 黑斑。修法：mirror Exposure / Contrast / WB 模式，加 `colorSpace: DCRColorSpace` 参数 + `isLinearSpace: UInt32` uniform，body 入口先 `max(rgbIn, 0)` (sub-gamut 防御)，perceptual 模式再 `DCRSRGBGammaToLinear`，OKLab 计算后对应分支再 `DCRSRGBLinearToGamma`。**真根因，不是头痛医头**。
- **WhiteBalance 输出契约修复** — perceptual 模式下 YIQ tint 矩阵在 ±200 极值会让输出通道滑到 ≈ -0.17，line 144 直接 `return mixed` 把负值漏给下游 OKLab 消费者。修：`mixed = max(mixed, 0)` 在 return 前。
- **SDK 输出非负契约机制化**（`Tests/DCRenderKitTests/Contracts/SDKFilterOutputContractTests.swift`）— 12 个测试覆盖每个 SDK 滤镜在 5 个代表性 patch × 极端参数下输出非负。新增 filter 必须加 `test<FilterName>AtExtremesIsNonNegative()` 测试方法，规则写进 `.claude/rules/filter-development.md` C.1/C.2/C.3 硬约束（输出非负 + colorSpace 参数 + per-PR 自检 checklist）。
- **优化器 + dispatcher 防御性 cleanup**（亲自全量审计的产物）— `consumerCounts` 4 处 byte-identical 重复提取到 `PipelineGraph.consumerCounts()` 单一来源；`Node.withReplacedRefs(kind:inputs:)` helper 让 CSE / VF / TailSink 的 NodeRef 改写自动保留 `inlinedBodyBeforeSample` / `tailSinkedBody`（消除同类 silent-drop bug）；`FusionBodySignatureShape.canFuseAsPixelLocalMember` computed property 集中 fusion-eligible 判断；`TextureAliasingPlanner` 的 dictionary 边迭代边删（Swift UB）改 snapshot 模式；`ComputeBackend` / `ComputeDispatcher` / `RenderBackend` 的 encoder 用 `defer { endEncoding() }` 模式防 SIGABRT（`RenderBackend.executeChain` 的 3 处 `try` 之前会泄漏 encoder）；`MetalSourceBuilder` 三种 extract artefact 变种合并成 `extractArtefacts` + `extractFusableArtefacts`；`uberFunctionName` 5 参数臃肿改成接受 `FusedClusterMember?`；`CompiledChainCache` fingerprint 加 `body.signatureShape` 防 functionName 碰撞。
- **视觉纹理参数重命名（breaking）** — `SharpenFilter.step` → `stepPixels`、`FilmGrainFilter.grainSize` → `grainSizePixels`、`CCDFilter` 三个空间参数都加 `Pixels` 后缀。Filter 不感知显示上下文（不 import UIKit），消费者继续负责 `basePt × pixelsPerPoint`，但 API 表面让"这是 pixel 不是 pt"在调用点编译期可见，未来消费者（Digicam 迁移到 DCR）不可能漏做 ppt 计算。Demo `FilterChainBuilder.swift` 和所有 test caller 同步更新。

---

## Pending 分类

### 进行中的大型重构：Pipeline Compiler（Phase 5-7 剩余）

**入口文档**：
- `docs/pipeline-compiler-design.md` — 设计稿（Q1-Q4 已 signed off）
- `docs/pipeline-compiler-handoff.md` — Session-to-session handoff + §10 opening prompt

**当前状态（2026-04-27）**：Phase 0-5 + Phase 8 fragment chain
已落地，558 tests pass，零 warning。Source-tap codegen + KI 头融
合 + TailSink 尾融合在 Session E 收敛后正式进入生产路径，runtime
parity test 锁住 codegen ↔ binding slot 一致性。剩下三件事：

| Phase | Scope | Blocker |
|---|---|---|
| **5 真机验证** | iPhone 上端到端跑全套 chain（编辑预览 + 相机预览 + 导出），确认 source-tap 融合输出与桌面 swift test 一致 | **user gate** 真机验证 |
| **6** | 12 filter 补 fragment shader body + compute/fragment parity（已部分落地：Phase 8 fragment chain 支持 5 种 shape，fragment-cluster codegen 路径就绪） | Phase 5 真机签字 |
| **7** | TBDR render pipeline backend + 终验 + 删 legacy kernels | **user gate** 真机终验 |

Session 间 handoff 用 `docs/pipeline-compiler-handoff.md` §10
opening prompt 装载上下文，不要重开 Q1-Q4 决策。

### 必定改 SDK 功能代码（0 条，不含 pipeline compiler）

无 — 所有"必改"代码类工作已在 Session C 落地。

### Release tag（1 条，user-gated）

| ID | 任务 |
|---|---|
| #63 | v0.1.0 tag（first public release — maintainer 执行 `git tag -s v0.1.0 && git push origin v0.1.0` 触发 release workflow） |

### 真机阻塞项（3 条）— 需要你在 iPhone 上真机评估后我才能关

| ID | 任务 |
|---|---|
| #37 | FilmGrain snapshot baseline freeze（gate on 真机确认） |
| #38 | CCD snapshot baseline freeze（gate on 真机确认） |
| #39 | PortraitBlur snapshot baseline freeze（gate on #75 真机确认） |

### v1.0 远期（2 条）

| ID | 任务 |
|---|---|
| #64 | v1.0.0 GA criteria 定义 + 锚定 |（Session C 已写 `docs/release-criteria.md`） |
| #65 | v1.0.0 GA tag（final release） |

---

## Session C 收敛决策速查

**砍掉**（TaskUpdate deleted）：

- #11 / #18 / #19 / #20 — 外部 app parity / SSIM 比对。DCR 不追 pixel-level 外部 parity；原理派自证 + 契约测试即可
- #41 / #42 / #43 — 性能测试（真机依赖 + 商用级 SDK 不需要在发布前锚定具体数字）
- #44 / #45 / #46 — 跨平台（macOS / Catalyst / tvOS/visionOS）。iOS-only 路线；macOS 保留 test-host 角色
- #50 / #51 / #52 — Harbeth 对照审计三件套。DCR 独立于 Harbeth，此审计与"存在意义"冲突
- #67 — Demo showcase 场景扩展（Demo 仅演示用途）
- #16 — Session B obsolete 的 §8 评估断点

**最终态：Tier 1 效果基础扎实，Tier 2 验证基础齐备，Tier 6 API 冻结 / Tier 7 Release 是剩余主攻。**

---

## 约束（SDK 级硬约束，任何 session 继承）

1. 每 commit 前 `swift build` + `swift test` 强制无豁免（见 `.claude/rules/commit-verification.md`）
2. 禁止"凭记忆"claim 业界做法，必须 fetched URL（`.claude/rules/engineering-judgment.md §4`）
3. 禁止"激进/保守"作质量判据（§1）
4. 替换算法前问历史（§3）
5. Test 失败默认**实现错不是断言错**，按 §2.2 三路对比（`.claude/rules/testing.md`）
6. 新滤镜开发前必须先做算法选型 4 步（`.claude/rules/filter-development.md`）
7. SDK 零外部依赖（`Package.swift.dependencies` 保持空；`PackageManifestTests` 自动守护）
8. 不主动 git push（需用户明确 "push"）
9. 英文 commits（conventional commits）+ 聊天简体中文

详见 `docs/session-handoff.md` §4。
