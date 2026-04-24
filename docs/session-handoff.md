# DCRenderKit Session Handoff

**目的**: 让任何一个新 Claude Code session 能在 5 分钟内接管上一个 session 的全部上下文，零信息丢失。本文是每次 session 结束前必须更新的握手状态。

**最后更新**: 2026-04-24，Session C 结束

---

## 0. 最重要的事（如果只读一段）

- Repo: `/Users/xiaosenromangic.com/DevWorkSpace/DCRenderKit/`
- 当前分支 `main`，`HEAD = c46ab19`（handoff snapshot commit），**Session C 累计 18 commits ahead of origin/main 未 push**（禁止自动 push）。snapshot 状态锚定在 handoff commit 前一刻的 `86b90c9`，但 `git log` 实时 HEAD 永远是 handoff commit 自己 —— 这是不可避免的 handoff paradox，不是 bug
- **326 tests pass / 0 failures / 0 warnings**
- **权威 pending todo** 在 repo 根 `TODO.md`（Session C 已重写成分类清单）。**不要**声称 TaskList 丢了 —— 见 §1。
- 硬约束 5 份 `.claude/rules/*.md` 必读 —— 见 §4。
- **Session C 的四个一致性 axiom（任何 session 继承，不可 revisit）**:
  1. **DCR 独立于 Harbeth** — 代码注释不引 Harbeth lineage，仅保留学术引用（Reinhard / DaVinci / OKLab / He & Sun / Mitchell / Ottosson / Hable / Eilertsen / IEC 61966-2-1 / Bjørge 等）
  2. **iOS-only SDK** — `Package.swift.platforms` 保留 `.macOS(.v15)` 仅作 `swift test` host，business-layer NSImage/AppKit 路径**已删尽**，不要重新加回
  3. **不追外部 pixel-level parity** — 任何 SSIM / Pixel Cake JPEG / Lightroom TIFF 对比方案都是 dropped；fitted Tier 2 filter 已全部替换为原理派，不要"为了对齐外部 app"重新 fit
  4. **原理派 tone operators** — Contrast (DaVinci log-slope) / Blacks (Reinhard toe) / Whites (Filmic shoulder) / ExposureNeg (pure linear gain) 全部已落地；新增 tone filter 必须走 filter-development.md 4 步，原理派是 Tier 0 候选
- **Session B 遗留的 Tier 3 五 filter 完整闭环**（Saturation/Vibrance/HS/Clarity/SoftGlow 契约 + 验证 + 算法依据 + 参数依据）**不要推倒重做**。
- **Session C 新增基础设施不要弃置**: `SnapshotAssertion`（Tier 4 snapshot 用）、`PipelineBenchmark`（性能用）、`LinearPerceptualParityTests`（feel drift 护栏）、`Foundation/SRGBGamma.metal`（IEC sRGB canonical）、`PackageManifestTests`（零依赖守护）、GitHub Actions CI / Issue-PR templates。

---

## 1. TaskList 真实存储位置（绝对不会"丢"）

### 存储位置

Claude Code 的 TaskList 数据持久化在：

```
~/.claude/tasks/<session-uuid>/<task-id>.json
```

每个 session 有独立 UUID；task JSON 文件按 id 命名。**UUID 即对话记录的 .jsonl 文件名**（在 `~/.claude/projects/-Users-xiaosenromangic-com-DevWorkSpace-wayshot-pm-agent-Digi-Cam/` 下）。

### 迁移步骤（新 session 接管时执行）

1. 查上一个 session 的 UUID（对话 .jsonl 文件 mtime 最近的就是）
2. 上一个 session task 目录：`~/.claude/tasks/<prev-uuid>/`
3. 当前 session 的 task 目录应自动创建（UUID 即当前对话 .jsonl）
4. 迁移命令：
   ```bash
   mkdir -p ~/.claude/tasks/<current-uuid>/
   cp ~/.claude/tasks/<prev-uuid>/*.json ~/.claude/tasks/<current-uuid>/
   ```
5. 然后 `TaskList` 工具会看到所有继承的 task（id 保留）

### 最近 session UUID 链（倒序）

| Session | UUID | 最后 commit |
|---|---|---|
| C (结束于 2026-04-24) | `6afb8a49-4085-4fc3-9b37-557b14c24dba` | `86b90c9` |
| B (结束于 2026-04-23) | `5d660bae-cb61-4c43-b626-12c921a9ac53` | `b327214` |
| A (结束于 2026-04-22) | `1ece456e-1d62-4dea-91d2-137f310c2a3a` | `2e5df4c` |
| 更早 | `67404015-6221-4bc5-bf0a-217ab8cedbf8` | — |

### 诚实记录：Session B 初时犯的错（警世）

Session B 初次接 Session A 时，先查 `TaskList` 看到空，然后**谎称**"跨 session 不保留"—— 这是**错的**。实际只是新 session 的 task 目录未创建 / 未迁移。**绝不要再犯这个错**。新 session 的第一个 action 应是：查上一个 session 的 task 目录存在与否、迁移。如果仍有问题，读 `TODO.md`（repo 根）也能立刻拿到 pending 列表。

### Session C 接任时的经验（与上条形成对照）

Session C 开始时：
1. 读 `docs/session-handoff.md` 全文
2. 按 §7 Phase 2.1 执行 `cp ~/.claude/tasks/<B>/*.json ~/.claude/tasks/<C>/` — 75 tasks 继承成功（31 completed + 44 pending）
3. `swift test` 验证 299-test 基线匹配 handoff §3 snapshot（Session B 交接时的 contract）
4. 发现 HEAD 与 handoff §3 说的 `9b3aa50 + 62 ahead 未 push` 不一致（实际已 push 到 `b327214`），以**当下 git 状态为准**，在汇报里标注 drift
5. 开始按用户指示推进，不再自证 TaskList 问题

**Session D 继续这个 pattern**。

---

## 2. 文档全景图（5 分钟知道看什么）

### Repo 根（新 session 先看这里）

