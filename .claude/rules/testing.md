# 测试规则

单元测试的唯一目的是**抓 bug**。写不出能抓 bug 的测试 = 测试毫无意义，
只是浪费 CI 时间。这份规则分两部分：

- **Part 1**：写测试前的设计原则
- **Part 2**：测试失败时的 mindset 与禁区

---

## Part 1：测试设计原则（写之前）

### §1.1 覆盖 SDK 契约，不止覆盖 filter 行为

SDK 每个 public API 的行为承诺（文档里写明的性质）**必须有独立测试绑定**。
不能假设"filter 测试通过了 → 契约就成立了"。

**反例**（就是被用户真机抓出来的 P0 bug）：

`Pipeline.intermediatePixelFormat` 文档承诺默认 `rgba16Float` 避免 8-bit
banding。但整个测试套件没任何测试问过："设置这个参数后，多 pass filter
的中间纹理格式真的是这个值吗？" → 契约被 `executeMultiPass` 静默违反
数月，靠用户真机暴露。

**正确做法**：每次添加 public API 声明 / 修改行为承诺时，必须**同步**
加一个契约测试。契约测试的特征：

- 直接读取 SDK 内部的可观测状态（如 `output.pixelFormat`）
- 断言这个状态**匹配 API 承诺**
- 不关心 filter 的业务语义（那是 filter 测试的事）

### §1.2 Source 数据覆盖条件轴，不是单一 happy path

测试的 source 纹理 / 输入数据必须覆盖**生产路径上每一种实际出现的组合**，
包括：

- **格式轴**：`bgra8Unorm`（相机）vs `rgba16Float`（内部）vs
  `bgra8Unorm_srgb`（可选）
- **分辨率轴**：小（单元测试性能）+ 真实量级（1080p / 4K）
- **动态范围轴**：uniform patch / gradient / 高对比度 edge
- **来源轴**：手工纹理 / MTKTextureLoader / CVMetalTextureCache（相机路径）

**反例**：SDK 所有 filter 端到端测试的 source 都是 `rgba16Float`
uniform patch。相机 `bgra8Unorm` 路径没覆盖 → 一个跨层 bug 藏了 12 个
Round。

**正确做法**：每新增一个端到端测试，问自己——

1. 这个 source 的格式在生产中会遇到吗？
2. 如果 SDK 有不同 source 格式的代码路径（如 `if source.pixelFormat == X`），
   每条路径都有独立测试吗？
3. 极端场景（高动态范围、HDR > 1.0、sub-pixel gradient）在 source 里
   体现了吗？

### §1.3 断言必须"方向 + 数值 + 精度"三要素，不能只测"活着"

**禁止**的断言类型（抓不到 bug）：

```swift
// ❌ 只测"活着" — output 原封不动都能过
XCTAssertTrue(pixel.r.isFinite)
XCTAssertGreaterThanOrEqual(pixel.r, 0)
XCTAssertLessThanOrEqual(pixel.r, 1)
```

这类断言在精度 bug（8-bit 截断）、identity bug（filter 没生效）、
方向 bug（highlights 反向）下**全部通过**。

**合格**的断言必须包含：

- **方向性**：positive 参数让 output 变亮还是变暗？必须有断言验证方向
- **数值**：预期值是多少？基于什么公式 / 公认 reference 推导出来
- **精度容限**：容差是多少？为什么选这个值？

```swift
// ✅ 方向 + 数值 + 容限
// HS kernel: ratio = 1 + highlights·h_weight·0.35
// baseLuma=0.7 → h_weight ≈ 0.844 → ratio ≈ 1.295
// → output ≈ 0.7 × 1.295 ≈ 0.907
XCTAssertEqual(pixel.r, 0.907, accuracy: 0.03)
```

### §1.4 写断言前必须先推导预期值，推导过程写进注释

这是最重要的一条。每个非 trivial 的断言写之前，必须先做：

1. **读实现 / 读公式 / 读 reference** 搞清楚"正确行为应该是什么"
2. **手工推导**预期值（shader 公式代入、reference 查表、数学推导）
3. **把推导过程写进注释**，让未来读者能复查

**禁止**：没推导就凭直觉写断言。这会导致测试失败时你自己都不知道
"正确的值应该是什么"，于是只能乱改。

**示例注释模板**：

```swift
// Derivation:
//   - Kernel formula: ratio = 1 + h·w·0.35 (HighlightShadowFilter.metal:86)
//   - baseLuma = guided filter output ≈ 0.7 (uniform patch input)
//   - h_weight = smoothstep((0.7-0.25)/0.6)² × (3 - 2×0.75) ≈ 0.844
//   - ratio = 1 + 1.0 × 0.844 × 0.35 ≈ 1.295
//   - output.r = 0.7 × 1.295 ≈ 0.907 (before satFactor, which is ~1.0 for ratio near 1)
// Tolerance ±0.03 covers satFactor adjustment + half-precision rounding.
```

### §1.5 Identity 测试 + 极值测试 + 契约测试的最小模板

每个新 filter 最小测试集：

