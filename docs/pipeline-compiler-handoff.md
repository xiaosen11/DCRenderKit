# Pipeline Compiler Refactor — Session Handoff

**Last updated**: 2026-04-24, end of session-2 (Phase 5 done —
awaiting user-gate real-device benchmark on iPhone 14 Pro Max).
**Target**: Phase 6 (fragment shader bodies) — **blocked on Phase 5
user gate** below.
**Remote state**: local `main` is ahead of `origin/main` by the
session-2 commits; `git push` is **user-gated**, not yet pushed.

This document is the authoritative hand-off for any Claude Code
session picking up the pipeline-compiler refactor. Read §0 first;
§1-§5 are lookup reference, §6 is the Phase-5 plan, §7 covers the
opening-prompt contract.

---

## 0. Most-important facts (read-this-or-miss-something)

1. **The authoritative design document is
   [`docs/pipeline-compiler-design.md`](pipeline-compiler-design.md)**.
   User-signed-off decisions live there; don't rehash the `A vs B`
   or "保守 / 激进" conversations.
2. **Scope = cross-filter fusion compiler** that turns
   `[Exposure, Contrast, Saturation, …]` into one uber kernel at
   runtime. Motivation: real performance regression when stacking
   ≥ 3-4 filters in a live preview.
3. **Method B**, aggressive TailSink, SDK-provided warm-up, IR
   not public — all four Q1-Q4 decisions are locked from
   session 0. Do not reopen.
4. **Current status**: Phases 0-4 complete. **504 tests pass,
   0 warnings**. The codegen / allocator infrastructure is
   ready; Phase 5 is the integration + user-gated real-device
   step.
5. **Phase 5 is destructive**: it deletes every
   `DCR<Name>Filter` production kernel (method B has no
   fallback), migrates 200+ existing tests off the standalone-
   kernel path, and turns `Pipeline.executeStep` into a
   codegen-driven dispatcher. The frozen `DCRLegacy*Filter`
   kernels in `Tests/DCRenderKitTests/LegacyKernels/` remain as
   the parity reference until Phase 7 終 verification, then
   they delete too.
6. **User gate at the end of Phase 5**: consumer must benchmark
   on real iPhone 14 Pro Max before Phase 6 unlocks.

---

## 0.1 Session-2 Phase 5 retrospective (2026-04-24)

Status: **code done, user gate open**.

| Step | Status | Commit | Delivered |
|---|---|---|---|
| 5.1 | ✅ | `de5a997` | `Pipeline.executeSinglePass` routes built-in filters through `ComputeBackend` |
| 5.2 | ✅ | `93ff6c3` | `PipelineOptimization` enum + `Pipeline.optimization` property |
| 5.3 | ✅ | `61be943` | Graph-level compiler path with cross-filter fusion; `DeferredEnqueueTests` adjusted for aliasing planner |
| 5.4 | ✅ | (no-op) | No tests hard-coded the 12 production kernel names — nothing to migrate |
| 5.5 | ✅ | `c8256b1` | 12 production standalone kernels deleted; body functions retained |
| 5.6 | ✅ | `c0b621b` | `PipelineCompilerWarmUp.preheat(combinations:)` async API |
| 5.7 | ⏳ | (this commit) | macOS benchmark harness + Phase 5 user gate (below) |

Test delta session-2: 504 → 517 (+13), zero warnings, zero
regressions through the whole session.

### 0.1.1 macOS benchmark (informational — user-gate runs on iPhone)

`Phase5BenchmarkTests.testFullModeFusesFourFilterChainIntoOneUberKernel`
A/B-tests `.full` vs `.none` on `[Exposure, Contrast, Blacks,
Whites]` at 1080×1080 with 2 warmup + 8 measured iterations.
Representative run on the session-2 CI host (Apple Silicon Mac,
idle thermal state):

| Mode | Uber kernels compiled | GPU median | GPU p95 |
|---|---|---|---|
| `.full` | 1 (fused cluster) | 0.279 ms | 0.280 ms |
| `.none` | 4 (per-filter) | 0.794 ms | 0.878 ms |

