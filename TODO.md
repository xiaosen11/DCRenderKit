# DCRenderKit — Pending Work

**权威 todo 源** — repo 根目录显眼处。每 session 结束更新一次。

完整 task 历史（含已完成）在 `~/.claude/tasks/<session-uuid>/*.json`（Claude Code 内部存储）。此文件是**人类可读快照**。

**最后更新**: 2026-04-24（Session C 收敛后，iOS-only / 原理派 tone operators / 不追外部 parity / Tier 1-7 大部分落地，剩余约 12 条 API freeze + docs + release tag + 真机阻塞项）

---

## 已确认完成项（不再列 —— 见 git log 与 CHANGELOG.md `[Unreleased]`）

Session B：Tier 3 五 filter 完整闭环（契约 → impl → 验证 → 算法/参数依据） · §8.1 A.1-A.7 · §8.2 A+.1-A+.5 · §8.3 A++.1-A++.5 · §8.4 Audit.1-7 · B.1-B.4 参数级依据。

Session C：#74 typed Error enum hierarchy · #73 Package.swift 空依赖守护 · Tier 1.3 四 fitted filter 全部替换为原理派（Contrast→DaVinci log-slope / Blacks→Reinhard toe / Whites→Filmic shoulder / Exposure-neg→linear gain） · #75 PortraitBlur two-pass Poisson 架构 · IEC sRGB Foundation helper · LinearPerceptualParityTests · Snapshot regression framework（#36） · PipelineBenchmark（#40） · README / CONTRIBUTING / CODE_OF_CONDUCT / CHANGELOG（#53/#54/#55/#56） · GitHub Actions CI（#60） · Issue/PR templates（#68） · v0.1.0 GA criteria（#64） · macOS 业务层剥离（iOS-only） · Harbeth lineage descriptor 清理。

Session D：#66 PortraitBlur mask routing integration tests（`Tests/DCRenderKitTests/IntegrationTests/`，3 tests synthetic-source / half-split-mask 覆盖 Demo→SDK 路径） · #70 Maintainer SOP + SECURITY.md（`docs/maintainer-sop.md` PR review / release cut / breaking-change 登记 checklist + `SECURITY.md` 漏洞报告 scope / 支持版本 / 响应 SLA） · #69 GitHub Discussions 指南（`docs/discussions-guide.md` — 4 分区 Q&A / Show-and-tell / Ideas / General + 启用 checklist） · Foundation capability baseline（`docs/foundation-capability-baseline.md` — 18 条架构能力 claim + evidence + rationale，分 5 category：依赖/平台、正确性架构、色彩/算法基础、验证门槛、out-of-scope 不保证项） · #72 零 warning 审（修 ResourceManagementTests 非 Sendable self capture / SmokeTests + ColorGradingFilterTests + ToneAdjustmentFilterTests 的 `#file` → `#filePath` 签名对齐 / MultiPassAndLoaderTests unused var；CI 加 `-Xswiftc -warnings-as-errors` 把审计锁成持久 gate） · #71 零 TODO/FIXME 审（2 个 false positive 清理：CCDFilter.metal `FIXME` 引用字样去词 / PackageManifestTests.swift 字符串内 `TODO.md` 改引用形式；所有 19 条 FIXME/TODO 已带 `(§…)` 或 `(#…)` reference，皆指向 findings-and-plan.md 已 archived section，作为 Tier 4 snapshot 锁定前的 accepted empirical tech debt） · #59 SwiftDoc 完整性审（16 filter 的 protocol conformance members + init + PipelineBenchmark.Result 6 properties 全部补 doc，infra types 的 member doc 密度已达标） · #48 internal/fileprivate 严格审（保守降级 `MultiPassExecutor` public → internal — 只有 Pipeline.executeMultiPass 调用，consumer 通过 `.multi(filter)` 间接触达；其他 public types 作 FilterProtocol conformance params / Pipeline injection deps 保留 public） · #49 Public API freeze review（`docs/api-freeze-review.md` — 8 类 public surface 每类 Stable/Evolving/Experimental 分层 + 全量 `[Unreleased]` breaking changes 对账 + deprecation workflow + 0.x 适配承诺） · #47 `@available(iOS 18.0, *)` 覆盖 64 条 public top-level declaration（3 个 PortraitBlurMaskGenerator 内部 `@available(iOS 17.0, *)` 升到 18 匹配 SDK deploy target） · #58 `docs/architecture.md`（13 条关键架构决策各配 choice/rejected/why/origin 四段，补上 layered overview ASCII 图 + 5 条 design principles + data flow，与 foundation-baseline 形成 narrative vs. capability 互补） · #57 DocC catalog（`Sources/DCRenderKit/DCRenderKit.docc/{DCRenderKit,GettingStarted,Architecture}.md` — landing page 全量 topic 分区 + getting-started 集成走查 + architecture TL;DR；CONTRIBUTING 补 local preview 说明；刻意不加 swift-docc-plugin 维持零依赖） · #61 DocC GitHub Pages deploy workflow（CI `docs` job 用 `xcodebuild docbuild` + `docc process-archive transform-for-static-hosting` + `actions/deploy-pages` —仅 main branch） · #62 Release automation workflow（`.github/workflows/release.yml` tag push → swift test 验证 → CHANGELOG section 提取 → `gh release create` 创建 GitHub Release；pre-1.0 / -suffix tag 自动 mark prerelease；maintainer 按 SOP §2 手动 tag 后触发） · #93 CCD 结构性单测补 4 个（CA 隔离 R/B 水平 offset / saturationBoost 对灰度 identity / 噪点 block 量化 / strength mix 线性性） · #94 `PipelineErrorTests.swift` 独立 15 tests（5 domain × 24+ cases 描述覆盖 / pattern-match / Invariant trigger / LUT3DFilter fail path）。

---

## Pending 分类

### 进行中的大型重构：Pipeline Compiler（Phase 5-7 剩余）

**入口文档**：
- `docs/pipeline-compiler-design.md` — 设计稿（Q1-Q4 已 signed off）
- `docs/pipeline-compiler-handoff.md` — Session-to-session handoff + §10 opening prompt

**当前状态（2026-04-24）**：Phase 0-4 完成，504 tests pass，零
warning。12 filter codegen + legacy parity 通过，cluster fusion 实
装，aliasing allocator 就绪。剩下三个 phase 要接着做：

| Phase | Scope | Blocker |
|---|---|---|
| **5** | Pipeline.executeStep 走 codegen + 删 12 个 production kernel + warm-up API + 迁移 50+ existing tests + 真机 benchmark | **user gate** 真机验证 |
| **6** | 12 filter 补 fragment shader body + compute/fragment parity | Phase 5 完成 |
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
