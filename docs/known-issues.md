# Known Issues

A short, honest list of issues we know about but have not fixed
(either because the root cause is outside the SDK, or because the
fix is post-1.0). Each entry includes how to verify it on your
own toolchain and what mitigation, if any, applies.

This file is the source of truth for the "Known limitations"
language in the README. New issues land here first; they only
move into `TODO.md` (for fix-tracking) once we have a plan.

---

## #1 — `MultiPassExecutorTests` skipped on CI (macOS 15.7.4 driver bug)

**Symptom**: When `swift test` runs the entire `DCRenderKitTests`
suite on macOS 15.7.4 / Xcode 16.4 / Swift 6.1.2, the process
deterministically SIGSEGVs ~250 ms into
`MultiPassExecutorTests.testDAGFanOut` (or whichever test in that
class is alphabetically first after `--skip` filters). The crash
is on a background thread; it doesn't surface as an XCTest
failure, only as a non-zero exit code.

**Root cause (confirmed)**: a Metal driver bug in the macOS 15.7
build chain. Reproduced reliably on the GitHub Actions
`macos-15` runner (image as of 2026-04-26). Does **not** reproduce
on:
- Local macOS 26 / Xcode 17 / Swift 6.2 — full suite passes
- The same suite split into per-class `swift test` invocations on
  CI, except `MultiPassExecutorTests` itself

We initially suspected an SDK-level race (a completion handler
running after `tearDown` had nilled out test-class properties),
but the multi-Pipeline isolation refactor that fixed every
analogous race left the crash unchanged on macOS 15.7.4 — confirming
the issue is below the SDK.

**Mitigation**:
- CI explicitly skips `MultiPassExecutorTests` on macOS 15.7.4
  (see `.github/workflows/ci.yml` for the in-line note).
- Functional coverage of `MultiPassExecutor` is preserved through
  `MultiPassFilterTests`, `Phase5PipelineIntegrationTests`, and
  the per-filter contract tests (Clarity, HighlightShadow,
  SoftGlow). No rendering correctness is unverified by CI.
- The skipped tests are validation-style (forward reference
  rejection, duplicate pass names, etc.) — easy to relocate to an
  isolated test class if the driver bug persists in macOS 16.

**How to verify yourself**:
- On macOS 26+: `swift test --disable-swift-testing` should pass
  every test, including `MultiPassExecutorTests`.
- On macOS 15.7.x: expect `MultiPassExecutorTests` to crash. Other
  tests pass.
- We are not aware of any user-facing rendering bug caused by this
  driver issue; the crash only triggers under XCTest's specific
  test-isolation pattern.

**Tracking**: re-test this on each new macOS / Xcode minor release.
If the crash disappears, remove the CI skip in the same PR.

---

## #2 — DocC archive depends on `docbuild` (no swift-docc-plugin)

**Status**: working as designed; documenting for clarity.

DCRenderKit's zero-external-dependency rule (enforced by
`PackageManifestTests.testPackageHasNoExternalDependencies`) means
we can't depend on `swift-docc-plugin`. The CI workflow generates
DocC archives via `xcodebuild docbuild` instead. This works but
implies:

- Local DocC preview requires Xcode (`xcodebuild docbuild` →
  archive opens in Xcode's documentation viewer).
- DocC catalogue updates are validated only by CI; there's no
  `swift package docc-preview`-equivalent.

If you're contributing to DocC docs and want a faster local
iteration loop, run:

```sh
xcodebuild docbuild \
    -scheme DCRenderKit \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .derivedData
```

Then double-click the resulting `.doccarchive` under
`.derivedData`.

---

## How to report a new known issue

If you find behaviour that looks like a bug but you're not sure:

1. Try to reproduce on at least two different macOS / Xcode
   combinations. Driver bugs that vanish across versions usually
   land here, not in the issue tracker.
2. Capture the smallest repro (a `swift test --filter` line, or a
   minimal app snippet).
3. Open a GitHub issue with the repro and your toolchain
   (macOS / Xcode / Swift / GPU model). We'll triage to either
   "real SDK bug" (→ TODO.md) or "known issue" (→ here).
