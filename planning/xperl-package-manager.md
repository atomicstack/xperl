# XPerl Package Manager and CPAN Compatibility System

## Purpose

Build a small package manager in XPerl that keeps the CPAN ecosystem usable as
XPerl changes its language and internals. The installer is also a bootstrap
project for XPerl itself: its implementation should use XPerl features in real
work, expose rough edges, and feed those findings back into the language,
libraries, diagnostics, and documentation.

The first useful result is an ordinary CPAN installer. Compatibility patches,
AI-assisted porting, and patch sharing are layers added to that working path.
Installing an unaffected distribution must not require an AI service or access
to an XPerl patch registry.

The first end-to-end target is installing `Sereal::Decoder` and
`Sereal::Encoder` through this infrastructure. They are separate CPAN
distributions with XS code. Success means the installer resolves their
dependencies, builds and tests both under XPerl, installs them into an
isolated prefix, and runs an encode/decode round trip from that prefix.

## Current checkpoint (2026-11-05)

The source-tree installer now reaches that target on x86_64 Linux with the
current CPAN releases, `Sereal::Decoder` 6.003 and `Sereal::Encoder` 6.003.
A fresh-cache, fresh-prefix run installed Decoder and its declared required
dependencies, then Encoder, with each distribution's test phase passing. An
encode/decode round trip loaded both XS modules from the new prefix. The
installer used three local registry patches: two for test-suite assumptions
in dependencies and one for Encoder's hash-entry traversal. The original
archives remain unchanged, and receipts record the source and patch hashes.

This checkpoint covers the local registry and `Makefile.PL` path. Remote
registry updates, `Build.PL`, opt-in agent repair, and patch proposal tooling
are later stages. The version ranges in the registry describe applicability;
the evidence records what has actually been tested.

## User workflow

```text
xperl install Module::Name
    -> resolve the CPAN distribution and recursive prerequisites
    -> download and verify its original release
    -> discover applicable XPerl patches, if a registry is configured
    -> apply patches to a working copy
    -> configure, build, test, and install with the running XPerl
    -> write a reproducible installation record

If build or tests fail and the user enabled an external agent:
    -> classify the failure and supply relevant migration recipes
    -> let the agent modify the working copy
    -> rebuild and retest within explicit attempt and time limits
    -> install only after the normal checks pass
    -> prepare a reviewable patch against the original CPAN release
```

The command should print the distribution, version, current phase, applied
patches, and location of the build log. Failures should identify the failed
command and preserve enough context to reproduce it. An opt-in machine-readable
result should expose the same information to other tools and agents.

## Architectural boundaries

- Implement the installer in XPerl, using its interpreter for metadata parsing,
  dependency decisions, subprocess management, and CLI behavior. Use XPerl
  features where they make the code clearer. `dispatch/on` is a specific
  feature to exercise for command routing, result handling, or diagnostic
  classification. Signatures, classes, and structured exceptions are further
  candidates when their current contracts suit the code.
- Keep the installer small and self-contained. Prefer bundled `HTTP::Tiny`,
  `CPAN::Meta`, `CPAN::Meta::Requirements`, `Archive::Tar`, `Digest::SHA`, and
  `ExtUtils::MakeMaker` where appropriate. Avoid importing cpanm, cpm, Menlo,
  or their dependency trees as the implementation.
- Keep CPAN installation, compatibility lookup, automated porting, and patch
  publication separate. The ordinary installation path must work when the
  other components are disabled or unavailable.
- Build from untouched upstream release archives. Apply compatibility patches
  only to disposable working copies. Preserve the source archive, its hash,
  and the ordered patch list so that a build can be repeated.
- Keep the external AI agent behind a documented command or protocol. The
  installer owns build and test decisions; it does not embed a particular
  provider or accept an agent's assertion of success without rerunning checks.
- Treat registry entries and agent edits as untrusted inputs. Validate archive
  paths, patch paths, hashes, and version applicability before use. Never run
  release-provided build scripts before the user has requested installation.

## CPAN installation path

Resolve module names through CPAN package metadata, choose a distribution,
download its release archive, and check its available digest. Cache metadata
and downloads so repeat installations do not fetch unchanged data. Support
an explicit distribution version or release path for reproducibility.

Read `META.json` or `META.yml` and install required configure, build, test,
and runtime prerequisites recursively. Check installed versions against each
requirement, detect dependency cycles, and report conflicting constraints.
Document how optional and recommended prerequisites are handled. Distributions
with incomplete or dynamic metadata need a clear fallback and diagnostics.