**Fusion speedup (median `.none` / median `.full`): 2.85×** on
macOS. The iPhone number will differ — Apple Silicon desktops
amortise dispatch overhead differently than mobile chips — but
the cache-hit expectation holds.

### 0.1.2 **PHASE 5 USER GATE — iPhone 14 Pro Max**

The compiler path is merge-ready behaviourally; the user-gate step
is the real-device perf + visual confirmation required before
Phase 6 unlocks. Do **not** open Phase 6 until this gate passes.

Perform the following on iPhone 14 Pro Max:

1. **Pull** the `main` branch of this repo (local only — the
   session-2 commits have NOT been pushed; `git log origin/main..HEAD`
   lists the seven outstanding commits to push first).
2. **Build + run** `DCRDemo` in Release configuration on device.
3. **Live preview benchmark**: apply the `[Exposure, Contrast,
   Blacks, Whites, Saturation, Sharpen, FilmGrain, Clarity]` 8-
   filter stack on the default sample photo. Observe:
   - Preview must remain smooth while dragging every slider.
   - No visible banding / colour shift versus pre-Phase-5 baseline
     (pull `e6e0739` for a side-by-side reference if needed).
   - No crashes / Metal validation errors in the Xcode console.
4. **Tier 2 visual sign-off**: the CLAUDE.md red-line against
   "先 MVP 再完善" means any visible regression on Tier 2 curves
   (Exposure / Contrast / Blacks / Whites / Highlights / Shadows)
   is a Phase-5-blocker. Sample five representative scenes
   (portrait / landscape / low-light / high-DR / macro) and
   confirm parity with the pre-Phase-5 baseline.
5. **Thumbs-up reply** to close the gate and unlock Phase 6.

If any of the above fails: file a Phase 5 regression in this doc
at §12 (create if missing) and **do not** open Phase 6. The most
likely root-cause buckets, in descending priority:
   (a) VerticalFusion crossing a `wantsLinearInput` boundary by
       accident (currently guarded; verify `canMerge` hasn't been
       relaxed).
   (b) LifetimeAwareTextureAllocator aliasing the final bucket's
       texture onto a still-live intermediate (planner's
       `Int.max` end-of-life for final nodes should prevent this;
       confirm in `TextureAliasingPlanner`).
   (c) Runtime Metal compile failure under device-specific
       toolchain (would throw early; check `XCTMetric` / Xcode
       console).

---

## 1. Session-1 commit chain (`main` branch)

```
878cb0a  feat(resources): LifetimeAwareTextureAllocator             Phase 4
7557810  test(compiler): multi-filter cluster parity + fixture fix   Phase 3 step 6
cac8e4b  feat(compiler): codegen for 5 richer-shape filters + parity Phase 3 step 3c
5cc93cb  test(compiler): legacy parity gate for 7 pure filters       Phase 3 step 5
ce64228  feat(compiler): ComputeBackend + UberKernelCache            Phase 3 step 4
f8b5153  feat(compiler): MetalSourceBuilder fusedPixelLocalCluster   Phase 3 step 3b
1f91938  feat(compiler): MetalSourceBuilder pixelLocalOnly           Phase 3 step 3a
952fd78  refactor(shaders): 5 remaining filters body markers         Phase 3 step 2b-f
57db540  feat(api): FusionBodySignatureShape                          Phase 3 step 2-pre
5391773  refactor(shaders): 7 pure pixelLocal body markers            Phase 3 step 2a
6203f7c  feat(compiler): ShaderSourceExtractor                        Phase 3 step 1
b75163d  test(compiler): bundle 12 legacy kernels as parity ref       Phase 1 step 6
9d919c9  feat(ir): Lowering AnyFilter → PipelineGraph                 Phase 1 step 4-5
223d7fb  feat(ir): PipelineGraph internal IR + validator              Phase 1 step 3
47c05c6  feat(filters): 12 FusionBodyDescriptor on built-ins           Phase 1 step 2
1b9ebc5  feat(api): FusionBodyDescriptor opt-in hook                   Phase 1 step 1
176c762  docs(compiler): Phase 0 design doc                            Phase 0
  ... plus Phase-2 optimiser commits (DCE, VerticalFusion, CSE,
      KernelInlining, TailSink, integration smoke)
```

Test count trajectory:  348 → 384 → 444 → 490 → 504.

