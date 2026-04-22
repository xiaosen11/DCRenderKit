# Commit 验证流程

每次 `git commit` 前**强制**跑完一套最小验证。跳步骤的 commit 视为违规；
哪怕 "看起来只是改注释 / 改 doc / 改 Demo" 也不例外。

---

## §1 最小验证清单

每次 commit 前跑：

1. **`swift build`** — SDK 编译零 warning
2. **`swift test`** — SDK 单测 + smoke test 全绿
3. **若改动触达 Demo**：`xcodebuild -project Examples/DCRDemo/DCRDemo.xcodeproj -scheme DCRDemo -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug build` 零 error

三项全过 = 才允许 `git add` + `git commit`。

---

## §2 为什么 `swift test` 是硬约束，即使 commit 看起来只改 Demo

"Demo-only 改动不影响 SDK" 是**推论不是证据**，按 `engineering-judgment.md §4`
不接受作为跳过验证的 reasoning。反例：

- Demo 依赖某 public API 的 implicit 行为；debug 中发现需要改 SDK；来回几次
  后已经动了 SDK 文件但忘记跑 test
- SDK 的 static var default 被 Demo 观察；改 default 看起来 Demo 改动，实际
  影响所有 SDK 内部测试依赖该 default 的断言
- xcodebuild Demo 过了但 Demo 依赖的 SDK public API 行为其实变了，只是没触发
  Demo 当前执行路径

每个 commit 一次 `swift test`，没有豁免。跑一次 0.5 秒，零开销。

---

## §3 Demo 改动的测试 gap（必须承认）

Demo 不在 SDK SwiftPM 的 test target 里。`swift test` 不会执行任何
Demo 代码行。这意味着：

- **`swift test` pass 不证明 Demo 正确**，只证明 SDK 内部行为不变
- **`xcodebuild Demo build` pass 不证明 Demo 运行时正确**，只证明编译通过
  （类型签名、import 路径、protocol conformance 等静态属性）

Demo 没有 XCTest target（当前 project.yml 没配）。因此 Demo 运行时
行为的 verification 只能靠：

- 用户真机 / 模拟器手动操作
- 手动对照期望行为（拖 slider、导出、查看相册）

### Mitigation — 涉及 Demo 改动的 commit 协议

涉及 Demo 的 commit message body **必须**列：

- **Build verification**: `xcodebuild Demo build` pass
- **Manual verification needed**: 具体步骤 + 期望行为，让 PR reviewer / 用户
  知道该怎么验

Code-path example：
> Manual verification needed:
> - Open DCRDemo in simulator
> - Select "人像" sample image
> - Wait ~1s for Vision mask generation
> - Drag PortraitBlur slider → expect subject stays sharp, background blurs

### 当 Demo 成为 integration reference 时

若某个 SDK API 的 "正确集成" 只在 Demo 里被验证（例如 `PortraitBlurMaskGenerator`
→ `FilterChainBuilder.build(portraitMask:)` 链路），应优先考虑：

1. **把 core logic 提到 SDK 做 integration test** — 构造 synthetic 输入 + mask，
   跑 pipeline，断言输出符合契约
2. **或给 Demo 新增 XCTest target** — 需要改 project.yml + 增加 test bundle
   配置。成本较高，在 Demo 规模变大后才值得

当前（2026-04-22）选路径 1：关键 SDK 集成路径应该有 SDK 层面的 integration
test，Demo 只作为 UI showcase。

---

## §4 规则起源（可追溯）

2026-04-22 session：3 个 Demo-only commit（`11bf7fa` export crash fix /
`89ad969` gamma encode / `f1837cc` PortraitBlur 三路径）以 "反正不动 SDK"
为由跳过 `swift test`。

- 事后补跑 248 tests 全绿
- 但用户指出："248 = 之前 session baseline 一样，意味着我 commit 的改动
  一行都没进 test coverage"
- 正确：SDK 无变化所以 SDK test 无变化是 trivially 成立的；跳 `swift test`
  只是把 regression 风险从 "不存在" reasoning 成 "应该不存在" 的赌博

触发条件（后续 Claude 看到任意一条都应停下引用本规则）：

- "反正只改 Demo，swift test 不用跑"
- "这是纯注释 / 纯 doc 改动，不会影响测试"
- "xcodebuild 过了，应该 OK"
- "Demo 编译过了就行"

——都属于跳过验证的借口，本规则否决这类推理。

---

## §5 为什么不单独跑个 SDK-internal linter 取代 swift test

跑 `swift test` 已经是最廉价的 regression signal。静态分析 / linter 能抓
部分类别 bug 但不覆盖行为；`swift test` 两三百个断言是**实际执行路径上**
的 ground truth。成本 ~0.5 秒。没有理由用更弱的检查替代。