| 类别 | 问什么 | 示例 |
|------|--------|------|
| Identity | 零参数 output === input？ | `f(x, 0, 0).r === x.r` |
| 极值不崩 | ±100 下 output 有限在 gamut？ | `f(x, 100).r ∈ [0, 1]` |
| **方向性** | 正参数让 output 变亮 / 变暗？ | `f(x, +100).r > x.r` |
| **数值** | 某典型输入下 output 和公式吻合？ | `f(0.7, +100) ≈ 0.907 ± 0.03` |
| **契约** | SDK 承诺的格式 / 状态匹配？ | `output.pixelFormat == .rgba16Float` |

前两项是已有规范，**后三项是这条规则新增**。

---

## Part 2：测试失败时的 mindset

### §2.1 默认假设：实现错了，不是断言错了

测试失败时，你的**第一反应**应该是：

> 实现可能有 bug，让我先去看看它实际输出了什么。

**不是**：

> 这个数看起来有点不对，我把断言放宽点 / 方向翻一下。

这是一个非常顽固的反直觉 mindset：当人刚写完实现、紧接着跑测试失败时，
潜意识会倾向于"测试写错了"，因为：

1. 实现是"劳动成果"，改实现成本心理上更高
2. 改断言 1 行，改实现 N 行，走阻力最小
3. 失败信息触达意识是"断言不匹配"，表层上看起来像断言的问题

**这是反科学方法的。** 正确的 mindset 是：

> 测试断言代表"正确行为应该是什么"，实现代表"目前产出什么"。
> 两者不一致时，默认认定实现错（因为"正确行为"是从 first principles
> 推导的，而实现是刚写的人类代码）。

### §2.2 测试失败的正确排查流程（强制）

**禁止跳步骤**。失败后必须按顺序走：

**第 1 步：读实现的实际输出**

把 `print` / `XCTAssertEqual` 的 actual 值打出来，记下来。

**第 2 步：重新做一遍 first-principles 推导**

回到你写断言时的推导过程（§1.4 要求写在注释里）。重新代入公式算一遍
expected 值。这次不是凭记忆，是完整重推。

**第 3 步：三路对比**

| | 值 | 含义 |
|---|---|---|
| A | 实现实际输出 | actual |
| B | 你断言里写的预期值 | assertion-expected |
| C | 重新推导出的预期值 | re-derived |

**第 4 步：分情况处理**

| 情况 | 诊断 | 行动 |
|------|------|------|
| A ≠ C，B = C | **实现错了** | 改实现 |
| A ≠ C，B ≠ C，A = B 偶然 | **实现和推导都可能错，先独立验证推导** | 去 reference（论文 / 竞品 / shader 公式）交叉对比 C，确认 C 正确后改实现 |
| A = C，B ≠ C | **断言公式推导错了**（推导错，不是数值错） | 在注释里写明推导错在哪，改断言 |
| A = B ≠ C | **推导错了** | 同上 |

### §2.3 绝对禁止的反模式

以下行为**任何情况都不允许**，一律视为测试舞弊：

1. **不看实现直接改断言方向**（"好像应该反过来，改成 >"）
2. **不看实现直接放宽容差**（"差得有点多，accuracy 从 0.01 改成 0.1"）
3. **不看实现直接注释掉失败的断言**（"先注释，回头再看"）
4. **用范围宽到无意义的断言代替精确断言**（`0 < x < 1` 代替
   `x ≈ 0.907 ± 0.03`）
5. **删除一个失败的测试然后写个更宽松的新测试冒充**
6. **把 XCTAssertEqual(x, y, accuracy) 改成 XCTAssertTrue(x.isFinite)**

**自查**：如果你正在改一个测试断言，回答：

- 我改之前**读过**实现对应的代码了吗？
- 我重新**推导**了一遍预期值吗？
- 我把推导写进了**注释**让别人能复查吗？
- 如果这三问任一答"没"，**停下来，回到 §2.2 第 1 步**。

### §2.4 实际案例：HighlightShadow 断言方向错误（2026-04-17 P0）

**场景**：写 `testHighlightShadowPositiveEffectiveOnBgra8UnormSource`，
测试 `HS(+100, 0)` 在 0.9 uniform patch 上的输出。

**错误 workflow**：

1. 凭"positive recovers highlights = 变暗"直觉写 `XCTAssertLessThan(r, 0.88)`
2. 测试失败：actual r = 1.0
3. **错误反应**：想直接把断言改成 `>0.92` 或放宽（幸好被打住了）

**正确 workflow**：

1. 读 `HighlightShadowFilter.metal:86`:
   ```metal
   ratio = 1.0f + highlights * h_weight * 0.35f
   ```
2. 代入：highlights=+1, h_weight=1（0.9 baseLuma 完全在 window 顶），
   ratio = 1.35
3. apply kernel：`result = orig * ratio` = 0.9 * 1.35 = 1.215 → clamp 1.0
4. **推导结论**：0.9 输入 + HS(+100) → output = 1.0（碰到 clamp）
5. 改测试：换成 0.7 输入避开 clamp，重新推导 output ≈ 0.907
6. 断言：`XCTAssertGreaterThan(r, 0.82)` + 注释写清推导

**教训**：第 1 次写断言就该先读 kernel。凭"文档里 recovers highlights
一词"的语义联想直觉是完全不可靠的——要信代码公式，不信文档措辞。

---

## 适用范围

- ✅ 所有新增单元测试
- ✅ 所有修改已有断言的场景
- ✅ 所有"测试失败 → 查错"的流程
- ⚠️ 性能 benchmark 类测试容差相对宽松可接受，但仍须有数值预期
