# 工程判断规则

补充 `testing.md` 的 meta 层：**如何 reason 关于技术方案**（不只是怎么测试
方案）。这些规则来自 2026-04-22 session 中发现的几条反模式。

---

## §1 禁止用"激进/保守"作为质量判据

"激进"和"保守"是**过程形容词**，描述的是"愿意做多大改动 / 愿意承担多少
风险"，**不**描述方案是否正确。技术方案的 spectrum 是"证据链支持" vs
"尚未验证"，不是"aggressive ↔ conservative"。

### 禁用 framing
- "先保守一点做小的改动"
- "过度激进了"
- "激进度没调对"

### 必须用的 framing
- "证据链支持方案 X，理由 Y"
- "信息不足，需要 Z 证据才能判断"
- "当前假设是 W，下一个观察会证伪它"

### 本 session 反例
.linear 审计迭代 3 版：V1 "16 filter 不动" → V2 "11 个都有漂移" → V3
"光学类 OK / 阈值类必修"。如果 label "V1 太保守 → V2 过度激进 → V3
平衡"就是 framing 错误。V3 是**质变**（找到正确机制），不是"取中值"。

---

## §2 横切关注点的改动一定要迭代

Color space 是 cross-cutting concern。无论上前分析多细，**第一版必然
不完整**。正确流程：

1. 最小可验证版本
2. 真机/用户反馈暴露下一层隐性假设
3. 反证和判据修正
4. 重复到反馈和判据自洽

"一次性估准工作量" 对这类任务**不是技能，是幻想**。P4 启动我预估 ~60 行，
实际做到 10+ 个 commit、多次返工。**这不是执行失败，是任务性质**。

---

## §3 替换算法前问历史

建议替换任何 filter 的算法前，必须问用户：

1. 这个选择有历史吗？
2. 考察过什么替代方案？为什么放弃？
3. 当前版本是"本来就想这样"还是"只能这样"？

**"只能这样"的情况** → 契约应锚**当前实现可达成的边界** + 文档化替代
失败原因，**不重写**。

### 本 session 反例
Local Laplacian Filter 曾尝试 N 次失败（remapping 连续性、金字塔 blend
等 blocker 未解决）→ Guided filter 是可接受的工程 trade-off。我原本
A++ 默认的"契约 fail → 换 LLF"是机械思路，正确是"测 guided 实际 halo
边界 + 文档化 LLF 考察失败"。

---

## §4 外部来源只引 fetched URL，不引记忆

LLM（包括我和过去的 Claude）可以用自信语气合成 pseudo-consensus。"业界
通用做法" "肉眼不可见" 是**不可证伪的垫底话术**。过去 Claude Code 推荐的
"行业标准"可能是 (a) 真引了主流 (b) 编的。

### 硬约束
- 用 WebSearch/WebFetch 取实际来源
- 引用只用 fetch 下来的 URL / DOI，**不用"我记得某论文说"**
- 多来源交叉：一致 → 可信；分歧 → 记录多观点
- 承认边界：闭源竞品实现不可见，只能用开源可观察近似

### 本 session 源头
用户指出 SoftGlow/Clarity/Vibrance/CCD 的"业界通用做法"claim 是过去
Claude Code 推荐的，不保证 100% 真。需要独立重新调研。

---

## §5 Perception-based effects 依然可形式化

用户最终视觉评估 ≠ 需求数学上不可定义。**每个 filter 都有可形式化的
行为契约**。

### 契约示例
- HighlightShadow: halo-free Δ% / Zone 系统 zone targeting /
  perceptually-linear slider (Weber-Fechner) / midtone 稳定性
- Clarity: spectral band 选择性 / edge preservation / dynamic range
  preservation
- SoftGlow: physical additivity / threshold-gated energy conservation

契约**可测量** → 测试脚本验证 → 否则是自己偷懒。**"perception-based"
不是"不可形式化"的合法理由**。

### 本 session 反例
我原本把"Clarity 层次感是主观的"当 escape hatch 说 Tier D "本质上限"，
用户正确指出这是**懒惰思考**。

---

## §6 严谨 ≠ 理论最优算法

严谨是：

1. **契约描述实际要达到的行为**（不是"理论上最好的效果"）
2. **选算法满足契约**（可能是 pragmatic 而非 optimal）
3. **文档化 trade-off 和替代方案考察结果**

**正确表述**：
> "我们选 X 因为在约束 Y 下能达成契约 Z；替代 W 考察结果为 V（因为原因
> U 未解决）"

**错误表述**：
> "我们选 X 因为它是最好的/原理派/业界通用"（没证据链）

---

## §7 本 session 汇总（可追溯）

所有规则都从具体教训中提炼出，见 2026-04-22 session 对话：

- §1: V1→V2→V3 审计 framing 批评
- §2: P4 scope 反复预估不准
- §3: LLF 历史提醒
- §4: "业界通用做法" 可能是 Claude 合成
- §5: Clarity "perception-based 不可形式化" 懒惰被指
- §6: 从上述综合推出

**未来触发条件**：任何时候用 "激进/保守/保险/大胆/保守估计" 形容技术
方案、用 "肉眼不可见/基本可接受/差别不大" 做不可证伪的垫底、说
"perception-based 所以没法"—— **停下，引此规则重写 framing**。