Run the distribution's declared build system with the same XPerl executable
that launched the installer. Support `Makefile.PL` and XS builds first, then
`Build.PL` where its build tool is available. Capture configure, compile, and
test output separately. Failed tests block installation unless the user gives
an explicit override. Provide an installation prefix or local-library option
so users can install without changing the XPerl installation itself.

Network access is available during development and may be used for live CPAN
integration tests. Keep a small local fixture for deterministic tests of
resolution, dependency ordering, patch selection, and failure handling.

## Compatibility registry

Maintain a shared registry of patches against original CPAN releases. An
entry identifies the distribution, its upstream version, the applicable
XPerl version range, the source archive digest, patch digest, and any relevant
platform or build constraints. Patch application order must be explicit.
An exact archive digest takes precedence over a loose name and version match.
The installer should refuse ambiguous or mismatched entries and explain why.

Keep the registry format inspectable and easy to review in Git. The first
implementation can read a local checkout or cached registry snapshot. Remote
lookup and update can follow without changing the ordinary installer path.
The installer records the registry revision or snapshot and every applied
patch digest in its installation record.

Prefer fixes that continue to work on ordinary Perl. Where XPerl-specific XS
code is necessary, use the existing `XPERL` preprocessor symbol after
including Perl headers, for example with `#ifdef XPERL`.

### Proposed registry shape (draft)

Index by CPAN distribution rather than module name: several modules can come
from one release, and a patch applies to the release source tree. A first Git
layout could be:

```text
registry/
  distributions/
    Example-XS/
      index.json
      patches/
        hash-api-v1.patch
  recipes/
    hash-storage-v1.md
```

The installer first resolves a module through CPAN, then reads only that
distribution's registry index. The paths in this example are illustrative:

```json
{
  "schema": 1,
  "distribution": "Example-XS",
  "releases": [
    {
      "version": "4.40",
      "cpan_path": "E/EX/EXAMPLE/Example-XS-4.40.tar.gz",
      "source_sha256": "<digest of the original archive>",
      "patch_sets": [
        {
          "id": "hash-api-v1",
          "xperl": {
            "min_inclusive": "v5.45.0",
            "max_exclusive": "v5.47.0"
          },
          "patches": [
            {
              "path": "patches/hash-api-v1.patch",
              "sha256": "<digest of the patch>"
            }
          ],
          "recipes": ["hash-storage-v1"]
        }
      ]
    }
  ]
}
```

The installer checks the distribution name, exact CPAN archive path and source
digest, XPerl version interval, and every patch digest before applying a set.
The patch array defines application order. Optional platform or build
selectors can be added only when an actual patch needs them. Two matching
patch sets for the same release are an error unless their relationship and
order are explicit. A release with no matching patch set follows the ordinary
CPAN installation path.

Keep test evidence in a separate reviewable record keyed by patch-set ID,
source digest, and XPerl build. This avoids treating a past successful test as
a promise for every platform or later XPerl version. The installation receipt
records the registry revision, patch-set ID, and digests actually used.
Proposed patches and recipes enter the Git registry through review, not through
an automatic write from the installer.

## AI-assisted porting and recipes

Agent assistance is opt-in and starts only after a build or test failure.
Give the agent the original release identity, working tree, failed command,
logs, XPerl version and configuration, active patches, relevant recipes, and
a bounded task: modify this distribution until the installer can build and
test it. Cap attempts and elapsed time, and retain all attempts and results.
The installer reruns configuration, build, and tests after each edit.

Migration recipes describe recurring incompatibilities, their symptoms,
affected XPerl versions, preferred source changes, compatibility constraints,
and a small validation example. Hash representation changes are an initial
recipe candidate. Recipes guide agents; they are not automatically applied
as source patches. A failed agent run should leave useful diagnostics and its
working tree for inspection without installing a broken distribution.

When a port passes, generate a patch against the untouched release. Save the
source hash, XPerl version, build and test results, and agent provenance with
the proposal. Submission to the shared registry is an explicit review step;
the installer should prepare a contribution without publishing it by default.
Reviewers can improve the patch, verify ordinary Perl compatibility where
practical, and add or revise a recipe when the failure is reusable.

## Dogfooding loop

For each implementation stage, record which XPerl features the installer uses
and any defects or friction it reveals. Turn those findings into focused
language, library, diagnostic, test, or documentation changes when justified.
Keep package-manager work and core-feature fixes in small reviewable changes.
The installer should provide real examples for XPerl documentation rather
than use a feature solely to demonstrate its syntax.

## Delivery stages

