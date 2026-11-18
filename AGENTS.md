# Perl Repository Agent Directives

This file gives repository-wide instructions for coding agents working on
Perl core. Apply these directives to every task unless the user explicitly
asks for a different approach.

## Prime Directives

- Keep changes to existing code or infra small, incremental, and reviewable.
- Prefer self-contained commits that include code, tests, documentation, and
  generated-file updates required by the change.
- Never put test-related counts in commit messages, including counts of tests,
  test cases, subtests, assertions, checks, or test files added or run, whether
  written as digits or words. It is fine to mention adding or updating tests,
  describe their coverage, or name new test files without counts.
  Omit routine validation summaries, including passing suites, successful
  builds, syntax checks, and clean diff checks. Only include those results in
  the PR description or work report or commit on specific request. Include
  validation details in a commit message only when they explain the change,
  a compatibility constraint, or a significant limitation.
- Make changes to modules maintained on CPAN in their upstream module
  repository. Do not patch the bundled copies under `cpan/` as part of a
  Perl-core change.
- On XPerl branches, separate fixes to inherited Perl blead code from fixes
  to XPerl-specific changes. Keep generic fixes and portable tests in commits
  suitable for blead, without mixing in XPerl syntax, functionality, or API
  adaptations. Mark those commits with `Blead-port: suitable` and explain
  the upstream applicability. Testing on blead and resolving migration
  conflicts can be a separate follow-up; the marker does not claim blead
  validation. Do not add this marker to commits made directly on blead or
  a blead-based feature branch. Determine whether a branch is XPerl from its
  codebase, not the checkout directory or branch name.
- Add or update tests for behavior changes, bug fixes, generated-file checks,
  and regression-sensitive refactors.
- Update documentation when behavior, APIs, diagnostics, build behavior,
  release process, or contributor workflow changes.
- Consider whether `pod/perldelta.pod` needs an entry for user-visible,
  downstream-visible, release-note-worthy, or maintainer-relevant changes.
- Preserve portability. Check platform READMEs, `hints/`, `Cross/`, EBCDIC,
  locale, threads, multiplicity, and non-Unix assumptions when relevant.
- Prefer existing Perl core patterns, helper macros, regeneration targets, and
  porting tools over new local conventions.
- Do not change shared porting, build, test, regeneration, or other generic
  infrastructure merely to accommodate a specific feature or distribution.
  Such changes require the user's explicit authorization.
- Do not hand-edit generated files without also identifying and running the
  generator, or documenting why regeneration is not appropriate.
- Keep public API, binary compatibility, and XS/embedding compatibility in mind
  for C and header changes.
- Add every new distribution file to `MANIFEST` with a short description, then
  run `make manisort`.
- Use focused validation first, then broaden. `make test_porting` is a good
  broad check for documentation, metadata, generated-file, and policy changes;
  for preliminary screening, `TEST_JOBS=N make -jN test_porting` is a
  reasonable parallel form.
- Use code archaeology when it helps explain bug reports, surprising behavior,
  compatibility constraints, or old design choices.

## Agent Skills

Repository-specific skill files live in `.agents/skills/`. Read the relevant
skill before editing the associated subsystem.

This is the canonical skill tree. From the sibling `perl_core_skillz`
repository, run `./sync-agent-skills --check` to verify its legacy mirror, or
use `./sync-agent-skills --sync` to update it. Use `--from-mirror` to restore
the guidance and skill tree to a Perl branch which does not contain them.

Generic skills are mirrored under `perl_agents/skills/`. Skills named
`xperl-*` apply only to XPerl and are mirrored under `xperl_agents/skills/`.
Use `--xperl` with the synchronizer to include those skills. Omit it when
restoring guidance for an ordinary Perl checkout.

## Tmux activity status

When working in the user's tmux session, follow
`.agents/skills/tmux-agent-status/SKILL.md`. Keep the tab colour and terminal
title symbol current for the whole agent team. Amber input waits take
priority over the five-operation cyan/green activity indicator.

## Core API design

When adding experimental core functionality, prefer a builtin function over a
new keyword whenever ordinary function-call syntax is sufficient. Reserve
keywords for constructs that require parser or compiler context. When a
feature needs both special syntax and associated callable builtins, provide a
small wrapper pragma that enables the feature and imports the builtins
together; keep the underlying feature and builtin mechanisms independently
usable.

## Companion instructions

`CLAUDE.md` is a concise pointer to this file and should not contain new
guidance; `AGENTS.md` contains the full repository guidance and is the place
to make changes.