- **`TODO.md`** ← 权威 pending todo，分类清单，Session C 重写成 12 条收尾 + 3 条真机阻塞 + 3 条保留 artifact + 2 条 v1.0 远期
- **`CHANGELOG.md`** ← `[Unreleased]` 段累积 Session B/C 所有 breaking changes 与新增，format keep-a-changelog 1.1.0 / SemVer 2.0.0
- **`docs/session-handoff.md`** ← 本文件
- **`docs/release-criteria.md`** ← Session C 写，三级 v0.1.0 GA 定义（minimal / consumer-grade / visual-quality）
- `README.md` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` / `LICENSE` — Session C 全刷过一遍（中英双语 README + 5 份 rules 引用 + 零依赖 / iOS-only 声明）
- `Package.swift` — iOS 18+ / macOS 15+（**macOS 仅 test host**）/ Swift 6 strict concurrency / 零外部依赖
- `CLAUDE.md` — 项目级 Claude 指令
- `.github/workflows/ci.yml` — Session C 重写：macos-15 + Xcode 16，合并为 `test` + `ios-build` 两 job，lint 检测 FIXME/TODO 必带 `(§…)` 或 `(#…)` 引用
- `.github/ISSUE_TEMPLATE/*.yml` + `PULL_REQUEST_TEMPLATE.md` — bug / feature / PR 模板

### `docs/`（审计 + 契约 + 历史）

- **`docs/findings-and-plan.md`** ← 历史 audit plan。**§7.3 / §8.4 / §8.5 / §8.6 均带 `ARCHIVED (2026-04-23)` 横幅**：Session C 做完了 §8.4 全部 / 完成了 §8.5 B.1 决策（换原理派）/ 丢弃了 §8.6 Tier 2 外部 parity 思路。内容保留作历史上下文
- **`docs/contracts/*.md`** ← 5 份 Tier 3 filter 契约（vibrance / saturation / highlight_shadow / clarity / soft_glow）。每份 6-7 条可测条款，每条款写了测法 + 依据 fetched URL。Session C 清理了各自 "实现归属" 格子里的 Harbeth lineage 字样
- **`docs/release-criteria.md`** ← Session C 写，本文件 §3 state snapshot 对应的 release readiness

### `.claude/rules/*.md`（5 份硬约束，必读）

见 §4 详列。Session C 未新增 rules（所有既有 rules 都适用）。

### `.claude/agents/*.md`

用户未启用 sub-agents（Session C 也没调过），跳过。

### Skills

DCRenderKit repo 自身没有 `.claude/skills/` 目录。session 可以继承使用 DigiCam 项目级的 skills（`pixel-fitting`, `ci-cd`, `perf`, `debug`, `native-ios` 等），但 **SDK 的"真 source of truth"是 5 份 rules + 本文件**；skills 是工具，rules 是硬约束。

### memory 自动加载

`~/.claude/projects/-Users-xiaosenromangic-com-DevWorkSpace-wayshot-pm-agent-Digi-Cam/memory/MEMORY.md` 是索引，加载完整文件 `project_dcrenderkit.md`、`user_preferences.md`、`feedback_commit_verification.md`。**新 session 会自动看到**，但里面记录的状态可能滞后，以 `TODO.md` + git log + 本文件为准。Session C 已更新 `project_dcrenderkit.md` 到当前状态。

---

## 3. 当前 state snapshot（2026-04-24 Session C 结束）

### Git

- 分支: `main`
- HEAD: `c46ab19`（`docs(handoff): Session C end snapshot`，handoff 自身）
- State snapshot 锚定: `86b90c9`（handoff commit 前一刻）—— 此 snapshot 里引用的测试数 / ahead 数 / breaking change 列表都是**写入 handoff 时的状态**，handoff commit 本身不改变 code 故 326 tests 两个 HEAD 上都 pass
- **18 commits ahead of origin/main**（Session C 累计，**含 handoff commit 自身**，未 push，禁止自动 push）
- Working tree: `Examples/DCRDemo/DCRDemo.xcodeproj/project.pbxproj` **持续脏**，属 Xcode IDE 自动编辑（`LastUpgradeCheck` + `DEVELOPMENT_TEAM` 位置漂移），**不要 stage**

### 测试

- **326 tests pass / 0 failures / 0 warnings**
- 新增测试文件（Session C）：
  - `Tests/DCRenderKitTests/PackageManifestTests.swift`（1 test — `.package(url:)` 守护）
  - `Tests/DCRenderKitTests/SRGBGammaConversionTests.swift`（12 tests — IEC 61966-2-1 piecewise 正反 + Zone midpoint 圆舍）
  - `Tests/DCRenderKitTests/LinearPerceptualParityTests.swift`（5 tests — 5 tone filter × 7 slider × 9 input = 315 grid-point parity 扫描）
  - `Tests/DCRenderKitTests/SnapshotAssertionTests.swift`（6 tests — snapshot framework self-test）
  - `Tests/DCRenderKitTests/PipelineBenchmarkTests.swift`（4 tests — benchmark primitive）
- 已更新测试：`MultiPassAndLoaderTests.swift`（删 `testNSImageLoad`）、`SmokeTests.swift`（PortraitBlur `.single` → `.multi`）、`PortraitBlurAndStatisticsTests.swift`（`runSingle` → `runMulti`）、`ToneAdjustmentFilterTests.swift`（Contrast/Blacks/Whites/ExposureNeg 断言按新原理派公式重推）、`Bgra8UnormSourceContractTests.swift`（Contrast expected 从 0.181 → 0.108）
- Contract tests (Session B 遗留) 继续保留全部：Vibrance 7 / Saturation 7 / HighlightShadow 8 / Clarity 7 / SoftGlow 6 = 35

### Filter 状态（Tier 分类 — Session C 更新）

| Tier | Filters | 验证方式 | 状态 |
|---|---|---|---|
| 1 formula-is-spec | Sharpen, NormalBlend, LUT3D, Exposure+ | unit test | ✓ 维护 |
| 2 **principled tone operators** (Session C 重写) | Contrast → DaVinci log-slope · Blacks → Reinhard toe · Whites → Filmic shoulder · ExposureNeg → linear gain · WhiteBalance 保留（YIQ + Kelvin 已原理化） | unit test + `LinearPerceptualParityTests` 315-点扫描 | ✓ 全绿 |
| 3 perception-based | Saturation / Vibrance (OKLCh) · HighlightShadow / Clarity (Guided Filter) · SoftGlow (pyramid bloom) | 契约 C.1-C.x 全部闭环 (Session B) | ✓ |
| 4 aesthetic | FilmGrain · CCD · PortraitBlur (Session C 升级为 two-pass Poisson) | Snapshot framework ready (`SnapshotAssertion`), **baselines 需真机 approve 再 freeze** | framework ✓ / baseline ⏳ 真机 |

### Session C 完成项（commit hash 索引，18 条）

**阶段 1 — Pre-convergence（Session C 前半）**:
- `8268686` — 标 #74 typed Error enum 已完成（代码早就是 typed enum，TODO 过期）
- `00e38d9` — `PackageManifestTests` 守护零外部依赖（#73）
- `998060d` — 抽 `Foundation/SRGBGamma.metal` canonical + 12 conversion tests（8 shader 统一到 `DCRSRGBLinearToGamma` / `DCRSRGBGammaToLinear`，MIRROR 模式）
- `173ff17` — PortraitBlur 重构为 MultiPassFilter（#75）：两遍 Poisson + 90° rotated pattern + 0.030 shortSide + SDK 扩展 `PassInput.additional(Int)` / `MultiPassFilter.additionalInputs`
- `5f32b2e` — Contrast → DaVinci log-space slope（`y = pivot · (x/pivot)^slope`, slope = `exp2(contrast · 1.585)`）
- `f402839` — Blacks → Reinhard toe with scale（`y = x / (x + ε·(1−x))`, ε = `exp2(−slider)`）
- `7760a0c` — Whites → Filmic shoulder（`y = ε·x / ((1−x) + ε·x)`）；**移除** `lumaMean:` 参数（breaking change）
- `cbeb3e3` — Exposure 负向 → pure linear gain（ev<0 不需要 Reinhard 因为 `gain<1` 无 overshoot）
- `6256d9a` — `LinearPerceptualParityTests`：5 tone filter × 315 grid-point parity（formalises findings §7.3 "feel drift" concept）
- `15a528b` — `SnapshotAssertion` + self-tests（#36，为 Tier 4 baseline freeze 铺路）
- `0b56b49` — `PipelineBenchmark` + self-tests（#40，SDK-internal timing，`MTLCommandBuffer.gpuStart/EndTime`，无 Instruments 依赖）
- `f65da03` — README 中英双语重写 + CONTRIBUTING 补 rules 引用 + 新建 CHANGELOG.md（`[Unreleased]` 含全部 Session C breaking changes）
- `40feef5` — CI workflow 重写（macos-15 + Xcode 16）+ Issue / PR templates
- `c8df797` — `docs/release-criteria.md`（v0.1.0 GA 三级定义）

**阶段 2 — Session C 收敛（HEAD side）**:
- `d10bbf7` — **macOS 业务层全删**（删 `PipelineInput.nsImage` / `TextureLoader(from: NSImage)` / `typealias DCRImage = NSImage` / `@available(iOS 17.0, macOS 14.0, *)` → `@available(iOS 17.0, *)` / CI matrix macOS job / 所有 README / CONTRIBUTING / release-criteria 的 macOS 声明）
- `641bde2` — **Harbeth lineage 清理**（42 处 Sources/ 注释 + README + CHANGELOG + contracts + release-criteria；保留 findings-and-plan / session-handoff 的历史记录；保留全部学术 fetched URL）
- `86b90c9` — findings-and-plan §7.3 / §8.4 / §8.5 / §8.6 加 `ARCHIVED (2026-04-23)` 横幅 + TODO.md 全量重写

### 未 push 的含义

18 commits 包括多组**破坏性行为变更**：
- Contrast / Blacks / Whites / ExposureNeg 曲线形状
- PortraitBlur `FilterProtocol → MultiPassFilter`（调用点必须改 `.single` → `.multi`）
- Whites 删 `lumaMean:` 参数
- macOS 业务层路径全删（NSImage API 不存在了）
- Swift sRGB helper 函数名统一（`dcr_{filter}LinearToGamma` → `DCRSRGBLinearToGamma`）

push 前建议：**DigiCam 端真机回归一遍 Tier 3-4 slider 体验**，尤其 Tier 2 新原理派曲线 + PortraitBlur 新强度。`CHANGELOG.md [Unreleased]` 里登记了每条 breaking change 的迁移说明。

### 3.X Session C 决策 trace（完整原始文本 + 实施 delta）

**Session C 中 user 用"一句话 binary approve"拍板了 3 组 tier-1 决策（D1 / D3 / D5）+ 1 组大收敛决策。** 实施过程中我基于业界验证和代码现实对部分做了微调 — 这里记录**原始推荐 → 用户批准 → 实施 delta**，让 Session D 理解当前状态的"由来"，避免 revisit。

#### D1 — Tier 2 fitted filter 路线（timestamp 2026-04-23 12:13）

**原始推荐（替换原理派）**：

| Filter | 原推荐 | 实际落地 | Delta 原因 | Commit |
|---|---|---|---|---|
| Contrast | DaVinci log-space `y = pivot·(x/pivot)^slope` | ✅ DaVinci log-slope, `slope = exp2(contrast · 1.585)` | 无 delta | `5f32b2e` |
| Blacks | Filmic toe `y = x / (x + ε·(1−x))` (Blender AgX) | ⚠️ **Reinhard toe with scale**（公式相同但溯源到 Reinhard 2002 更早更权威） | 数学等价，溯源换更原始的 fetched URL | `f402839` |
| Whites | Inverse Filmic shoulder | ⚠️ **Filmic shoulder `y = ε·x / ((1−x) + ε·x)`**（是 Blacks toe 的代数镜像而非"inverse"） | 命名准确化：`y = 1 − toe(1−x, ε)` 展开即得，不是逆函数 | `7760a0c` |
| Exposure neg | Inverse Reinhard `y = x / (1 − x + ε)` | ⚠️ **Pure linear gain `y = clamp(x · gain, 0, 1)`** | gain<1 无 overshoot，不需要 Reinhard；实施时发现原推荐过度工程化 | `cbeb3e3` |
| WhiteBalance | 保留（YIQ tint + Kelvin warm-overlay 已原理派） | ✅ 保留，无变更 | 无 delta | — |

**用户批准文本**: "全 OK"（2026-04-23 12:14）。

**Breaking change 说明**: Whites 删 `lumaMean:` 参数（shoulder 不需要 scene-adaptive pivot），这是 D1 批准后实施中发现的必然简化，已登记 `CHANGELOG.md [Unreleased]`。

#### D3 — PortraitBlur kernel 路线（同 D1 approved）

**原始推荐（方案：两遍 apply + 移除 Swift ×0.5 + shader 系数 `0.040`）**:

- 根因：`PortraitBlurFilter.swift:86-88` Swift 层 `strength * 0.5` 二次压缩 + `maxBlurRadius = shortSide * 0.025` → slider=100 时 1080p 峰值仅 13.5px / 4K 27px，**远低于 Apple Portrait mode 典型 50-100px 区间**
- 业界对标：Apple Portrait f/2.8-f/4.5 ≈ 50-100px（4K 场景实测）；Instagram/VSCO 100-200px；DCR 原值低于基线
- 两遍 Poisson 16-tap = 等效 32-tap 采样密度（shader 注释 §53 原已预留），消除 ≥60px banding

**实际落地**：

| 项 | 原推荐 | 实际 | Delta 原因 |
|---|---|---|---|
| 二次压缩 | 移除 Swift ×0.5 | ✅ 移除 | 无 delta |
| shader 系数 | `0.040` (1080p 43px / 4K 86px) | ⚠️ **`0.030`** (1080p 46px / 4K 92px) | 两遍 Poisson `σ·√2` 放大因子让 0.030 已覆盖 Apple Portrait 上界；0.040 会 overshoot 到 120px+ |
| 两遍 apply | 是 | ✅ two-pass Poisson + 90° rotated pattern | pass 2 旋转让 32 sample 位置 uncorrelated |
| 架构 | FilterProtocol（单 pass） | ⚠️ **MultiPassFilter**（SDK 扩展 `PassInput.additional(Int)` + `MultiPassFilter.additionalInputs`） | 两遍需要 mask + intermediate texture 路由，SDK 原 MultiPassFilter 仅支持 `.primary`，必须扩展 |

Commit: `173ff17`。`kDCRPortraitBlurCoef = 0.030` 旁已写 doc comment: 真机觉得"还弱"升到 0.035；觉得"太猛"降到 0.025。

#### D5 — 真机回归 reference（同 D1 approved）

**原始推荐**: 用户自己拍人像+风光 / Pixel Cake JPEG 20 张 / Lightroom 导出作 Tier 2 fitted filter 对照 → "不声称 matches 某 specific app，但每个 filter 要过'你觉得商用级'这一关"

**实际落地**: ⚠️ **D5 后来被 Session C 收敛决策整体砍掉**（见下一节）。不追外部 pixel-level parity 成为第 3 条 axiom，Pixel Cake 对照 + Lightroom 导出方案 dropped。**替换为**：内部 `LinearPerceptualParityTests` 315-点扫描 + `SnapshotAssertion` 真机 baseline（#37/#38/#39 仍 pending 真机）+ 每个 Tier 3 filter 的契约 C.1-C.x 条款。

#### Session C 收敛决策（timestamp 2026-04-23 后半段，user 完整原文）

> **砍（TaskUpdate deleted）**:
> - #41 #42 #43 性能测试
> - #44 #45 #46 跨平台（**方案 A**：Package.swift 保留 `.macOS(.v15)` 作 test host，业务 NSImage/AppKit 分支全删，文档去 macOS 支持声明，CI matrix 删 macOS）
> - #50 #51 #52 Harbeth 三条
> - #11 #18 #19 #20 外部锚定四条
> - #67 Demo showcase
> - #16 obsolete
>
> **保留做**:
> - #66 Demo→SDK integration test（放 `Tests/DCRenderKitTests/IntegrationTests/`，**不加 Demo XCTest target**）
> - #69 写 `docs/discussions-guide.md`（GitHub 页面开启用户自己做）
> - #70 写 `docs/maintainer-sop.md` + `SECURITY.md`
>
> **代码清理**:
> - 全仓清理 NSImage / AppKit / `#if canImport(AppKit)` / `@available` 里的 macOS 部分
> - 全仓清理 Harbeth 引用注释（"ported from Harbeth" / "inherited from Harbeth lineage" 等），保留 fetched reference（Reinhard / DaVinci / OKLab 等学术引用）
> - `findings-and-plan.md` 的 §7.3 / §8.4 / §8.5 B.1 / §8.6 Tier 2 相关章节加 **ARCHIVED (2026-04-23)** 横幅，内容不删
>
> **新建**:
> - `docs/foundation-capability-baseline.md`（DCR 基座能力 checklist，约 15 条架构能力，用于自证"基座 ≥ Harbeth"）
>
> **规则**:
> - 分批 commit，每 commit 前跑 swift build

**落地情况**:
- 方案 A (iOS-only + macOS test host) → commit `d10bbf7`
- Harbeth lineage strip → commit `641bde2`（42 处 Sources/ 清理 + 学术引用保留）
- `findings-and-plan.md` ARCHIVED banner → commit `86b90c9`
- TODO.md 重写为分类清单 → commit `86b90c9`（同一 commit）
- 保留做 3 条 **+** `docs/foundation-capability-baseline.md` → **未完成，作为 Session D 第一批 artifact**（见 §6 + §7）

#### 决策 trace 的关键教训（写给 Session D）

1. **"全 OK" 不代表盲 implement**：D1 批准 Blacks Filmic toe，但实施时查到 Reinhard 2002 更原始 → 用后者（数学等价）。D1 批准 Exposure Inverse Reinhard，实施时发现 gain<1 无需 → 换 linear gain。**approved 路线 + 业界/数学验证修正 = 正确落地**，这是合规，不是偏离
2. **PortraitBlur 0.040 → 0.030 的调整不是保守**：两遍 Poisson 有 `σ·√2` 放大因子，0.040 会 overshoot；0.030 才落在 Apple Portrait 上界。这是**数学推导**，不是"求稳"
3. **D5 被收敛决策覆盖**：原批准的 Pixel Cake / Lightroom 参考线后来被砍，换成内部护栏。**后续决策可以覆盖前序决策**，不是背信
4. **Session D 若质疑任何 Session C 落地**，应先读本节决策 trace，确认是否 "approved 路线 + 数学/业界 delta 合规"，而不是简单改回去

---

## 4. 硬约束（继承自 `.claude/rules/*.md`）

### `commit-verification.md`

每次 `git commit` 前强制 `swift build` + `swift test`（+ `xcodebuild` if Demo 触达）。**无豁免** —— "Demo-only / doc-only / comment-only" 都不能跳过。

### `engineering-judgment.md`

- §1 禁用"激进/保守"作质量判据，改"证据链支持方案 X"
- §2 横切关注点（e.g. color space）一版改不完，准备迭代
- §3 替换算法前问历史（LLF 失败 N 次，guided filter 是 pragmatic trade-off）
- §4 外部来源只引 fetched URL，不引记忆
- §5 perception-based 不是 escape hatch，契约可形式化
- §6 严谨 = 契约 + 算法满足 + trade-off 文档化，不是"理论最优"

### `testing.md`

- §1.4 写断言前必须推导预期值，推导写进注释
- §1.5 identity/极值/方向/数值/契约 五类断言最小模板
- §2.1 测试失败默认"实现错"不是"断言错"
- §2.2 三路对比：A(shader actual) / B(断言里的 expected) / C(重新推导)
- §2.3 禁止不看实现直接改断言方向 / 放宽容差 / 注释掉
- §2.4 具体 case：HS 断言方向错 → 按 §2.2 应改实现不改断言

### `filter-development.md`

新滤镜开发前 4 步：维度分类 → 算法候选清单 → WebSearch 业界参考 → Doc comment 写模型形式理由。**经验拟合是最后手段**。

### `spatial-params.md`

三类参数三种适配方式：视觉纹理 `basePt × pixelsPerPoint` / 图像结构 按纹理维度比例 / 逐像素不适配。

---

## 5. 用户偏好（继承 + Session C 新增）

**继承自 A/B**：
- **严谨 > 快速**，愿意投入时间做彻底严谨化，不要求"快速 ship"
- **不用 Instruments**，performance 测量通过 SDK-internal tooling（Session C 落地 `PipelineBenchmark`，基于 `MTLCommandBuffer.gpuStart/EndTime`）
- 聊天简体中文，代码 + commit + SwiftDoc 英文
- 破坏性变更前明确告知，等用户确认（pre-1.0 期间 breaking 自由，**登记 CHANGELOG.md `[Unreleased]`** 即可）
- 遇到"激进/保守/perception-based 所以没法/肉眼不可见"这类 framing 立刻停下，引规则重写
- **禁止**"Harbeth 继承"作为参数依据 — DCRenderKit 存在意义是不依赖 Harbeth

**Session C 新增的口径/风格偏好**（含用户原话，避免被改写失真）：

- **完美主义 + 优先级** — user 2026-04-23 原话：
  > "你按照'功能，效果，逻辑，验证，代码质量'先行 这个优先级重新排，而且验证和效果最好穿插排，最后再整理边边角角的比如语法，api 这些，我现在要求你立即排一个全量的优先级，我要优先看到正确且严谨的特效实现和足够扎实的基座，而且都按照最难最严格的规格去做，**严禁图省事**，我不是已经持久化了很多原则了吗，**我是个绝对的完美主义，严谨和正确远远大于速度和成本**"
  - **含义**：优先级顺序 `功能 > 效果 > 逻辑 > 验证 > 代码质量 > edge polish`；验证穿插在效果推进里，不是做完一堆再一起测；边边角角（`@available` / warning / docstring）永远最后
- **今日完成期望** — user 2026-04-23 12:12 原话：
  > "不是接下来2-3周，而是我希望你今天就搞定所有的 task，且足够严谨足够完美的完成，**我会一直监督你**"
  - **含义**：不要提"需要 N 周"类多 session 拆分建议；不要每步等批准；user 会主动打断，所以你自主推进即可；但**破坏性行为 / 需要 user 信息（真机 / Pixel Cake / platform decision）的 gate** 必须 surface
- **禁止 session 时长自我 hedging** — user 2026-04-23 12:52 原话抓包："Session 时长已过是什么意思"。**我没有 time limit**，只有 context window / cognitive load。禁说"session 时长到了 / 今天做到这里 / 明天继续"类推脱。
- **"读代码"不能用二手 summary 替代** — user 原话："你才读了代码库 15 个文件吗"。声称"已读完代码库"时必须自己 Read 而非依赖 Explore agent 二手 summary；大规模探索可以用 Explore 做 indexing，但关键文件（filter / shader / 契约 / rules）必须 Read
- **阶段性决策拍板后别再反复 ping-pong** — Session C 中 D1/D3/D5 一次 "全 OK"，后续不再复问；每个 binary decision 给 ≥2 候选 + 明确推荐 + 依据，让 user 一句话决
- **分批 commit**，每 commit 前 build+test；commit message 写 why > what（英文 conventional commits）
- **不主动 push**（需用户明确 "push"）
- **"保留做"和"砍"的指令必须立即 TaskUpdate**，文件清理跟进
- **破坏性变更前明确告知** + **CHANGELOG.md `[Unreleased]` 登记**（pre-1.0 期间 breaking 自由，但每条必须有迁移说明）

---

## 6. 已知 drift / edge case

- **pbxproj 持续脏**：`Examples/DCRDemo/DCRDemo.xcodeproj/project.pbxproj` 是 Xcode IDE 自动编辑，每次打开都变。除非实际改 Demo 代码，**不要 stage**。
- **memory 滞后风险**：`project_dcrenderkit.md` 可能被标记 "N days old" warning。以 `TODO.md` + 本文件 + git log 为准；Session C 末已更新 memory 到当前状态。
- **#37 / #38 / #39 snapshot baseline 被真机评估 gate**：`SnapshotAssertion` framework 完备（first-run 写 baseline + `XCTSkip`，second-run 断言 drift < tolerance），但 **baseline PNG 要在 iOS 真机上你主观确认 filter 效果 OK 后才能 freeze 进 repo**。
- **#75 PortraitBlur 系数 0.030**：Session C 推算的 effective peak radius 1080p=46px / 4K=92px，落在 Apple Portrait 50-100px 区间。若真机"还弱"升到 0.035；若"太猛"降到 0.025。`kDCRPortraitBlurCoef` 旁的 doc comment 已写明调参方向。
- **PortraitBlur 契约未写**：Tier 3 五 filter 都有 `docs/contracts/<name>.md`，PortraitBlur (Tier 4) 当前用 snapshot 代契约。如果你决定给 Tier 4 也写契约文档就加；不是 release blocker。
- **已拍板的决策（不要 revisit）**：
  - DCR 独立于 Harbeth（`Sources/` 已零 Harbeth）
  - iOS-only（macOS 业务层已全删；保留 `.macOS(.v15)` 仅因 macos-15 runner 是能让 Metal 单测真跑 GPU 的 CI 环境）
  - Tier 2 fitted 曲线已换原理派，不要因为 "某 app 效果不一样" 换回 fitted
  - Pixel-level 外部 parity 不做（#11/#18/#19/#20 已删）
  - 性能测试不做硬数字 gate（#41/#42/#43 已删；`PipelineBenchmark` 是 tool not gate）
  - 跨平台不支持（#44/#45/#46 已删）
  - Harbeth diff audit 不做（#50/#51/#52 已删）
  - Demo showcase 不扩（#67 已删）
- **Session A 残留断言错误历史**：`engineering-judgment.md §1` 里有本真案例 "V1→V2→V3 审计 framing 批评"—— 不是 failed review，是 methodology 沉淀。
- **未 push 18 commits 里的破坏性变更**：Contrast / Blacks / Whites / ExposureNeg 曲线形状全部变；PortraitBlur `FilterProtocol → MultiPassFilter`（调用点 `.single` → `.multi`）；Whites 删 `lumaMean:` 参数；macOS 业务路径全删。**push 前建议 DigiCam 真机回归**。
- **Session C 保留做但未完成 artifact**（Session D 第一件事）：
  - #66 Demo→SDK integration test → `Tests/DCRenderKitTests/IntegrationTests/`
  - #70 `docs/maintainer-sop.md` + `SECURITY.md`
  - #69 `docs/discussions-guide.md`
  - `docs/foundation-capability-baseline.md`（约 15 条基座能力 checklist，用于自证"基座 ≥ 任何继承源"）

---

## 7. 下个 session 开场 Prompt（完整版，复制粘贴）

**要求 session 不跳步骤地读完下列全部**。这个 prompt 长是有意的 —— "无缝、无损" 交接的代价就是你必须先完整装载上下文，然后才能做判断。跳读可能引入 session B 犯过的同类错误（Harbeth 继承、谎称 TaskList 丢、凭记忆 claim 业界做法、测试失败改断言）。

```
继续 DCRenderKit 开发 (repo: /Users/xiaosenromangic.com/DevWorkSpace/DCRenderKit/)。

**Phase 1 — 装载上下文（必读，~40 min；跳读视为违规）**

A. 握手 + pending todo (3 分钟)
   A.1 docs/session-handoff.md **全文** （本文件，你现在读的）— 尤其 §0 axioms
        + §3 state snapshot + §5 用户偏好 + §6 drift + §8 踩坑索引
   A.2 TODO.md （repo 根；Session C 重写；当前 ~12 条收尾 + 3 条真机阻塞 + 2 条远期）
   A.3 CHANGELOG.md [Unreleased] （Session B/C 累计 breaking 条目）

B. 硬约束 rules (必读 5 份，10 分钟)
   B.1 .claude/rules/commit-verification.md
       — 每 commit 前 swift build + swift test 无豁免。Demo-only/doc-only/
         comment-only 都不能跳。§4 规则起源有 Session A 具体违规案例
   B.2 .claude/rules/engineering-judgment.md  ← **最关键**
       — §1 禁用 "激进/保守/保险/大胆/肉眼不可见" framing
       — §2 横切关注点一版改不完，准备迭代
       — §3 替换算法前问历史
       — §4 外部来源**只引 fetched URL**，不引记忆
       — §5 perception-based **不是**"不可形式化"的 escape hatch
       — §6 严谨 = 契约 + 算法满足 + trade-off 文档化，不是理论最优
       — §7 规则起源案例清单
   B.3 .claude/rules/testing.md
       — §1.4 断言前必须推导预期值，推导写进注释
       — §2.1 测试失败默认**实现错**不是断言错
       — §2.2 三路对比流程 (A actual / B assertion / C rederive)
       — §2.3 禁止改方向/放宽容差/注释掉失败断言
       — Part 3 Tolerance 错误预算建模
   B.4 .claude/rules/filter-development.md
       — 新 filter 必走 4 步；经验拟合是最后手段
   B.5 .claude/rules/spatial-params.md
       — 3 类空间参数适配策略

C. Plan + Tier 3 契约 (10 分钟)
   C.1 docs/findings-and-plan.md — **注意 §7.3 / §8.4 / §8.5 / §8.6
        均是 ARCHIVED**，内容仍可查但结论已被 Session C 超越；当前状态在本
        handoff §0 axioms + §3 state snapshot
   C.2 docs/contracts/vibrance.md       ← Tier 3 契约 5 份全读
   C.3 docs/contracts/saturation.md
   C.4 docs/contracts/highlight_shadow.md
   C.5 docs/contracts/clarity.md
   C.6 docs/contracts/soft_glow.md
   C.7 docs/release-criteria.md — v0.1.0 三级 GA 定义

D. Session C 新增基础设施 (必读使用文档 / 头部注释，5 分钟)
   D.1 Tests/DCRenderKitTests/SnapshotAssertion.swift 顶部 doc
        — Tier 4 aesthetic filter baseline 怎么 freeze / re-record
   D.2 Sources/DCRenderKit/Statistics/PipelineBenchmark.swift 顶部 doc
        — MTLCommandBuffer.gpuStart/EndTime 测 median / p95 / stddev
   D.3 Sources/DCRenderKit/Shaders/Foundation/SRGBGamma.metal 顶部注释
        + OKLab.metal 顶部注释 — MIRROR 模式约定
   D.4 Tests/DCRenderKitTests/LinearPerceptualParityTests.swift 顶部 doc
        — 5 tone filter × 315 grid-point parity 扫描护栏

E. 踩坑记录 (位置索引，按需查)
   E.1 本 handoff §8 — Session A/B/C 三 session 全部踩坑汇总索引
   E.2 rules/engineering-judgment.md §7 — 方法论反例汇总
        (V1→V2→V3 framing 批评 / LLF 历史 / pseudo-consensus / Clarity 懒惰思考)
   E.3 rules/testing.md §2.4 — HS 断言方向错具体案例
   E.4 rules/commit-verification.md §4 — 3 个 Demo-only 跳 test 案例
   E.5 git log — Session B: cadc1e7 Vib/Sat C.3 gamut 踩坑 / 04aa8bc SoftGlow σ 调参 / fd6cc92 Zone midpoint 发现
                 Session C: 173ff17 PortraitBlur MultiPassFilter 架构扩展 / 5f32b2e Contrast log-slope / d10bbf7 macOS 剥离
   E.6 memory/feedback_commit_verification.md — 规则起源快照

F. 工作流参考 (遇到对应场景时查)
   F.1 新 filter → filter-development.md 4 步 + contracts/*.md 模板
   F.2 测试失败 → testing.md §2.2 三路对比 (A actual / B assertion / C rederive)
   F.3 新契约 → 按 5 份已有 contracts 结构 (§1 Scope / §2 算法 / §3 条款 /
       §4 测试图 / §5 Out of scope / §6 参考 / §7 变更日志)
   F.4 替换 tone curve → 原理派 Tier 0 (Reinhard / DaVinci / Filmic /
       linear gain)；fitted 只作最后手段；breaking change 登记
       CHANGELOG.md [Unreleased]
   F.5 业界 claim → fetched URL 进 contract doc (engineering-judgment §4)
   F.6 破坏性行为变更 → commit message 明写 "Breaking change" 段 +
       CHANGELOG 登记 + 告知用户 DigiCam 端需回归
   F.7 Tier 4 baseline freeze → SnapshotAssertion.assertMatchesBaseline;
       first-run 写入 + XCTSkip，真机 approve 后提交 PNG 到 __Snapshots__/
   F.8 性能验证 → PipelineBenchmark.measureChainTime (不做硬数字 gate)
   F.9 FIXME 必带 (§…) 或 (#…) 引用 — CI lint 会挡住裸 FIXME

**Phase 2 — 接管动作 (4 步)**

1. 迁移 TaskList:
   - 上 session UUID (Session C): 6afb8a49-4085-4fc3-9b37-557b14c24dba
   - 当前 session UUID: 查 ~/.claude/tasks/ 下 mtime 最新（不含上述）
   - 执行:
     mkdir -p ~/.claude/tasks/<current>/
     cp ~/.claude/tasks/6afb8a49-4085-4fc3-9b37-557b14c24dba/*.json \
        ~/.claude/tasks/<current>/
2. 运行 swift build + swift test，确认 **326 pass at HEAD c46ab19**（snapshot anchor 86b90c9 上也是 326 pass，handoff commit 不改 code）
3. 确认 git status: `Examples/DCRDemo/DCRDemo.xcodeproj/project.pbxproj` 可能
   dirty (Xcode 自动编辑，不 stage)
4. 查 TODO.md "Session C 保留做" 三条 + "foundation-capability-baseline"
   为 Session D 的第一批任务

**Phase 3 — 开场问候**

向用户简短回报 (3-4 行):
- 已读 handoff + 5 rules + 5 contracts + release-criteria + Session C 新增
  basic infra docs
- TaskList 已迁移 (X 条 completed / Y 条 pending)
- swift test 326 pass 确认基线 OK (or 若 fail 立即报细节)
- 即将按 Session C 保留指令开始四件 artifact 工作（#66 / #70 / #69 /
  foundation-capability-baseline），确认顺序后动手

**Session C 留给 Session D 的第一批工作（优先级顺序）**

Session C 用户决策"保留做"的 4 件：

1. **#66 Demo→SDK integration test**
   - 放 `Tests/DCRenderKitTests/IntegrationTests/`
   - 覆盖 PortraitBlurMaskGenerator → PortraitBlurFilter 链路
   - 不加 Demo XCTest target（decision 明确）
   - 用 synthetic mask + uniform source 跑 pipeline 断言输出满足契约
     （`additional(0)` mask 正确被消费、strength=0 identity、strength=100
     blurAmount 至少一处非零）

2. **#70 Maintainer SOP + SECURITY.md**
   - 新建 `docs/maintainer-sop.md`：PR review 流程、release cut 流程、
     breaking-change 登记 checklist、security 响应 SLA
   - 新建 repo 根 `SECURITY.md`：漏洞报告方式（邮件 / private issue）、
     支持的版本、修复 SLA

3. **#69 GitHub Discussions 指南**
   - 新建 `docs/discussions-guide.md`
   - 建议分区：Q&A / Show-and-tell / Ideas / General
   - 页面开启由用户自己在 GitHub 侧做（我们只写指南）

4. **基座能力 baseline**
   - 新建 `docs/foundation-capability-baseline.md`
   - ~15 条架构能力 checklist，证明"DCR 基座 ≥ 任何继承源"
     （典型：zero-external-deps / typed Error hierarchy / 16-float
     intermediates / Multi-pass DAG executor / principled tone operators
     / contract-verified Tier 3 / snapshot-regression Tier 4 / linear-
     perceptual parity 护栏 / Swift 6 strict concurrency / …）
   - 用作 release doc 和 marketing truth-claim 底座

完成这 4 件后，继续 TODO.md 上的 Tier 6 API 冻结系列（#47 / #48 / #49 / #59 /
#71 / #72），然后 Tier 7 DocC / Release plumbing（#57 / #58 / #61 / #62 / #63）。
**真机阻塞项（#37 / #38 / #39）** 需要用户参与，不要主动做 freeze。

**硬禁**（任何 session 继承）:
  - "Harbeth 继承" 不是依据 (DCR 独立于 Harbeth)
  - "激进/保守/肉眼不可见/perception-based 所以没法" 是 forbidden framing
  - 引业界做法必须 fetched URL 不引记忆
  - commit 前 swift build + swift test 无豁免
  - 不主动 git push (需用户明确 "push")
  - 测试失败时默认实现错，不盲改断言方向/tolerance
  - 替换算法前问历史
  - 新 filter 必走算法选型 4 步
  - 禁止 **"TaskList 跨 session 丢了"** 这类谎言
  - 不要重新引入 NSImage / AppKit / macOS business API
  - 不要为了"对齐某外部 app"把原理派 tone curve 换回 fitted
  - "Session 时长到了" 这类自我 hedge 禁说 (Session C 中段被 user 抓到)
  - FIXME / TODO 必带 (§…) 或 (#…) 引用，CI lint 会挡

**完成 Phase 1-3 + 前两件 artifact (#66 / #70) 后**向用户汇报一次进度；
用户未打断时继续推进 #69 / foundation-capability-baseline / Tier 6。
```

### 7.1 短版开场（仅用于对项目已熟悉的快速接管）

```
继续 DCRenderKit。先 Read docs/session-handoff.md §7 全部，按 Phase 1-3
装载 + 执行 Session C 留给 D 的 4 件 artifact (#66 / #70 / #69 /
foundation-capability-baseline)，再继续 Tier 6 收尾。
```

但**第一次接管 Session D 建议用完整版**，装载损失一次换终身无损。

---

## 8. 踩坑记录 / 沉淀索引（快速查询）

不重复内容，只列**哪里能查到什么经验**。新 session 遇到对应场景再读。

### 8.1 方法论错误与修正案例

| 场景 | 在哪读 | 教训 |
|---|---|---|
| 用"激进/保守"描述方案 | `engineering-judgment.md §1` + §7 反例 | V1→V2→V3 不是"取中值"，V3 是质变 |
| 凭记忆 claim 业界做法 | `engineering-judgment.md §4, §7` | Session A 多次合成 pseudo-consensus |
| "perception-based 所以不可形式化" | `engineering-judgment.md §5` | 每个 filter 都有可形式化契约 |
| 预估 scope 反复不准 | `engineering-judgment.md §2` | 横切任务（color space）第一版必不完整，这是任务性质不是失败 |
| 替换算法前没问历史 | `engineering-judgment.md §3` | LLF 已尝试 N 次失败，"契约锚当前实现可达边界"而非"换 LLF" |

### 8.2 测试错误模式

| 场景 | 在哪读 | 教训 |
|---|---|---|
| 测试失败立刻改断言 | `testing.md §2.1, §2.3` | 默认实现错不是断言错 |
| 凭直觉写断言方向 | `testing.md §2.4` + HS 案例 | HS 断言第 1 次方向写反 → §2.2 三路对比定位 |
| 凭感觉选 tolerance | `testing.md §1.4` + Part 3 | 必须推导 Float16 量化 + guided filter 噪声 + bilinear 等误差源加起来 |
| 合成 patch 偶然 out-of-gamut 导致 contract 测试失败 | session B `cadc1e7` commit msg | Vib/Sat C.3 用 pure blue 做 high-sat anchor 而非 synthesize |
| Gaussian spread 阈值设得太乐观 | session B `04aa8bc` commit msg | SoftGlow C.4 16px 阈值按数学推导 5·10⁻⁴ 降到 3·10⁻⁴ |

### 8.3 Commit 流程错误

| 场景 | 在哪读 | 教训 |
|---|---|---|
| Demo-only commit 跳 swift test | `commit-verification.md §4` + `feedback_commit_verification.md` | Session A 三个 11bf7fa/89ad969/f1837cc 违规 → user 揪出 → 立规 |

### 8.4 Session B 特有发现

| 发现 | 在哪读 | 价值 |
|---|---|---|
| HS smoothstep 窗口 = Koren Zone midpoints | `docs/contracts/highlight_shadow.md` §2 + commit `fd6cc92` | 4 个端点精确匹配 <0.005，硬依据 unlock |
| DCR SoftGlow **不是** Dual Kawase | `docs/contracts/soft_glow.md` §1 + commit `56f447d` | 之前 claim 错了，更正为 "pyramid bloom 族变体" |
| Clarity "perceptually-linear slider" claim 无证据 | `ClarityFilter.metal` (已删) + commit `e28bb76` | B.1 查 Weber-Fechner 给不出系数 → fabricated claim 移除 |
| Saturation `s=0` breaking change | commit `05f8463` | Rec.709 Y gray → OKLab L gray，DigiCam 侧需真机回归 |
| Vibrance 语义破坏性变更 | commit `e635cb5` | GPUImage max-anchor → Adobe 语义 OKLCh selective + skin protect |

### 8.4.C Session C 特有发现

#### 8.4.C.1 — 决策 / 架构层发现

| 发现 / 决策 | 在哪读 | 价值 |
|---|---|---|
| #74 typed Error enum 早已完成 (TODO 过期) | `PipelineError.swift` + commit `8268686` | 读代码比读 TODO 靠谱 — 二手 summary (subagent) 不能替代自己读代码 |
| `MultiPassFilter` 无法接 external mask | `MultiPassFilter.swift: PassInput.additional(Int) + additionalInputs` + commit `173ff17` | SDK 架构扩展合法途径，不是 hack |
| Session C 收敛决策把 44 pending 砍到 ~12 | 本 handoff §3.X + TODO.md rewrite | **方案 A: iOS-only (保留 .macOS(.v15) test host)** + 删 Harbeth diff / pixel parity / 性能 gate / 跨平台 — 大尺度 "砍" 决策比 "做" 决策更能收敛 session |
| `ARCHIVED (...)` banner 是 findings-and-plan 的正确处理方式 | commit `86b90c9` | 不删内容，加横幅标"内容已被后续取代但保留作为决策历史" |
| D1 "全 OK" 批准后 Blacks/Whites/Exposure 的实施 delta | 本 handoff §3.X 决策 trace | approved 路线 + 业界/数学验证修正 = 合规；不是偏离 approved |
| Handoff paradox | 本 handoff §0 + §3 | handoff commit 自身会让 HEAD 前进 1 步 — snapshot anchor 永远比 runtime HEAD 早 1 commit，不可避免 |

#### 8.4.C.2 — 测试 / 实施踩坑

| 场景 | 在哪读 | 教训 |
|---|---|---|
| Contrast 换 DaVinci log-slope 后 slider+100 在 pivot 以上立刻 clamp | `ToneAdjustmentFilterTests.swift:testContrastPositiveFullSliderBrightensAbovePivot` + commit `5f32b2e` | 单点测试要选在 gamut 内验证 **shape** 而非 clamp；原 test x=0.7 被 clamp 1.0 丢 shape 信息 → 改 x=0.6 |
| 新 Contrast lumaMean 是 pipeline-space-dependent | `LinearPerceptualParityTests.testContrastLinearPerceptualParitySweep` | parity test 传 lumaMean=0.5 给 linear mode 必须 `gammaToLinear(0.5)` 转换，否则 43 个 test failure 是假象（drift 是 0.5 → 0.214 的 color-space 不一致） |
| PortraitBlur Swift ×0.5 二次压缩让 shader 注释峰值失效 | commit `173ff17` | "注释声称 27px 但实际 13.5px" 是真 bug；两遍 Poisson + 移除 Swift ×0.5 + shader 系数 0.025→0.030 = 最终 46/92 px |
| PortraitBlur 类型 migration `.single` → `.multi` | `SmokeTests.swift` + `PortraitBlurAndStatisticsTests.swift` + commit `173ff17` | 架构从 `FilterProtocol` 改 `MultiPassFilter` 后**所有调用点必须迁移**，`runSingle → runMulti` 改名一次 |
| Whites `lumaMean:` 删参触发全 call site migration | commit `7760a0c` + 相关 test 更新 | Filmic shoulder 不需要 scene-adaptive pivot → 参数删除 → test 里 `init(whites:lumaMean:)` → `init(whites:)`；同时删 `testWhitesLUTInterpolationEdgeClamp`（LUT 架构已移除） |
| `PackageManifestTests` 首跑 skip | commit `00e38d9` | Swift 6 里 `#file` 解析为 `#fileID`（module-relative 路径），`URL(fileURLWithPath:)` 找不到文件 → 改 `#filePath` 解决 |
| Parity sweep Contrast 43 个 fail | commit `6256d9a` | 两个 color-space mode 传同一 `lumaMean=0.5` 但 pipeline-space 不同，必须各自 `gammaToLinear(0.5)` 转换 |
| `PassGraphVisualizer` exhaustive switch 漏 case | commit `173ff17` 修 `PassInput.additional(Int)` 新 case | 新 enum case 必须遍历所有 switch；Swift 6 默认开 exhaustive |
| `SourceKit IDE 错报` 误导 | (本 session 反复出现) | SourceKit 诊断 "Cannot find type X" 是 workspace 索引错（打开的是 wayshot repo 不是 DCR）；**以 swift build 为权威**，忽略 SourceKit |

#### 8.4.C.3 — 行为 / 交互错误

| 错误 | User 原话 | 教训 |
|---|---|---|
| "Session 时长已过" 自我 hedge | "时长已过是什么意思" | 我没有 time limit 只有 context window / cognitive load，**禁说** "时长到了 / 今天做到这里 / 明天继续" |
| 声称读完代码库但只读 15 个文件 | "你才读了代码库 15 个文件吗" | 关键文件（filter / shader / 契约 / rules）必须自己 Read 而非依赖 Explore agent 二手 summary |
| 提"接下来 2-3 周"计划 | "不是接下来 2-3 周，而是我希望你今天就搞定所有的 task" | 不要跨 session 拆分；当日完成是隐含期望，除非是真的物理阻塞（真机 / 用户动作） |
| 凭记忆 claim 业界做法（继承自 A/B） | `engineering-judgment.md §4, §7` | 外部 claim 必须 fetched URL；禁 synthesize "pseudo-consensus" |

### 8.5 典型工作流（参考上次实战路径）

- **Tier 3 闭环**（5 filter 通用流程）：WebSearch 文献 → 写契约 md → 写 contract tests → 跑 → §2.2 修复失败 → commit
  - 真实案例：session B commit 链 `ab2b932` → `1cce611` → `05f8463/e635cb5` → `cadc1e7`
- **参数依据补**（B 系列流程）：WebSearch → 分类（硬依据/可防御/tech debt）→ contract doc 更新 + shader comment 同步去除 fabricated claim
  - 真实案例：session B commit `e28bb76` + `fd6cc92`
- **Industry audit**（§8.4 通用流程）：WebSearch ≥ 2 源 → 对照 DCR 实现 → contract doc §"业界对照" 表 + fetched URL
  - 真实案例：session B commit `56f447d`
- **Session 结束 handoff**（本 session 立规）：
  1. 更新 TODO.md 分类列表
  2. 更新 session-handoff.md §3 + §6
  3. 刷新 memory/project_dcrenderkit.md
  4. 最后 commit 含这 3 个文件，message: `docs(handoff): Session X end snapshot`

---

## 9. 如何维护本文件

**每个 session 结束前**（切 session 或 /clear 前）:

1. 更新本文件 §3 "当前 state snapshot"（HEAD、ahead count、test count、completed 项）
2. 更新 `TODO.md`（pending 任务如有 update）
3. 视情况刷新 memory `project_dcrenderkit.md`
4. 若有新硬约束 → 新增 `.claude/rules/xxx.md`
5. 最后一个 commit 应该包含这 3 个文件的更新，commit message 形如 `docs(handoff): Session X end snapshot`

新建 hard rule 的门槛：必须是**通用 methodology**（适用多 session、多 filter），不是单次 tactical 事情。
