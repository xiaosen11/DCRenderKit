# Security Policy

## Scope

DCRenderKit is a local-only image-processing SDK. It does not perform
network I/O, does not read or write user credentials, does not call
authentication or cryptographic primitives, and does not decode
compressed image formats itself (it hands CGImage/CVPixelBuffer
decoding to the platform). The realistic threat surface is therefore
narrower than a typical networked library:

- Memory safety in the Metal / texture / buffer layer (out-of-bounds
  reads or writes, pool hazards, use-after-free) — callable from any
  consumer app that feeds DCRenderKit a filter chain.
- Parser robustness in `CubeFileParser` — the `.cube` file loader
  accepts caller-supplied text. A malformed file shouldn't trigger a
  crash, infinite loop, or unbounded memory allocation.
- Metal shader crashes on adversarial input textures (e.g. dimensions
  that bypass the bounds-check contract, unexpected pixel formats).

Issues outside that scope (application-level crashes a consumer app
could have caused itself without DCRenderKit, or Metal driver bugs on
a specific GPU generation) should go through the normal
[issue tracker](https://github.com/xiaosen11/DCRenderKit/issues)
rather than the private channel below.

## Supported Versions

DCRenderKit is pre-1.0. Security fixes land on the most recent
published `0.x` release.

| Version   | Status                                             |
| --------- | -------------------------------------------------- |
| `main`    | Fixes applied here and released promptly           |
| Latest `0.x` | Supported — security fixes backported if necessary |
| Prior `0.x`  | Not supported — update to the latest release   |

Once `v1.0.0` ships, this table will be expanded to carry an explicit
support window per major version.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security-relevant
reports.** Public disclosure before a fix lets the issue reach
adversaries before downstream consumers can update.

Use GitHub's private security advisory form:

> <https://github.com/xiaosen11/DCRenderKit/security/advisories/new>

Include:

1. A short description of the vulnerability.
2. Steps to reproduce (ideally a minimal `XCTestCase` or Swift
   Playground snippet that shows the bad behaviour).
3. Affected `0.x` versions, if known. If you only have `main`, say
   that.
4. Your assessment of impact (crash on malformed input / possible
   memory corruption / information disclosure / etc.) — not binding,
   just useful for triage.

If you don't have a GitHub account, open an anonymous gist with the
report and email the gist URL to the maintainer listed in the
repository's GitHub profile. Do not paste the report into a regular
issue.

## Response SLA

Times are wall-clock, measured from the advisory being filed. "Triage"
means an acknowledgement and severity assessment, not a fix.

| Severity        | Acknowledge      | Triage + assess | Fix target               |
| --------------- | ---------------- | --------------- | ------------------------ |
| Critical (RCE, memory corruption reachable from app consumers) | 2 business days | 5 business days | 14 days to a patched release |
| High (crash / DoS, data disclosure)                            | 3 business days | 7 business days | 30 days                      |
| Moderate (parser robustness, undefined behaviour without impact) | 5 business days | 14 business days | 60 days                    |
| Low (hardening, defence-in-depth)                              | best-effort     | best-effort     | next convenient release      |

If we miss an SLA we'll surface that to you on the advisory thread
with a reason. Consumer apps that can't wait are welcome to propose a
patch via the same private channel.

## Coordinated Disclosure

Once a fix ships, we'll publish a GitHub Security Advisory with
credit (or anonymously at your request). CVE assignment is filed
through GitHub when the issue is reachable from a consumer app
without explicit misuse by the app itself — i.e. the SDK is at fault,
not the integrator.

We ask for **at least 30 days** between the advisory being filed and
public disclosure, or until a fix ships, whichever is sooner.
Exceptions (accelerated disclosure for actively-exploited issues)
are negotiated on the advisory thread.

## Safe-Harbor for Researchers

Security research that targets DCRenderKit itself — reverse
engineering, fuzzing the `.cube` parser or Metal kernels, crafting
adversarial textures — is welcome. Please avoid running fuzzers
against third-party services that happen to host DCRenderKit-powered
apps; that's outside our scope and yours.

## Preventive Measures in the Codebase

The SDK is structured to minimise the attack surface these policies
cover:

- Zero external dependencies (guarded by
  `PackageManifestTests.testPackageHasNoExternalDependencies`) — no
  transitive vulnerabilities to track.
- Every compute kernel has a mandatory bounds check at the `gid`
  boundary (rule in `.claude/rules/` — CI lint blocks bare kernels).
- Typed error hierarchy (`PipelineError`) — no `NSError` or untyped
  failure modes reach callers.
- `CubeFileParser` validates `LUT_3D_SIZE` before allocating and
  rejects files whose data row count does not match `dimension^3`.
- `UniformBufferPool` is fenced per command buffer (historical fix
  for a ring-buffer overwrite that would have been a silent memory
  hazard under long filter chains).

Reports that exercise these checks successfully are the most valuable
kind — they indicate a gap we didn't anticipate.