---

## 2. Files / modules laid down this session (landmarks)

### `Sources/DCRenderKit/Core/FusionBodyDescriptor.swift`
Public API. `FusionBodyDescriptor` + `FusionNodeKind` +
`FusionBodySignatureShape` (5 variants). Every built-in filter
ships a concrete descriptor via `FilterProtocol.fusionBody`.
Default is `.unsupported` (legacy compatibility).

### `Sources/DCRenderKit/Core/PipelineGraph/`
Whole IR + optimiser live here:
- `Node.swift` — `NodeKind` (6 variants + cluster) + `NodeRef` +
  aux enums + dependency walker.
- `PipelineGraph.swift` — container + 5-rule validator +
  `_testInvalidNodes` bypass for validator tests.
- `Lowering.swift` — `[AnyFilter] × TextureInfo → PipelineGraph?`.
- `OptimizerPass.swift` — protocol + `Optimizer.defaultPasses`
  ordered list.
- `DeadCodeElimination.swift` — reachability-driven pruning.
- `VerticalFusion.swift` — merges same-shape, same-linear
  pixelLocal chains into `.fusedPixelLocalCluster`. Shape match
  is required (Step 3c added the guard).
- `CommonSubexpressionElimination.swift` — folds
  signature-identical non-final non-cluster nodes.
- `NodeSignature.swift` — CSE key (byte-level uniform compare).
- `KernelInlining.swift` — absorbs a lone pixelLocal into a
  downstream `.neighborRead`'s `inlinedBodyBeforeSample`.
- `TailSink.swift` — aggressive version; absorbs a downstream
  pixelLocal into either a cluster (as a new member) or into a
  neighborRead's `tailSinkedBody`.
- `ShaderSourceExtractor.swift` — marker-based `.metal` source
  slicing.

### `Sources/DCRenderKit/Dispatchers/`
- `FusionHelperSource.swift` — canonical SRGBGamma + OKLab
  helper strings (MIRROR discipline) + 5 filter-private helper
  blocks. `helpersForBody(named:)` routes bodies to dependencies.
- `MetalSourceBuilder.swift` — per-shape code generators: 5
  single-node shapes + cluster. Uber-kernel name is FNV-1a hash
  over body name + uniform struct + shape tag.
- `ComputeBackend.swift` — compile + bind + dispatch.
  Texture slots: 0=output, 1=source, 2+ aux. One uniform buffer
  per cluster member; single buffer for single-node.

### `Sources/DCRenderKit/Resources/`
- `UberKernelCache.swift` — `[functionName: MTLLibrary |
  MTLComputePipelineState]`. Production uses shared; tests build
  isolated caches for cache-hit probes.
- `TextureAliasingPlanner.swift` — hermetic bucket planner
  (interval-graph greedy-by-release).
- `LifetimeAwareTextureAllocator.swift` — plan →
  `[NodeID: MTLTexture]` via TexturePool.

### `Tests/DCRenderKitTests/LegacyKernels/*.metal`
Twelve `.metal` files (legacy copies of Phase-1 production
kernels, renamed `DCRLegacy*Filter`). Registered via
`LegacyKernelFixture.registerIfNeeded()`; each legacy-using test
calls it in `setUpWithError`. The fixture's guard is **dynamic**
(probes `ShaderLibrary.shared.contains(...)`) not once-per-
process — that's a fix for test-order drift where other tests
`unregisterAll()` between legacy consumers.

---

## 3. Locked architectural decisions (do not reopen)

| Decision | Reference | Rationale |
|---|---|---|
| Method B (no production fallback) | Q1, design §4 | User rejected method A — production has no legacy path post-Phase-5 |
| Aggressive TailSink | Q3 | User rejected保守; design §5.5 describes the scope |
| SDK provides warm-up | Q2 | `PipelineCompilerWarmUp.preheat(...)` API lives in Phase 5 |
| IR internal | Q4 | Additive public API limited to 6 items in §9; 7th is `FusionBodySignatureShape` |
| VerticalFusion shape-match | Phase 3 step 3c | Cross-shape clusters deferred to future work |
| Legacy kernels in test target | Phase 1 step 6 | Mirror of Phase-1 production kernels; delete-after-Phase-7 |
| Planner final-node segregation | Phase 4 | Final node's bucket never aliases (caller holds output post-CB) |
| Compile guard mode | repo-wide | `swift build -Xswiftc -warnings-as-errors` — already zero-warning; keep that way |

