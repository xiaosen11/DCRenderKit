# DCRenderKit Maintainer SOP

Operational playbook for project maintainers. Covers PR review,
release cutting, breaking-change bookkeeping, and security-response
coordination. The audience is the person merging PRs and tagging
releases — not the day-to-day contributor, who should read
[CONTRIBUTING.md](../CONTRIBUTING.md) instead.

If a process in here conflicts with a published rule in
`.claude/rules/*.md`, the rule wins; the rules are hard constraints
and this document is the operational overlay.

---

## 1. PR review checklist

Run every PR through the list. Items are ordered by cost — cheap
checks first so an obvious failure doesn't waste reviewer time on
line-by-line commentary.

### 1.1 Gate checks (CI must be green before human review)

- [ ] GitHub Actions `test` job passes (`swift build` + `swift test`,
      macOS-15 runner with Xcode 16).
- [ ] GitHub Actions `ios-build` job passes (`xcodebuild` against the
      iOS Simulator SDK).
- [ ] Lint job is clean — bare `FIXME` / `TODO` / `HACK` without a
      `(§…)` or `(#…)` reference is a hard fail; `.package(url:…)` in
      `Package.swift` is a hard fail.

Any of those red → send back to the contributor before reviewing
substance.

### 1.2 Scope review

- [ ] PR title uses conventional-commits format
      (`<type>(<scope>): <description>`, types per CONTRIBUTING.md).
- [ ] PR body states the problem, the chosen approach, and the
      trade-offs considered. "Fix X" without context is returned for
      a description rewrite rather than merged and forgotten.
- [ ] Changes stay inside the stated scope. A `fix` PR quietly
      refactoring an unrelated module gets split.

### 1.3 Code substance

- [ ] Tests added / updated. New filters need at minimum an identity,
      an extreme-value, a direction/monotonicity, a numeric assertion
      with a derived expected value, and (for Tier 3) a contract test
      (see `.claude/rules/testing.md` §1.5).
- [ ] For any new Metal kernel: the bounds check at the top of the
      kernel is present; per-shader uniform struct layouts are kept
      in sync with the Swift `FilterUniforms` struct; `Foundation/*`
      MIRROR blocks stay in sync if they're touched.
- [ ] New public APIs are annotated for iOS availability (the
      `@available` sweep from #47 is the expected baseline once
      complete).
- [ ] SwiftDoc is present for every new public symbol. For filter
      structs, the `Model form justification` block documents the
      algorithm choice and at least one alternative considered (see
      `.claude/rules/filter-development.md`).

### 1.4 User-visible change bookkeeping

- [ ] `CHANGELOG.md` has an `[Unreleased]` entry describing the
      user-visible change. Internal refactors with no API / behaviour
      impact don't need one but benign misses are cheap to amend.
- [ ] **Breaking changes are flagged explicitly** in `[Unreleased] →
      Changed (breaking)` or `Removed (breaking)`, with a migration
      note describing what consumers must change. See §3 below.
- [ ] For Tier 3 filter changes: the relevant `docs/contracts/*.md`
      is updated if the contract's clauses shift. Contract revisions
      must be reviewed alongside the code.

### 1.5 Decision journal

- [ ] If the PR resolves a debate or encodes a non-obvious trade-off,
      the reasoning lives in the PR body and the commit message, not
      just Slack / meeting notes. Future maintainers read
      `git log -p` more than Slack.

### 1.6 Approval

- [ ] At least one maintainer approval. Two is preferred for
      public-API changes; one is acceptable for internal refactors.
- [ ] Squash and merge is the default. Merge commits are reserved
      for PRs that contain a meaningful commit-by-commit progression
      and whose author asks for it.

---

## 2. Release cut

