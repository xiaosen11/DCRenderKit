# DCRenderKit Session Handoff

**目的**: 让任何一个新 Claude Code session 能在 5 分钟内接管上一个 session 的全部上下文，零信息丢失。本文是每次 session 结束前必须更新的握手状态。

**最后更新**: 2026-04-23，Session B 结束

---

## 0. 最重要的事（如果只读一段）

- Repo: `/Users/xiaosenromangic.com/DevWorkSpace/DCRenderKit/`
- 当前分支 `main`，`HEAD = 9b3aa50`，62 commits ahead of `origin/main`（**未 push**，禁止自动 push）
- 299 tests pass，0 warnings
- **权威 pending todo** 在 repo 根 `TODO.md`。**不要**声称 TaskList 丢了 —— 见 §1。
- 硬约束 5 份 `.claude/rules/*.md` 必读 —— 见 §4。
- 已有的 Tier 3 五 filter 完整闭环（Saturation/Vibrance/HighlightShadow/Clarity/SoftGlow 契约 + 验证 + 算法依据 + 参数依据），**不要推倒重做**。

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
| B (结束于 2026-04-23) | `5d660bae-cb61-4c43-b626-12c921a9ac53` | `9b3aa50` |
| A (结束于 2026-04-22) | `1ece456e-1d62-4dea-91d2-137f310c2a3a` | `2e5df4c` |
| 更早 | `67404015-6221-4bc5-bf0a-217ab8cedbf8` | — |

### 诚实记录：Session B 初时犯的错

我上一次接 Session A 时，先查 `TaskList` 看到空，然后**谎称**"跨 session 不保留"—— 这是**错的**。实际只是新 session 的 task 目录未创建 / 未迁移。**绝不要再犯这个错**。新 session 的第一个 action 应是：查上一个 session 的 task 目录存在与否、迁移。如果仍有问题，读 `TODO.md`（repo 根）也能立刻拿到 pending 列表。

---

## 2. 文档全景图（5 分钟知道看什么）

### Repo 根（新 session 先看这里）

- **`TODO.md`** ← 权威 pending todo，分类清单，人类可读
- **`docs/session-handoff.md`** ← 本文件
- `README.md` / `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` / `LICENSE` — 常规开源基础
- `Package.swift` — iOS 18+ / macOS 15+ / Swift 6 strict concurrency / 零外部依赖
- `CLAUDE.md` — 项目级 Claude 指令

### `docs/`（审计 + 契约）

- **`docs/findings-and-plan.md`** ← 权威 plan，§8 是当前审计状态（§8.1/§8.2/§8.3/§8.4 均 ✓，§8.5 B.1 pending user，§8.6 签 no，§8.7 纯文档 wording，§8.10 Phase 2+ 未来）
- **`docs/contracts/*.md`** ← 5 份 Tier 3 filter 契约（vibrance / saturation / highlight_shadow / clarity / soft_glow）。每份 6-7 条可测条款，每条款写了测法 + 依据 fetched URL

### `.claude/rules/*.md`（5 份硬约束，必读）

见 §4 详列。

### `.claude/agents/*.md`（未触达的 sub-agent 配置）

用户未启用，跳过。

### memory 自动加载

`~/.claude/projects/-Users-xiaosenromangic-com-DevWorkSpace-wayshot-pm-agent-Digi-Cam/memory/MEMORY.md` 是索引，加载完整文件 `project_dcrenderkit.md`、`user_preferences.md`、`feedback_commit_verification.md`。**新 session 会自动看到**，但里面记录的状态可能滞后，以 `TODO.md` + git log + 本文件为准。

---

## 3. 当前 state snapshot（2026-04-23 Session B 结束）

### Git

- 分支: `main`
- HEAD: `9b3aa50`
- Commits ahead of origin/main: 62（**未 push**）
- Working tree: `Examples/DCRDemo/DCRDemo.xcodeproj/project.pbxproj` **持续脏**，属 Xcode IDE 自动编辑（`LastUpgradeCheck` + `DEVELOPMENT_TEAM` 位置漂移等），**不要 stage**，除非实际改了 Demo 代码

### 测试

- 299 tests pass / 0 warnings / 0 regressions
- 契约测试在 `Tests/DCRenderKitTests/Contracts/`：
  - `ContractTestHelpers.swift`（共享 helpers + OKLab Swift mirror + ColorChecker constants + zone Y + texture builders）
  - `VibranceContractTests.swift`（7 tests）
  - `SaturationContractTests.swift`（7 tests）
  - `HighlightShadowContractTests.swift`（8 tests，HS C.2 拆 2 条）
  - `ClarityContractTests.swift`（7 tests）
  - `SoftGlowContractTests.swift`（6 tests）
  - 总计 35 contract tests + 13 OKLabConversion + 2 新 Vibrance + 先前 249 = 299

### Filter 状态（Tier 分类）

| Tier | Filters | 验证方式 | 状态 |
|---|---|---|---|
| 1（formula is spec） | Sharpen, Normal Blend, LUT3D, Exposure+ | unit test（已有） | ✓ 维护 |
| 2（fitted MSE） | Contrast, Blacks, Whites, Exposure-, WhiteBalance | Tier 2 SSIM spot-check（§8.6 C）— **user signed no，改 snapshot 路径** | pending |
| 3（perception-based） | Saturation, Vibrance, HighlightShadow, Clarity, SoftGlow | 契约 C.1-C.x **全部闭环** | ✓ |
| 4（aesthetic） | FilmGrain, CCD, PortraitBlur | snapshot regression（#36-39） | 待做 |

### Session B 完成项（commit hash 索引）

