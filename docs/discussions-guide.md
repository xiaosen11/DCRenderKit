# GitHub Discussions Guide

GitHub Discussions is the DCRenderKit project's forum for questions,
ideas, and longer-form conversation that doesn't fit the bug-report /
feature-request shape of an Issue. This document is the intended
layout plus the posting / moderation conventions. The actual
Discussions page is enabled by the repository owner from the GitHub
UI — see §5 below for the one-time setup steps.

---

## 1. Discussions vs. Issues vs. PRs

Which place to post is rarely ambiguous once the question is sharpened,
but the SDK's interface does blur the line in a couple of spots.
Use this mapping:

| Signal                                                  | Destination      |
| ------------------------------------------------------- | ---------------- |
| "I hit this crash / wrong output with steps X / Y / Z." | **Issue** (bug) |
| "Please add support for filter X / API Y."              | **Issue** (enhancement) — open a Discussion first only if the scope is exploratory |
| "How do I chain FilmGrain after my own filter?"         | **Discussion** (Q&A) |
| "I shipped my app using DCRenderKit and wanted to share the before/after." | **Discussion** (Show-and-tell) |
| "What if we added an OpenCL backend for Linux?"         | **Discussion** (Ideas) |
| "I'm curious why the default intermediate format is `.rgba16Float`." | **Discussion** (General) |
| "Here's a PR implementing X."                           | **Pull request** — referenced from any related Discussion |

If you start in the wrong place we'll move the post — no penalty.

---

## 2. Category layout

The recommended categories, in the order they should appear in the
sidebar:

### 2.1 Q&A

**Purpose**: help requests, integration questions, debugging
questions that lack a reproducible crash.

**Format**: discussion-with-answer. The asker (or a maintainer) can
mark one reply as the accepted answer; Discussions will surface
that answer at the top of the thread for future readers.

**Good post example**:

> "I'm rendering a `Pipeline` into a `MTKView`'s drawable using
> `encode(into:writingTo:)`. The result looks gamma-compressed
> compared to the source. I'm running `.linear` colour space. What
> drawable pixel format should I use?"

**Bad post example** (belongs in Issues):

> "My app crashes when I call `pipeline.outputSync()`. Stack trace
> below."

### 2.2 Show-and-tell

**Purpose**: share apps / projects using DCRenderKit, interesting
filter chains you've composed, before/after screenshots, performance
results on specific devices.

**Format**: discussion (no accepted answer). Upvotes work as
appreciation.

**Good post example**:

> "Built a film-look editor for iPad using the Tier 3 filter chain
> `[HS, Clarity, SoftGlow, FilmGrain]`. Here's the CCD-style
> preset I ended up with and a couple of before/after frames…"

### 2.3 Ideas

**Purpose**: exploratory feature requests that aren't yet concrete
enough for an Issue. "Would it be useful if…" class posts. Once an
Idea has a clear scope and a use case, a maintainer will move it
to an Issue.

**Format**: discussion (no accepted answer). Upvotes help us
prioritise.

**Good post example**:

> "Idea: a built-in `BloomFilter` variant that applies in post-
> compositing rather than as a filter step. Would let downstream
> blends work on the un-bloomed image."

**Bad post example**:

> "Bug: bloom is too strong at slider 100."  ← belongs in Issues.

### 2.4 General

**Purpose**: everything else. Design-philosophy discussions,
colour-space rabbit holes, announcements, off-topic-but-adjacent
conversation.

**Format**: discussion (no accepted answer).

**Good post example**:

> "The `.linear` vs `.perceptual` toggle in `DCRenderKit` made me
> curious about how other SDKs handle intermediate precision. Here
> are three I compared against…"

---

## 3. Posting guidelines

Low bar, high value:

- **Search first.** GitHub's discussion search covers titles and
  bodies; spend 30 seconds checking before posting a question.
- **State the SDK version** if the question touches runtime
  behaviour (`DCRenderKit.version`, Xcode version, target platform).
- **Share code snippets or pipeline configurations** if the question
  depends on them. Pseudo-code is fine; we don't need your whole
  project.
- **Don't mix questions.** One post = one topic. Multi-topic posts
  fragment into unfindable answers.
- **Be specific in titles.** "Why is my output dark?" gets far
  fewer responses than "Why does `ExposureFilter(exposure: -50)`
  clip harder than expected in `.linear` mode?".
- **Close the loop.** If your question got solved in chat and you
  don't post a follow-up, future readers with the same question
  have no way to know. A one-line "turned out it was X — thanks"
  is worth a lot.

---

## 4. Moderation

The code of conduct from [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md)
applies — be respectful, no harassment, good-faith participation.

Specific to Discussions:

- **Spam / promotional-only posts** (app store ads unrelated to
  DCRenderKit use, crypto posts, commercial service pitches) are
  locked and deleted without warning.
- **Off-topic drift** in a thread gets a gentle maintainer nudge.
  If the new topic is interesting, suggest a new Discussion for it.
- **Stale Q&A** (no answer after 60 days, original asker unreachable)
  gets a "ping" comment. After another 30 days with no movement,
  the Discussion is closed with status `outdated`. Closing is not
  deletion; the thread is still searchable.
- **Questions that clearly belong in Issues** are converted (GitHub
  supports this natively) rather than answered in place.
- **Duplicate Discussions** are closed with a pointer to the canonical
  thread.

Maintainers use their own judgement on edge cases. Please flag
anything you think crosses a line.

---

## 5. Enabling Discussions (one-time, repo owner)

GitHub turns Discussions off by default. To enable:

1. Go to the repository **Settings** tab.
2. Under **Features**, tick **Discussions**. The Discussions tab
   appears in the repository's top nav.
3. Navigate to the new **Discussions** tab.
4. Click the ⚙ icon next to **Categories** and remove the default
   categories that don't match the layout above
   (e.g. "Announcements" and "Polls" unless you want them).
5. Add these four categories in this order, with the matching format:

   | Category     | Format                       |
   | ------------ | ---------------------------- |
   | Q&A          | Discussion (question/answer) |
   | Show-and-tell | Open discussion             |
   | Ideas        | Open discussion              |
   | General      | Open discussion              |

6. For each category, paste the purpose description from §2 above
   into the category's description field — shows up as a tooltip and
   in the "new post" template hint.
7. Save.

### Welcome post

After categories are configured, pin a single welcome Discussion in
General linking to this guide, CONTRIBUTING, and the CODE_OF_CONDUCT.
Template:

```markdown
# Welcome to DCRenderKit Discussions

This is the place for questions, ideas, show-and-tell, and longer
conversation that doesn't fit an Issue.

- **Looking for help?** → Q&A category
- **Built something cool?** → Show-and-tell
- **Got a feature idea?** → Ideas (once it has a scope, we'll
  convert to an Issue)
- **Everything else** → General

Please read [docs/discussions-guide.md](…/discussions-guide.md) for
posting conventions and [CODE_OF_CONDUCT.md](…/CODE_OF_CONDUCT.md)
for participation rules.

Pinned so it stays at the top of General.
```

---

## 6. Cross-references

- [CONTRIBUTING.md](../CONTRIBUTING.md) — how to contribute code /
  file issues / open PRs.
- [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) — behavioural
  expectations applicable to all channels.
- [SECURITY.md](../SECURITY.md) — **do not** file security-sensitive
  reports as public Discussions; use the private advisory form.
- [docs/maintainer-sop.md](maintainer-sop.md) — maintainer-facing
  triage and release playbook; §5 touches on the Discussions close
  policy from a maintainer angle.
