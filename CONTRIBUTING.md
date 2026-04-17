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

### Swift Style

- Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Use meaningful names (`exposure` not `exp`, `filterChain` not `fc`)
- Prefer value types (`struct`) over reference types (`class`) unless state sharing is required
- Use `async`/`await` for asynchronous APIs, not completion handlers

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
  - Reference image test (output compared to known-good output)

- New public APIs MUST have at least one integration test

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