- `ab2b932` — Vibrance + Saturation 契约 spec
- `1cce611` — OKLab helper metal + 13 tests
- `05f8463` — Saturation OKLCh 重构（breaking change: s=0 anchor Rec.709 → OKLab L）
- `e635cb5` — Vibrance Adobe OKLCh 重构（breaking change: max-anchor → selective+skin protect）
- `cadc1e7` — Vibrance + Saturation 契约验证（14 tests）
- `4c65482` — HS 契约 spec
- `f08d417` — Clarity + SoftGlow 契约 spec
- `04aa8bc` — HS + SoftGlow + Clarity 契约验证（21 tests）
- `56f447d` — §8.4 Audit.1/2/5 industry 校准（fetched URL 补 SoftGlow/Clarity/HS 算法依据）
- `e28bb76` — B 系列参数推导（ε / pyramid anchor / Weber-Fechner）
- `fd6cc92` — B.4 本质参数硬依据（HS smoothstep = Zone midpoints 精确匹配；guided radius 论文范围内）
- `9b3aa50` — §8.4 Audit.6/7 收尾（FilmGrain sin-trick + Tone curve families）

### 未 push 的含义

62 commits 包括 Saturation + Vibrance 的**破坏性行为变更**（s=0 灰点 / vibrance skin protect）。push 前建议：
- DigiCam 端回归测试（真机跑一遍 Saturation + Vibrance slider 体验）
- 确认无意外 regression

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

## 5. 用户偏好（继承）

- **严谨 > 快速**，愿意投入时间做彻底严谨化，不要求"快速 ship"
- **不用 Instruments**，performance 测量通过 SDK-internal tooling (PipelineProfiler)
- 聊天简体中文，代码 + commit + SwiftDoc 英文
- 破坏性变更前明确告知，等用户确认
- 遇到"激进/保守/perception-based 所以没法/肉眼不可见"这类 framing 立刻停下，引规则重写
- **禁止**"Harbeth 继承"作为参数依据 —— DCRenderKit 存在意义是不依赖 Harbeth（2026-04-23 user 明确）

---

## 6. 已知 drift / edge case

- **pbxproj 持续脏**：`Examples/DCRDemo/DCRDemo.xcodeproj/project.pbxproj` 是 Xcode IDE 自动编辑，每次打开都变。除非实际改 Demo 代码，**不要 stage**。
- **memory 滞后风险**：`project_dcrenderkit.md` 会被标记 "5 days old" warning，要以 `TODO.md` + 本文件 + git log 为准，memory 是参考。
- **§8.5 B 用户决策 pending**：
  - B.1 Tier 3 纯拟合替换（Contrast/Blacks/Whites/Exposure-/WhiteBalance）
  - B.2 EV_RANGE=4.25 vs 业界 ±5
  - B.3 Saturation/Vibrance linear 下微偏
  - B.4 parity 测试 tolerance 0.05→0.02
  - B.5 §8.4 若发现 2+ 编，全量重审 7 个 —— 已做完，结果"没人编，都真"
- **#75 PortraitBlur slider +100 过弱**：真机反馈记录，待做。
- **#39 snapshot blocked by #75**：修好 PortraitBlur 才能 snapshot。
- **Session A 残留断言错误历史**：`engineering-judgment.md §1` 里有本真案例，"V1→V2→V3 审计 framing 批评"—— 不是 failed review，是 methodology 沉淀。

---

## 7. 下个 session 开场 Prompt（复制粘贴版）

```
继续 DCRenderKit 开发。强制先做以下 5 步再任何 action：

1. Read /Users/xiaosenromangic.com/DevWorkSpace/DCRenderKit/docs/session-handoff.md 全文
2. Read /Users/xiaosenromangic.com/DevWorkSpace/DCRenderKit/TODO.md
3. Read 5 份 .claude/rules/*.md（commit-verification / engineering-judgment / testing /
   filter-development / spatial-params）
4. 迁移上 session 的 TaskList:
   - 上 session UUID: 5d660bae-cb61-4c43-b626-12c921a9ac53
   - 当前 session UUID: 你自己的（查 ~/.claude/tasks/ 下最新目录）
   - 执行: mkdir -p ~/.claude/tasks/<current>/ &&
     cp ~/.claude/tasks/5d660bae-cb61-4c43-b626-12c921a9ac53/*.json ~/.claude/tasks/<current>/
5. 跑 swift test 确认基线（应该是 299 tests pass at commit 9b3aa50）

完成这 5 步后，回报：
- 你看到 commit ahead count / HEAD / test count
- 3 个候选方向（P1 Harbeth diff / P2 Performance / P3 必定改代码 4 条打包）
- 你倾向哪条 + 为什么

等我 pick 方向再动第一行代码。不要直接猜下一步。

硬禁：
- "Harbeth 继承"不是依据
- "激进/保守/肉眼不可见/perception-based 所以没法"是 forbidden framing
- 引业界做法必须 fetched URL
- commit 前 swift build + swift test 无豁免
- 不主动 git push
```

---

## 8. 如何维护本文件

**每个 session 结束前**（切 session 或 /clear 前）:

1. 更新本文件 §3 "当前 state snapshot"（HEAD、ahead count、test count、completed 项）
2. 更新 `TODO.md`（pending 任务如有 update）
3. 视情况刷新 memory `project_dcrenderkit.md`
4. 若有新硬约束 → 新增 `.claude/rules/xxx.md`
5. 最后一个 commit 应该包含这 3 个文件的更新，commit message 形如 `docs(handoff): Session X end snapshot`

新建 hard rule 的门槛：必须是**通用 methodology**（适用多 session、多 filter），不是单次 tactical 事情。
