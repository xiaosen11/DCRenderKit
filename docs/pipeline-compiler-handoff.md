# Pipeline Compiler Refactor — Session Handoff

**Last updated**: 2026-04-24, end of session-1 (Phases 0-4 done).
**Target**: Phase 5 (Pipeline integration + real-device benchmark).
**Remote state**: `origin/main` tracks every commit in this session.

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

## 10. Literal opening prompt for next session

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

**绝对禁止**：
  · 重开 Q1-Q4（shape 方案、TailSink 激进 / 保守、warm-up 归属、IR 暴露）。
  · 碰 fragment shader（Phase 6 的事）。
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
