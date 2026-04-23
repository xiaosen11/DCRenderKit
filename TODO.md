# DCRenderKit — Pending Work

**权威 todo 源** — repo 根目录显眼处。每 session 结束更新一次。

完整 task 历史（含已完成）在 `~/.claude/tasks/<session-uuid>/*.json`（Claude Code 内部存储）。此文件是**人类可读快照**。

**最后更新**: 2026-04-23（Session C 进行中，HEAD `b327214`，0 ahead of origin/main — Session B 后已 push，299 tests pass）

---

## 已确认完成项（31 条，不再列 —— 见 git log）

Tier 3 五 filter 完整闭环（契约 → impl → 验证 → 算法/参数依据） · §8.1 A.1-A.7 · §8.2 A+.1-A+.5 · §8.3 A++.1-A++.5 · §8.4 Audit.1-7 全部 ✓ · B.1-B.4 参数级依据全部收尾 · **#74 typed Error enum hierarchy（Session C 代码审确认）**

---

## Pending 分类（按"是否改 SDK 功能代码" `Sources/DCRenderKit/**`）

### 必定改 SDK 功能代码（3 条）

| ID | 任务 | Scope |
|---|---|---|
| #47 | 所有 public API 加 `@available` 标注 | 全 public 声明加属性 |
| #73 | Package.swift dependencies 必须空验证 | 守护测试（当前已空，不需删依赖） |
| #75 | PortraitBlur 效果强度优化（真机 slider +100 过弱） | shader 参数 / 算法调整 |

> **#74 typed Error enum hierarchy 已完成** — `Sources/DCRenderKit/Error/PipelineError.swift` 已是 5-domain typed enum（device / texture / pipelineState / filter / resource）。grep `NSError` 在 Sources/ 零结果。Session C (2026-04-23) 代码审确认无遗留，任务移除。

### 可能改 SDK 功能代码（investigation，发现问题才改，12 条）

| ID | 任务 | 触发改代码条件 |
|---|---|---|
| #19 | 5 fitted × 20 JPEG SSIM 对比 | 低 SSIM + 用户决定 refit（blocked by #11 已签 no → 实际 dead） |
| #20 | 低 SSIM 根因决策 | 同上 |
| #44 | macOS 路径完整性验证 | 发现 macOS 特异 bug |
| #45 | Catalyst 兼容性测 + 决策 | 不兼容需条件编译 |
| #48 | internal/fileprivate 严格审 | 不当 public 降级（API break） |
| #49 | Public API 冻结评审 + Breaking changes catalog | 冻结时发现命名/签名问题 |
| #50 | 每个 filter 对照 Harbeth 源码 diff 审计 | 发现 behavior gap |
| #51 | Harbeth 遗漏 filter 清单 + 决定是否补 | 补 = **新 filter 代码** |
| #52 | DigiCam Harbeth→DCR 迁移影响评估 | 发现集成 bug |
| #66 | Demo 加 XCTest / SDK 集成测试 | 暴露 SDK 集成 bug |
| #71 | 零 TODO/FIXME 审（全部 resolve 或 link issue） | resolve 动作触达代码 |
| #72 | 零 warning 审（-warnings-as-errors） | 修 warning 触达代码 |

### 纯 test / tooling（新代码但非 filter 功能，9 条）

| ID | 任务 |
|---|---|
| #18 | SSIM 对比脚本（Swift CLI tool） |
| #36 | Snapshot regression framework |
| #37 | FilmGrain snapshot baseline freeze |
| #38 | CCD snapshot baseline freeze |
| #39 | PortraitBlur snapshot baseline（blocked by #75） |
| #40 | Pipeline benchmark harness + 4K per-filter ms 测 |
| #41 | TexturePool 内存 profile |
| #42 | 真机 GPU utilization + 热度测 |
| #43 | 视频管线 per-frame 场景测（30fps 1080p 30s） |

### 纯文档（7 条）

| ID | 任务 |
|---|---|
| #53 | README.md（中英双语 + quick start） |
| #54 | CONTRIBUTING.md |
| #55 | CODE_OF_CONDUCT.md（Contributor Covenant 2.1） |
| #56 | CHANGELOG.md（keep-a-changelog） |
| #57 | DocC 文档配置 + 本地生成 + 预览 |
| #58 | Architecture docs 迁入 DCRenderKit/docs/ |
| #59 | 所有 public 符号 SwiftDoc 完整性审 |

### 纯 CI / Release / Community（10 条）

| ID | 任务 |
|---|---|
| #60 | GitHub Actions CI |
| #61 | GitHub Actions DocC 生成 + Pages |
| #62 | Release 流程自动化 |
| #63 | v0.1.0 tag（first public release） |
| #64 | v1.0.0 GA criteria 定义 + 锚定 |
| #65 | v1.0.0 GA tag |
| #67 | Demo showcase 场景扩展（Demo 不是 SDK） |
| #68 | Issue / PR 模板 |
| #69 | GitHub Discussions 开启 + 分区 |
| #70 | Maintainer SOP + Code review process |

### 用户决策 / obsolete（3 条）

| ID | 状态 |
|---|---|
| #11 | 已签字"不做外部锚定" — 事实上 dead，但未 mark deleted |
| #16 | Session B 已过完整个 §8.1-§8.4，obsolete |
| #46 | tvOS/visionOS 支持决策（待用户 input） |

---

## 未来 session 推荐切分

- **P1（最大未知）**：#50 + #51 + #52 **Phase 10 Harbeth diff** — 能力完整性缺口扫描
- **P2（基线护城河）**：#40-#43 **Phase 7 performance** — 定性能数字、发现回归能抓
- **P3（scope 清晰的打包）**：#47 + #73 + #74 + #75 **必定改代码 4 条打包**

---

## 约束（SDK 级硬约束，任何 session 继承）

1. 每 commit 前 `swift build` + `swift test` 强制无豁免，无条件适用（见 `.claude/rules/commit-verification.md`）
2. 禁止"凭记忆"claim 业界做法，必须 fetched URL（`.claude/rules/engineering-judgment.md §4`）
3. 禁止"激进/保守"作质量判据（§1）
4. 替换算法前问历史（§3）
5. Test 失败默认**实现错不是断言错**，按 §2.2 三路对比（`.claude/rules/testing.md`）
6. 新滤镜开发前必须先做算法选型 4 步（`.claude/rules/filter-development.md`）
7. SDK 零外部依赖（Package.swift.dependencies 保持空）
8. 不主动 git push（需用户明确 "push"）
9. 英文 commits（conventional commits）+ 聊天简体中文

详见 `docs/session-handoff.md` §4。