---

## 4. Known test-order / gotcha quirks

1. **`LegacyKernelFixture.registerIfNeeded()` uses a dynamic
   probe**, not a one-shot flag. Several other tests call
   `ShaderLibrary.shared.unregisterAll()` in their setUp
   (`SmokeTests`, `ToneAdjustmentFilterTests`,
   `SRGBGammaConversionTests`). Running legacy-using tests after
   those WITHOUT the dynamic-probe fix produced 18 failures in
   the full-suite run. If you add more tests that wipe
   ShaderLibrary, either call `registerIfNeeded` in their
   `tearDown` too or leave the dynamic probe alone.
2. **`Fx.pixelLocalNode` parameter order**: `isFinal` precedes
   `additionalNodeInputs` by default. Test calls using positional
   `additionalNodeInputs:` followed by `isFinal:` trigger a
   compile error; follow call sites in
   `CommonSubexpressionEliminationTests` if unsure.
3. **`Node.outputSpec` for `.fusedPixelLocalCluster`**: always
   `.sameAsSource` because `VerticalFusion.canMerge` requires
   both nodes' specs match and both be `.sameAsSource`. Planner
   resolves this to the source `TextureInfo` verbatim.
4. **`FilmGrain` is `.neighborRead`, not `.pixelLocal`**. Phase 3
   step 3c reclassified it — it reads the block-centre texel. If
   you re-run `FusionBodyDescriptorTests
   .testBuiltInSinglePassFiltersDeclareConcreteDescriptors`, the
   expected kind is `.neighborRead(radius: 16)`.
5. **`NormalBlendBody` returns `half4`, not `half3`**. Alpha
   must survive Porter-Duff compositing. The
   `.pixelLocalWithOverlay` uber kernel template accounts for
   this (`output.write(rgba, gid);` instead of
   `half4(rgb, c.a)`).
6. **CCD init signature** is
   `init(strength:digitalNoise:chromaticAberration:sharpening:saturationBoost:grainSize:sharpStep:caMaxOffset:)`
   — do NOT use `density:caAmount:sharpAmount:saturation:`
   (old parameter names). Tests in `LegacyParityTests`
   already follow the right form.
7. **LUT3D init** takes `cubeData: Data, dimension: Int`
   (binary float payload), not `cubeData: <.cube text>`.
   Integration tests use an inline identity 2³ cube.
8. **FusionBody is `internal` not public**; but
   `FusionBodyDescriptor` wraps it as `public`.
   `PipelineCompilerTestFixtures.dummyBody` and
   `PipelineGraphIRTests.dummyBody` construct `FusionBody`
   directly with `signatureShape:` — both helpers need
   updating together if FusionBody gains fields.

---

## 5. How to verify state before working

```bash
# From repo root:
swift build -Xswiftc -warnings-as-errors    # zero warnings expected
swift test                                   # 504 pass / 0 fail / 0 unexpected
git log --oneline origin/main..HEAD          # should be empty (we push every phase)
git status                                   # clean except .claude/skills/ untracked (ignore)
```

If `swift test` shows 18 failures for `LegacyParityTests` /
`LegacyKernelAvailabilityTests`, the fixture-fix regression is
back. Check `LegacyKernelFixture.registerIfNeeded` — it must
probe `ShaderLibrary.shared.contains(functionNamed:)`, not a
static flag.

---

## 6. Phase 5 — the work to do next

### 6.1 Scope

Wire the Phase-3 codegen into production dispatch. Deliverables:

1. **`Pipeline.optimization: PipelineOptimization`** public
   property (new enum: `.full | .none`). Default `.full`.
2. **`Pipeline.executeStep`** routes `.single(filter)` through
   `ComputeBackend.execute(...)` when `filter.fusionBody.body !=
   nil` and `.optimization = .full`; otherwise falls through to
   the legacy `ComputeDispatcher.dispatch` path (for third-party
   filters with `.unsupported` descriptors).
