<!--
Thanks for contributing to DCRenderKit! Please fill in the sections below.
Delete irrelevant sections if they don't apply.
-->

## Summary

<!-- 1–2 sentences on what this PR does, and why. -->

## Type of change

- [ ] Bug fix (no public API changes)
- [ ] New feature (new filter, new API, or new configuration surface)
- [ ] Breaking change (public API signature, behaviour, or uniform layout
      changed — requires a `Changed (breaking)` entry in CHANGELOG.md
      under `[Unreleased]`)
- [ ] Docs / CI / tooling only

## Algorithmic justification (for filter changes only)

<!--
If this PR adds, replaces, or changes the core algorithm of a filter,
fill in the Model form justification block (per
.claude/rules/filter-development.md):
-->

- Type: [ 1D per-pixel | 2D neighborhood | Multi-scale | … ]
- Algorithm: [ name + reference URL (paper / open-source implementation / industry presentation) ]
- Alternatives considered: [ which candidate families, why this wins ]

## Test plan

<!--
  - What new tests were added? (identity, extreme, monotonicity,
    contract clauses, snapshot baseline — see CONTRIBUTING.md)
  - Which existing tests need to be updated because behaviour changed?
  - Did you re-derive expected values per testing.md § "Part 1" § 1.4?
-->

- [ ] `swift build` succeeds with no warnings
- [ ] `swift test` all green (record pass count: _____)
- [ ] For filter / shader changes: new-pixel expected values
      derived from the operator formula (not from observed output)
      and written into the assertion comments
- [ ] For Tier 3 perception-based filters: `docs/contracts/<name>.md`
      updated if clauses changed
- [ ] For Tier 4 aesthetic filters: `SnapshotAssertion` baseline
      re-recorded intentionally if output shape changed

## CHANGELOG entry

<!--
Add a bullet under [Unreleased] in CHANGELOG.md in the appropriate
section (Added / Changed / Deprecated / Removed / Fixed / Security).
Breaking changes MUST be in the Changed section with an explicit
migration note.
-->

- [ ] `CHANGELOG.md` updated under `[Unreleased]`

## Related issues

<!-- e.g. Closes #42, Addresses #56. -->

---

<!--
Reviewer checklist (do not remove):

  - [ ] No unreferenced FIXME / TODO / HACK in this PR's diff
        (CI lint will flag these too)
  - [ ] No new `.package(url:)` entries in Package.swift
  - [ ] PR title follows conventional-commit format:
        `<type>(<scope>): <description>`
-->