DCRenderKit follows [SemVer 2.0.0](https://semver.org). Pre-`v1.0.0`
releases ship with breaking changes inside the `0.x` series; post-`v1.0.0`
they trigger a major bump.

### 2.1 Pre-cut gate

Pre-release criteria are enumerated in
[`docs/release-criteria.md`](release-criteria.md). Before cutting,
walk the three tiers and pick which one this release commits to:

- **Tier 1 — Minimal viable**: SDK compiles, all tests pass,
  documentation present. Safe to tag an `-rc` on this alone.
- **Tier 2 — Consumer-grade**: Tier 1 + the `@available` sweep, the
  API freeze review, SwiftDoc completeness, zero-warning build. This
  is the target for every public `0.x.0` release.
- **Tier 3 — Visual-quality committed**: Tier 2 + real-device baseline
  approval for the Tier 4 aesthetic filters (FilmGrain / CCD /
  PortraitBlur snapshot freeze `#37 / #38 / #39`). Required before
  `v1.0.0`; optional before that.

The release notes should state which tier the release meets.

### 2.2 The cut itself

1. **Sanity**: on `main` (or the release branch), run:
   ```
   swift build -warnings-as-errors
   swift test
   ```
   Both must be green. If either is red, stop — you're not cutting
   a release today.
2. **Roll the `[Unreleased]` heading**: edit `CHANGELOG.md` and move
   the current `[Unreleased]` block under a new heading
   `## [X.Y.Z] - YYYY-MM-DD`. Create a fresh empty
   `## [Unreleased]` block above it.
3. **Bump the version constant**:
   ```swift
   // Sources/DCRenderKit/DCRenderKit.swift
   public static let version = "X.Y.Z"
   public static let channel = "release"   // or "dev" for -rc / -beta
   ```
4. **Commit**: `chore(release): v<X.Y.Z>` with the CHANGELOG diff and
   the version bump in one commit. Do not include unrelated changes.
5. **Tag**: `git tag -s v<X.Y.Z> -m "v<X.Y.Z>"` — signed tags preferred
   when the maintainer's GPG key is configured; plain annotated tags
   are acceptable.
6. **Push**: `git push origin main` then `git push origin v<X.Y.Z>`.
   Pushing main first ensures CI for the release commit runs before
   the tag lands; if CI fails the tag is easier to retract.
7. **GitHub Release**: create a GitHub Release from the tag, paste
   the new CHANGELOG block as the body, and mark it
   "pre-release" for anything < `v1.0.0`. Once the release automation
   from `#62` lands, steps 7 and the body-paste become automatic.
8. **Bump to next dev version**: immediately after, bump
   `DCRenderKit.version` to the next tentative release suffixed
   `-dev` (e.g. `0.2.0-dev`) and set `channel = "dev"`. Commit.

### 2.3 Retracting a release

If post-release triage reveals a showstopper before meaningful
adoption (hours, not days), the right move is a patch bump with the
fix (`0.1.0` → `0.1.1`), not a retraction. Published tags stay
published; GitHub Releases can be marked "yanked" by editing the
release notes to say so.

For genuinely broken tags (accidental push), `git push --delete
origin v<X.Y.Z>` + delete the GitHub Release is acceptable only if
no consumer has downloaded the tarball. After any downloads we follow
the patch-bump path above instead.

---

## 3. Breaking-change registration

DCRenderKit is pre-`v1.0.0`, so breaking changes are allowed inside a
`0.x` series provided they are documented.

### 3.1 What counts as breaking

- Removing or renaming a `public` symbol.
- Changing the type of a `public` property or method parameter.
- Changing the return type of a `public` method (adding a `?` is
  breaking for callers that treat the old non-optional return as
  non-nil).
- Changing observable runtime behaviour for unchanged inputs — e.g.
  the Session C Tier 2 tone operator rewrites. The API signature
  didn't shift but the output curve did.
- Moving a filter from `FilterProtocol` to `MultiPassFilter` — the
  call site must change from `.single(filter)` to `.multi(filter)`.

### 3.2 What does NOT count as breaking

- Adding a new `public` symbol.
- Relaxing a precondition (changing `@available(iOS 18.0, *)` to
  `iOS 17.0`).
- Internal refactors that leave public output bit-identical on
  representative inputs.
- Documentation, tests, or internal tooling changes.

If a change is ambiguous (subtle output drift that might be visible
on some input), treat it as breaking and log it; costs of over-logging
are low, costs of a silent regression hitting a consumer are high.

### 3.3 Logging the change

Every breaking change must land in `CHANGELOG.md` under
`[Unreleased] → Changed (breaking)` or `Removed (breaking)` with:

1. **What changed** — class and method names, before/after.
2. **Why it changed** — commit / PR reference, principled
   justification.
3. **Migration path** — the exact diff consumers should apply
   (renamed symbol, removed parameter, new semantic). Link to the
   relevant PR for extended rationale.

Worked examples live in the current `[Unreleased]` block of
`CHANGELOG.md` (Session C Tier 2 rewrites and the `macOS` strip).

### 3.4 Communicating to consumers

When a breaking change lands on `main` but before the next release:

- Keep `[Unreleased]` up to date so consumers following `main` can
  preview the migration.
- The release commit's `CHANGELOG.md` diff is the canonical
  "migration checklist" for the release.
- For consumers we know about (currently: DigiCam), flag the
  breaking change in the PR body so downstream rollout happens on
  the consumer's own schedule. Do not block the SDK release on the
  consumer's migration.

---

## 4. Security response

Covered in detail by [`SECURITY.md`](../SECURITY.md). This section
is the operational complement.

### 4.1 Intake

1. A private security advisory lands via the GitHub security tab.
   Subscribe to the repository's security alerts so these surface
   promptly.
2. Acknowledge within the SLA band (see SECURITY.md). A template
   response is fine — the important thing is "yes, we see it,
   tracking it".
3. Triage severity using SECURITY.md's rubric. If unclear, assume the
   next bucket up and downgrade later rather than the reverse.

### 4.2 Fix workflow

1. **Work the fix on a private branch** if the issue is reachable
   from a consumer app's normal API surface. The security advisory
   UI supports "working privately in a fork" — use it.
2. Write a regression test that exercises the vulnerable path.
   Failing → passing is the evidence the fix is real.
3. Update `CHANGELOG.md` `[Unreleased]` with a brief, non-disclosing
   entry: "`CubeFileParser`: reject malformed LUT headers that were
   not previously rejected (sec advisory GHSA-…)". Link the
   advisory, not the exploit.
4. Merge the fix **before** the advisory goes public, and cut a
   patch release immediately.

### 4.3 Disclosure

1. Publish the security advisory with the fix's version listed.
   Credit the reporter unless they've asked to stay anonymous.
2. Request a CVE via GitHub if the issue meets the usual bar
   (reachable from a consumer app without explicit misuse by the
   consumer).
3. Tag `v<X.Y.Z+1>` and mention the advisory in the release notes.

### 4.4 When in doubt

Err on the side of confidentiality during the fix window and
transparency after disclosure. Consumers want to know *what* shipped
and *how* to upgrade, not a post-mortem of how the bug got in —
reserve that for a follow-up blog post if it's educational.

---

## 5. Issue triage

### 5.1 Labels

The repository uses the default GitHub label set augmented with:

- `bug` — reproducible incorrect behaviour.
- `enhancement` — new feature request.
- `question` — support-like requests; consider redirecting to
  Discussions.
- `tier-1` / `tier-2` / `tier-3` / `tier-4` — which filter tier the
  issue touches (use only when obvious from the title).
- `good-first-issue` — small, well-scoped tasks suitable for a new
  contributor.
- `blocked-on-real-device` — fix requires physical-device evaluation
  (typically the Tier 4 snapshot baselines `#37 / #38 / #39`).

### 5.2 Closing policy

- Issues stale 90 days with no reproduction get a "ping" comment.
  After another 30 days with no response, close with
  `closed as not reproducible`.
- Invalid reports (misuse, not a DCRenderKit issue) close with a
  brief explanation. Offer to move the conversation to Discussions
  if the user genuinely needs help.
- Duplicate reports close immediately with a link to the canonical
  issue.

### 5.3 Prioritisation

Weekly (or as often as issue load demands):

1. Triage new issues into labels.
2. Review `blocked-on-real-device` issues for any whose blocker has
   been resolved by a recent real-device session.
3. Surface critical bugs to the next release cycle's milestone.

---

## 6. Decision log

Maintainers making non-obvious decisions (scope changes, rule
revisions, convention choices) should leave a paper trail:

- For decisions that affect ongoing work, add a line to
  `docs/session-handoff.md` §6 (drift / edge cases).
- For decisions that become hard constraints, file a new
  `.claude/rules/<name>.md` and cross-reference it from the PR that
  establishes the rule.
- For decisions that only matter to the maintainer themselves
  (tooling preferences, internal process tweaks), update this SOP
  with a commit message explaining the change.

Session handoffs (`docs/session-handoff.md`) are the authoritative
record of state for multi-session work; this SOP captures process
that outlasts any single session.