3. **`Pipeline.encodeAll`** runs `Lowering.lower(...)` +
   `Optimizer.optimize(...)` up-front, allocates via
   `LifetimeAwareTextureAllocator`, dispatches each resulting
   node, and wires the allocator's `scheduleRelease` into the
   command buffer's completion handler.
4. **Delete every production standalone kernel**. Remove the
   `kernel void DCR<Name>Filter(...)` declarations from the 12
   filter `.metal` files; keep only the `// @dcr:body-begin`
   inline body + uniform struct + shared helpers. The SDK
   shipping binary loses ~12 kernels, gaining the runtime-
   compiled uber kernels.
5. **`PipelineCompilerWarmUp.preheat(combinations:)`** —
   public API that builds + compiles the PSOs for common
   combinations at app-startup so first dispatches hit cache.
6. **Test-target delete migration**. Every test that calls
   `ComputeDispatcher.dispatch(kernel: "DCRExposureFilter", ...)`
   — about 50+ of them — must migrate to the codegen path OR
   explicitly use `DCRLegacyExposureFilter` (the legacy copy)
   if it needs kernel-level access.
7. **Real-device benchmark**. `PipelineBenchmark` already has
   the measurement primitives; add a Phase-5 smoke test that
   compares pre-refactor vs post-refactor dispatch count + peak
   texture memory on a representative 4-filter chain.
8. **User gate**: after the above, ship to consumer for
   real-device benchmarking. Do NOT delete the
   `Tests/DCRenderKitTests/LegacyKernels/*.metal` files at this
   phase — they're the parity reference through Phase 7.

### 6.2 Work order (recommended)

Step 5.1 — Pipeline wiring without deleting production kernels.
  Fuse the compiler in parallel to the legacy path; `.optimization
  = .none` falls to legacy. All existing tests still pass
  because production kernels remain.

Step 5.2 — Add `PipelineOptimization` enum + property.
  Public-API additive; update CHANGELOG `[Unreleased]`.

Step 5.3 — Phase-5 smoke tests covering the default `.full`
  path for a realistic chain. Before deleting production
  kernels, every smoke must pass.

Step 5.4 — Migrate tests that hard-coded
  `ComputeDispatcher.dispatch(kernel: "DCR...")`. Two paths:
    (a) Routine smoke tests → switch to going through
        `Pipeline.output()` (codegen-driven).
    (b) Direct kernel-name tests (legacy parity, shader smoke)
        → keep using `DCRLegacy*Filter`.