1. **Resolve and fetch:** implement the XPerl CLI and CPAN release lookup,
   download, digest calculation, cache, and archive validation. Exercise
   `dispatch/on` in command routing. Test against a pinned small release and
   the two Sereal archives without running release code.
2. **Pure-Perl install:** configure, build, test, and install a small
   pure-Perl release into an isolated prefix using the running XPerl. Keep
   phase logs and a receipt; refuse to install after failed tests.
3. **Prerequisites:** read `META.json` and `META.yml`, recursively install
   required configure, build, test, and runtime modules, check version
   constraints, and detect cycles. Use a clean prefix to expose hidden
   dependencies.
4. **XS builds:** use the selected XPerl executable, headers, configuration,
   and toolchain for `Makefile.PL` and representative XS modules. Add the
   supported `Build.PL` path when its build tool is available.
5. **Sereal acceptance:** install `Sereal::Decoder` and then
   `Sereal::Encoder` through the installer, with no manual build or dependency
   step. Diagnose any XPerl-specific failure and keep a reproducible baseline.
6. **Known compatibility patches:** define the registry schema, local lookup,
   XPerl version selection, safe patch application, and recorded patch hashes.
   If Sereal needs a patch, use it as the first real registry entry and rerun
   the acceptance test through the normal installer path.
7. **Assisted porting:** define the external-agent protocol and stopping rules,
   add migration recipes, and verify every agent edit with the same build and
   test path.
8. **Community reuse:** produce reviewable patch and recipe proposals, add a
   registry contribution workflow, and make accepted fixes discoverable to
   later installs.

At each stage, validate the XPerl-specific behavior with focused tests and
exercise representative real CPAN releases over the network. Record the exact
release, XPerl build, commands, and outcomes for those live checks.

### Sereal acceptance test

Pin the first live run to the `Sereal-Decoder-6.003` and
`Sereal-Encoder-6.003` CPAN releases, published on 31 October 2026. Record
their archive digests at download time. Later runs may update the target
versions deliberately, but must state the new release identities.

Baseline recorded on 5 November 2026 from the original CPAN archives:

| Distribution | Archive SHA-256 | Required non-core prerequisites |
|---|---|---|
| `Sereal-Decoder-6.003` | `2e6908af638b34b1f381019b0de1fd6dabf67b0fd2efcc030bfb3e2f7d8ce45b` | `Devel::CheckLib >= 1.16` for configure; `Test::Deep`, `Test::Differences`, `Test::LongString`, `Test::Warn` for tests |
| `Sereal-Encoder-6.003` | `217de2b585aaf183368a4a54c1adbffae78cc30b7430ad55c59a48d3ca33b30b` | The same configure and test modules, plus `Sereal::Decoder >= 6.003` for runtime and tests |

These prerequisites come from each release's `META.json`. The current built
XPerl has `ExtUtils::MakeMaker` and `ExtUtils::ParseXS`, but lacks the listed
non-core modules and both Sereal modules. This is a metadata and installed
module inventory, not a build or test result. The archived inputs are in the
workspace's `tmp/xperl-installer-cache/` directory.

From a clean prefix and cache, run the equivalent of:

```text
xperl install --prefix <isolated-prefix> Sereal::Decoder
xperl install --prefix <isolated-prefix> Sereal::Encoder
xperl -I<isolated-prefix>/lib/... -MSereal::Encoder -MSereal::Decoder \
    -e '<encode and decode a representative structure>'
```

The installer must invoke `Makefile.PL`, the compiler, and the test harness
using the selected XPerl build and configuration. It must install required
prerequisites recursively, report optional prerequisites, run each release's
test suite, and retain logs and receipts. The final round trip must load the
modules from the isolated prefix, not from a preexisting system installation.
The upstream Sereal release notes advise installing the Decoder before the
Encoder for version 6 protocol compatibility; the target order follows that
guidance.

Sources: [Decoder 6.003](https://metacpan.org/release/YVES/Sereal-Decoder-6.003),
[Encoder 6.003](https://metacpan.org/release/YVES/Sereal-Encoder-6.003), and
[Encoder release notes](https://metacpan.org/release/YVES/Sereal-Encoder-6.003/changes).

## Decisions to settle during implementation

- The installer command's packaging and installation location in the XPerl
  distribution. Avoid changing shared Perl build machinery solely for this
  feature without explicit authorization.
- The CPAN mirror and integrity metadata policy, including behavior when an
  upstream archive has no trusted digest.
- The registry's hosting, update mechanism, and trust model.
- The exact external-agent command protocol and how a user supplies agent
  credentials outside installer logs and records.
- The first supported non-Unix installation and XS build environments.
