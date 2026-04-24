# DCRenderKit — Pending Work

**权威 todo 源** — repo 根目录显眼处。每 session 结束更新一次。

完整 task 历史（含已完成）在 `~/.claude/tasks/<session-uuid>/*.json`（Claude Code 内部存储）。此文件是**人类可读快照**。

**最后更新**: 2026-04-24（Session C 收敛后，iOS-only / 原理派 tone operators / 不追外部 parity / Tier 1-7 大部分落地，剩余约 12 条 API freeze + docs + release tag + 真机阻塞项）

---

## 已确认完成项（不再列 —— 见 git log 与 CHANGELOG.md `[Unreleased]`）

Session B：Tier 3 五 filter 完整闭环（契约 → impl → 验证 → 算法/参数依据） · §8.1 A.1-A.7 · §8.2 A+.1-A+.5 · §8.3 A++.1-A++.5 · §8.4 Audit.1-7 · B.1-B.4 参数级依据。

Session C：#74 typed Error enum hierarchy · #73 Package.swift 空依赖守护 · Tier 1.3 四 fitted filter 全部替换为原理派（Contrast→DaVinci log-slope / Blacks→Reinhard toe / Whites→Filmic shoulder / Exposure-neg→linear gain） · #75 PortraitBlur two-pass Poisson 架构 · IEC sRGB Foundation helper · LinearPerceptualParityTests · Snapshot regression framework（#36） · PipelineBenchmark（#40） · README / CONTRIBUTING / CODE_OF_CONDUCT / CHANGELOG（#53/#54/#55/#56） · GitHub Actions CI（#60） · Issue/PR templates（#68） · v0.1.0 GA criteria（#64） · macOS 业务层剥离（iOS-only） · Harbeth lineage descriptor 清理。

Session D：#66 PortraitBlur mask routing integration tests（`Tests/DCRenderKitTests/IntegrationTests/`，3 tests synthetic-source / half-split-mask 覆盖 Demo→SDK 路径） · #70 Maintainer SOP + SECURITY.md（`docs/maintainer-sop.md` PR review / release cut / breaking-change 登记 checklist + `SECURITY.md` 漏洞报告 scope / 支持版本 / 响应 SLA） · #69 GitHub Discussions 指南（`docs/discussions-guide.md` — 4 分区 Q&A / Show-and-tell / Ideas / General + 启用 checklist） · Foundation capability baseline（`docs/foundation-capability-baseline.md` — 18 条架构能力 claim + evidence + rationale，分 5 category：依赖/平台、正确性架构、色彩/算法基础、验证门槛、out-of-scope 不保证项） · #72 零 warning 审（修 ResourceManagementTests 非 Sendable self capture / SmokeTests + ColorGradingFilterTests + ToneAdjustmentFilterTests 的 `#file` → `#filePath` 签名对齐 / MultiPassAndLoaderTests unused var；CI 加 `-Xswiftc -warnings-as-errors` 把审计锁成持久 gate） · #71 零 TODO/FIXME 审（2 个 false positive 清理：CCDFilter.metal `FIXME` 引用字样去词 / PackageManifestTests.swift 字符串内 `TODO.md` 改引用形式；所有 19 条 FIXME/TODO 已带 `(§…)` 或 `(#…)` reference，皆指向 findings-and-plan.md 已 archived section，作为 Tier 4 snapshot 锁定前的 accepted empirical tech debt）。

---

## Pending 分类

### 必定改 SDK 功能代码（0 条）

无 — 所有"必改"代码类工作已在 Session C 落地。

### API 冻结 / 代码质量审（3 条）

| ID | 任务 |
|---|---|
| #47 | 所有 public API 加 `@available(iOS 18.0, *)` 标注 |
| #48 | internal / fileprivate 严格审（降级不必要 public） |
| #49 | Public API 冻结评审 + Breaking changes catalog |

### 文档（2 条）

| ID | 任务 |
|---|---|
| #58 | Architecture docs 迁入 DCRenderKit/docs/ |
| #59 | 所有 public 符号 SwiftDoc 完整性审 |

### DocC / Release plumbing（4 条）

| ID | 任务 |
|---|---|
| #57 | DocC 文档配置 + 本地生成 + 预览 |
| #61 | GitHub Actions DocC 生成 + GitHub Pages |
| #62 | Release 流程自动化（tag → CHANGELOG → GitHub Release） |
| #63 | v0.1.0 tag（first public release） |

### Test 覆盖补强（Session C 末 test coverage audit 发现，2 条，低优，不 block release）

| ID | 任务 | 背景 |
|---|---|---|
| #93 | CCD 结构性单测补 3-5 个（当前仅 2 个 identity + clamping） | Tier 4 by design 用 snapshot 代契约，但 CCD 单测比 FilmGrain/PortraitBlur 都薄。候选方向：mosaic pattern orientation / vignette 半径 × 分辨率比例 / filter step ordering 不变性 |
| #94 | `PipelineErrorTests.swift` 专门 error case 覆盖 | 当前 `PipelineError` typed enum 的 error path test 是 implicit 散布在各 dispatcher/loader/filter test 里，没有专门 error file 系统枚举所有 case |

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