Step 5.5 — Delete production kernels. Diff:

    # In each of 12 `Shaders/.../<Name>Filter.metal`:
    -kernel void DCR<Name>Filter(
    -    texture2d<half, access::write> output [[texture(0)]],
    -    ...
    -{
    -    ...
    -    output.write(half4(DCR<Name>Body(...), ...), gid);
    -}

  The body, uniform struct, markers stay. ShaderLibrary now has
  no kernel-resolvable symbol for `DCR<Name>Filter` — tests that
  still reference it must have migrated in step 5.4.

Step 5.6 — Warm-up API.

Step 5.7 — Real-device benchmark + hand-off to user for
  approval.

### 6.3 What NOT to do in Phase 5

- Do NOT touch fragment shaders — that's Phase 6's job.
- Do NOT attempt mixed-shape clusters. VerticalFusion's
  shape-match guard is locked for Phase 5.
- Do NOT try to delete legacy kernels in
  `Tests/DCRenderKitTests/LegacyKernels/`. They stay through
  Phase 7.
- Do NOT try to auto-detect helper dependencies by scanning
  body text — `FusionHelperSource.helpersForBody(named:)`
  hardcodes the known-correct list.

### 6.4 Estimated scope

- ~800 lines new code (Pipeline integration + warm-up)
- ~300 lines test migration (50+ test call sites)
- 12 `.metal` edits (delete kernel block each)
- Full session's worth of work.
- User gate → end of session naturally.

---

## 7. Phase 6 — fragment shader bodies (overview)

Every `.pixelLocalOnly` / `.pixelLocalWithLUT3D` /
`.pixelLocalWithOverlay` filter gains a fragment-shader variant
of its body. Fragment bodies use `stage_in` for the pixel
coordinate and color attachments 0 for output + 1 for input (or
input sampled via `texture_sampler`). The fragment codegen
follows the same signature-shape framework but routes through
`MTLRenderPipelineDescriptor` instead of compute.

Per-filter parity test: run both compute-backed body and
fragment-backed body on the same input; assert bit-close at
`±1 LSB`.

Estimated scope: 80-100 k tokens of context; 12 filters × 30
lines shader + 12 parity tests ≈ ~400 lines + tests.

---

## 8. Phase 7 — TBDR render pipeline (overview)

`TBDRBackend` sibling of `ComputeBackend` that uses render
pipelines + `.memoryless` attachments. Short cluster chains get
the render path (intermediates stay in tile memory, zero device
bandwidth); longer chains or aux-reading filters fall through
to the compute path.

Phase 7 ends with `Tests/DCRenderKitTests/LegacyKernels/` + the
dynamic-probe fixture code deleting (once the user has accepted
Phase-7 real-device verification).

Estimated scope: ~80 k tokens; on the order of 2-3 sessions of
ordinary work including the final legacy cleanup commit.

---

## 9. Opening-prompt contract for the next session

See §10 below for the literal prompt. Key points that the
next Claude must internalise before touching code:

1. Read `docs/pipeline-compiler-design.md` cover-to-cover
   (800 lines — 15 minutes).
2. Read THIS document (you're reading it now).
3. Run `swift test` and confirm **504 / 0 / 0** before doing
   anything.
4. Do not re-architect; do not re-decide Q1-Q4; do not propose
   a "method C".
5. Phase 5 is destructive — every step 5.1 → 5.7 lands with its
   own commit. No giant single commit.
6. Before deleting a production kernel (step 5.5), grep the
   test target for the kernel name and confirm every reference
   has migrated. No orphan tests.
7. After each commit: `swift build -Xswiftc -warnings-as-errors`
   must pass with zero warnings. Fix as you go, never defer.

---

## 10. Literal opening prompts

Three versions — pick the one matching which phase the session
is starting on. Every version includes the Q1-Q4 lock + the
"don't reopen decisions" guardrails, so mis-picking is safe
(you'll just load more context than strictly needed).

### 10.A Phase 5 opening (user-gated Pipeline integration)

```
继续 DCRenderKit 的 pipeline-compiler refactor。你现在接手的是 Phase 5
(Pipeline integration + 真机 benchmark)。

**必读顺序（装载上下文，别跳步骤）**：

1. docs/pipeline-compiler-design.md — 完整设计稿。Q1-Q4 已 signed off，
   不要重开这些讨论。重点看 §4 (shader body B 方案)、§5 (optimizer)、
   §6 (codegen shape 分解)、§7 (allocator)、§9 (public API 边界)、
   §10 (testing strategy)、§11 (phase gate)、§13 (risks)。

2. docs/pipeline-compiler-handoff.md — 本文件的基础。§0 5 条 most-
   important、§3 锁定决策表、§4 测试顺序踩坑、§6 是你的工作主战场。
   §7/§8 是 Phase 6/7 overview，如果本 session 做完 Phase 5 还有余量
   且 user 让你接着做，再读对应节；否则不读。

3. Tests/DCRenderKitTests/PipelineCompiler/ 目录 ls 一遍。每个测试
   文件的顶部注释说明它覆盖什么 phase 的什么 step。LegacyParityTests 和
   ClusterLegacyParityTests 是你 migration 时的 ground truth。

4. Sources/DCRenderKit/Dispatchers/ComputeBackend.swift + MetalSourceBuilder
   .swift — Phase 3 已实装好的两个核心类。Phase 5 要把 Pipeline 的
   dispatch 路由到这里。

5. Sources/DCRenderKit/Resources/LifetimeAwareTextureAllocator.swift
   — Phase 4 的新 allocator，Phase 5 要接 Pipeline.

**验证当前状态（必做）**：

  swift build -Xswiftc -warnings-as-errors   # 零 warning
  swift test                                  # 504 pass / 0 fail

如果以上不 match，STOP。别改代码，先和 user 对齐状态。

**Phase 5 工作清单（按序做、每步独立 commit）**：

  5.1 Pipeline.executeStep 并联走 codegen（不删 production kernel）
  5.2 PipelineOptimization enum + Pipeline.optimization public property
  5.3 Phase-5 integration smoke tests
  5.4 Migrate 50+ 既有测试：或走 Pipeline.output() 路径，或切到
      DCRLegacy<Name>Filter 走 legacy 引用
  5.5 删除 12 个 production standalone kernel（.metal 文件里只保留
      body + markers + uniform struct + helpers）
  5.6 PipelineCompilerWarmUp.preheat(combinations:) API
  5.7 真机 benchmark 报表，然后 user-gate

**User gate**: 5.7 完成后，停下来请 user 在 iPhone 14 Pro Max 上跑
benchmark + 视觉验证 Tier 2 曲线感官问题。不跑过去不要开 Phase 6。

**如果 Phase 5 user gate 通过且 user 让你继续 Phase 6**: 读本文件的
§7 Phase 6 overview，然后按 §10.B 的 opening prompt 自我装载 Phase 6
scope，最后再开始 Phase 6 代码工作。结束 session 前更新本 §1 commit
chain + §6 改成 Phase-5 retrospective + §7 扩写成 Phase 6 active plan。

**绝对禁止**：
  · 重开 Q1-Q4（shape 方案、TailSink 激进 / 保守、warm-up 归属、IR 暴露）。
  · 碰 fragment shader（Phase 6 的事，除非 user 明确让你进 Phase 6）。
  · 跨 shape 合并 cluster（Phase 3 step 3c 明确锁定了 shape match）。
  · 删除 Tests/DCRenderKitTests/LegacyKernels/*.metal（Phase 7 才删）。
  · 凭记忆 claim "Apple 官方建议" 之类（.claude/rules/engineering-
    judgment.md §4 要求 fetched URL）。

**CLAUDE.md + 现有 rules 继续适用**：
  · 每 commit 前 swift build + swift test 无豁免
  · 商用级代码、零 warning
  · 破坏性变更登记 CHANGELOG [Unreleased]
  · 不主动 git push（需用户明确 "push"）
  · 英文 commit + 中文聊天

开工前先跑一遍验证，然后 Step 5.1 开始。每个 commit 都要带测试。
```

### 10.B Phase 6 opening (fragment shader bodies)

```
继续 DCRenderKit 的 pipeline-compiler refactor。你现在接手的是 Phase 6
(fragment shader body 补齐 + compute/fragment parity)。

**前置条件**: Phase 5 已合并到 main，真机 benchmark 通过且 user 签字。
如果不确定，跑 swift test 查最新 pass count + 读 handoff §1 最新 commit
chain 是否列出 Phase-5 条目。

**必读**：

1. docs/pipeline-compiler-design.md — §1-§4 + §6 TBDR 铺垫。
2. docs/pipeline-compiler-handoff.md — §0 决策 lock + §3 锁定决策 +
   §4 踩坑 + §7 Phase 6 overview（本 session 主战场）+ §8 Phase 7
   overview（了解下游需求不要破坏 TBDR 前提）。
3. Sources/DCRenderKit/Dispatchers/MetalSourceBuilder.swift — 看看
   compute 路径现有 shape 实装，fragment 版本按相同 shape 拆分。
4. Sources/DCRenderKit/Shaders/**/*.metal — 每个 filter 的 body 已存
   在，fragment 版本要在同文件加第二个 body 或单独 .metal 文件 —
   依架构决定。

**验证当前状态（必做）**：

  swift build -Xswiftc -warnings-as-errors
  swift test

pass count 应 ≥ session-1 的 504 + Phase 5 新增量。0 warning / 0 fail。
不 match 就 STOP。

**Phase 6 工作清单**：

  6.1 决定 fragment body 住哪：同 .metal 的 second body，还是
      `<Name>FilterFragment.metal`？选一条路，设计稿更新反映决策。
  6.2 `MetalSourceBuilder.buildFragmentPipeline(for: Node)` —
      与 compute 方法对称，emit vertex + fragment pair + render
      pipeline descriptor。
  6.3 ComputeBackend 的兄弟 `RenderBackend` / 或 compute backend
      的 render overload。
  6.4 9 个 pixel-local filter 补 fragment body（LUT3D/NormalBlend 形
      状不同，独立处理）。
  6.5 compute/fragment parity test × 每 filter — 同 input 下两版
      output ±1 LSB。

**User gate**: 无强制真机 gate；但 Phase 6 完成后 Phase 7 才能接。

**绝对禁止**: 见 §10.A 同样列表。加一条：别在 Phase 6 就切 production
dispatch 到 render pipeline — 那是 Phase 7 的 TBDR 任务。本 phase
只是**准备** fragment body，不走 TBDR 路径。

开工流程同 §10.A。每 step 独立 commit + tests。
```

### 10.C Phase 7 opening (TBDR + final cleanup)

```
继续 DCRenderKit 的 pipeline-compiler refactor。你现在接手的是 Phase 7
(TBDR render pipeline backend + 终验 + legacy kernel 删除)，项目的最
后一个 phase。

**前置条件**: Phase 5 + Phase 6 都已合并到 main。Compute/fragment
parity test 全绿（Phase 6 的保底）。真机 Phase-5 benchmark 已 user 签
字。

**必读**：

1. docs/pipeline-compiler-design.md — §6.2 TBDR backend scope、
   §7.4 memoryless attachment、§13 TBDR 风险条目。
2. docs/pipeline-compiler-handoff.md — §0 决策 lock + §3 锁定决策 +
   §4 踩坑 + §8 Phase 7 overview（本 session 主战场）+ §2 文件索引
   确认 Sources / Tests 当前形态。
3. Apple Metal documentation on TBDR:
   - `MTLStorageModeMemoryless`
   - `MTLRenderPassDescriptor` + tile memory
   - `imageblock` / function linking for tile shaders
   （engineering-judgment §4: 引 fetched URL，不靠记忆）

**验证当前状态（必做）**：

  swift build -Xswiftc -warnings-as-errors
  swift test

pass count 应反映 Phase 5 + 6 累积。不 match 就 STOP。

**Phase 7 工作清单**：

  7.1 `TBDRBackend` — sibling of ComputeBackend. 输入 Node 输出
      render pipeline dispatch。memoryless attachment 决策逻辑在
      allocator 扩展。
  7.2 Allocator 扩展 supporting memoryless spec — 同 bucket 但不走
      TexturePool.dequeue，`MTLTexture` 是 memoryless 的。
  7.3 Backend 路由：Pipeline.executeStep 对 cluster / 连续 pixelLocal
      chain 选 TBDR if 够长且下游能接 render；否则 compute。
  7.4 Phase-7 smoke test 覆盖 TBDR 路径 bit-equal compute 路径。
  7.5 真机终验（user gate）：benchmark + 视觉验证在 TBDR 路径上
      维持或改善。
  7.6 **Final cleanup commit**：user 签字 + 真机稳定 ≥ 1 周后 —
      删 Tests/DCRenderKitTests/LegacyKernels/*.metal × 12 +
      LegacyKernelFixture.swift + LegacyParityTests.swift +
      ClusterLegacyParityTests.swift + LegacyKernelAvailabilityTests
      .swift。
  7.7 Handoff doc §1 改成 "final", §6-§8 改成 retrospective. memory
      file 里记"done"。

**User gate 2 次**:
  · 7.5 真机终验
  · 7.6 删 legacy 前 user 签字 + ≥ 1 周稳定观察

**绝对禁止**: 见 §10.A。加一条：7.6 之前任何情况下都不要删 legacy
kernels — 它们是 parity 最后的保险。

开工流程同 §10.A。Phase 7 尾声 session 结束时，refactor 项目完
结；memory file 标 "done"，handoff doc 归档。
```

---

## 11. Maintaining this document

Every end-of-phase commit should update §1 (commit chain) and
§5 (verification-state expected). Phase-5 completion flips §6
to a "Phase 5 retrospective" section and opens §7 Phase-6 as
active. Phase-7 completion deletes the legacy kernel section
from §2 and moves §3's "legacy kernels in test target" entry
to "Done — removed in commit <hash>".

Keep decision reversals explicitly called out if they ever
happen (they shouldn't — Q1-Q4 are locked).
