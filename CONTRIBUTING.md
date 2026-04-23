# Contributing to DCRenderKit

Thank you for your interest in contributing to DCRenderKit! This document outlines the process and guidelines for contributing.

## Code of Conduct

This project adheres to the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## How to Contribute

### Reporting Bugs

1. Check [existing issues](https://github.com/xiaosen11/DCRenderKit/issues) to avoid duplicates.
2. Use the bug report template and include:
   - iOS/macOS version
   - Device model (especially GPU generation)
   - Minimal reproducible example
   - Expected vs actual behavior

### Suggesting Features

1. Open a [Discussion](https://github.com/xiaosen11/DCRenderKit/discussions) first for broader features.
2. Create an issue with the `enhancement` label for specific requests.

### Submitting Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Make your changes following the coding standards below
4. Ensure all tests pass: `swift test`
5. Update documentation as needed
6. Commit with a clear message (see commit message format below)
7. Push and open a PR

## Coding Standards

### Environment

- Swift 6.0 (strict concurrency) / Xcode 16+
- iOS 18.0+ / macOS 15.0+ deployment targets
- Zero external dependencies — any `.package(url:...)` in
  `Package.swift.dependencies` fails `PackageManifestTests`

### Swift Style

- Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Use meaningful names (`exposure` not `exp`, `filterChain` not `fc`)
- Prefer value types (`struct`) over reference types (`class`) unless state sharing is required
- Use `async`/`await` for asynchronous APIs, not completion handlers

### Hard-coded rules

The `.claude/rules/` directory formalises project-wide non-negotiables.
Humans contributing PRs should read them too:

- `commit-verification.md` — `swift build` + `swift test` before every
  commit, no exceptions (including Demo-only / doc-only changes).
- `engineering-judgment.md` — no "aggressive / conservative" framing;
  external claims require a fetched URL, not memory; don't bypass
  algorithm history when replacing a filter.
- `testing.md` — assertion expected values must be derived and
  commented; failing tests default to "implementation is wrong, not
  the assertion"; follow the 3-way re-derivation protocol on failure.
- `filter-development.md` — new filters follow the 4-step algorithm
  selection gate (dimension classification → candidate list →
  industry reference → `Model form justification` doc comment).
  Empirical fitting is the last resort.
- `spatial-params.md` — spatial parameters fall into three
  categories (visual-texture / image-structure / per-pixel) with
  three different adaptation strategies.

### Filter contract requirements

New Tier 3-style "perception-based" filters (local tone, effects)
must ship with a contract in `docs/contracts/<filter>.md` declaring
measurable clauses, plus a test in `Tests/DCRenderKitTests/Contracts/`
verifying each clause. See existing contracts (Clarity, HighlightShadow,
SoftGlow, Saturation, Vibrance) for the template.

### Metal Shaders

All Metal shaders must:
1. Include bounds check: `if (gid.x >= width || gid.y >= height) return;`
2. Use `half` precision unless full `float` is required
3. Document model form justification in the Swift doc comment of the wrapping filter:

```swift
/// Model form justification:
///   - Type: [1D per-pixel | 2D neighborhood | Multi-scale]
///   - Algorithm: [Name + reference to paper/implementation]
///   - Alternative considered: [Why not X]
```

### Commits

Use conventional commits format:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`

Example:
```
feat(render): add custom vertex buffer support to RenderDispatcher

Allows non-quad geometry for distortion filters and sticker rendering.
Includes PSO cache key expansion.

Closes #42
```

### Testing

- New filters MUST have at least:
  - Identity test (zero parameters = original image)
  - Extreme value test (±100 or max range doesn't crash or produce NaN)
  - Monotonicity test if the slider has an ordered axis
  - For Tier 3 (perception-based) filters: a contract document plus
    contract tests (see `docs/contracts/` + `Tests/DCRenderKitTests/
    Contracts/`)
  - For principled tone operators (Reinhard toe, log-slope, etc.):
    hand-derived numerical-assertion tests that cite the operator's
    formula (see `ToneAdjustmentFilterTests.swift` for the pattern)

- New public APIs MUST have at least one integration test.

- Regression-sensitive outputs (Tier 4 aesthetic filters) use
  `SnapshotAssertion.assertMatchesBaseline` to freeze pixel-level
  baselines. First-run writes the baseline; subsequent runs fail on
  drift past tolerance.

## Pull Request Process

1. PR title follows conventional commit format
2. PR description includes:
   - Problem statement
   - Solution approach
   - Trade-offs considered
   - Test plan
3. All CI checks must pass
4. At least one reviewer approval required
5. Squash and merge preferred

## Questions?

Open a [Discussion](https://github.com/xiaosen11/DCRenderKit/discussions) — we're happy to help.
