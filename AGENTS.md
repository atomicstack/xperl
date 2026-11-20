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

## Implementation language and dogfooding

Do not add Python scripts, embedded Python, or Python dependencies to the
Perl project. Write project tooling in Perl. Replace existing project Python
tools with Perl when working on them.

Use the interpreter being developed for agent work wherever practical. In a
built checkout, run scripts and one-liners with `./perl -Ilib` so we exercise
the target branch's interpreter. Occasional external helpers are acceptable
when they save substantial hassle, but do not save Python in the project or
introduce it as a project dependency. Keep any exceptional scratch helpers
outside the source tree.

## Project and upstream boundaries

This working repository holds branches for two distinct projects, Perl5 and
its sister fork XPerl. A checkout directory does not identify the project.
Before editing, identify the target from the user's request, branch ancestry,
codebase, and configured remotes. Verify the branch's upstream and intended
push destination. Do not infer the destination from the directory name.

Shared rules, including Perl tooling, readable code, and explanatory commit
messages, apply to both projects. Project-specific rules apply only to their
own branches:

- Perl5 branches target Perl5 upstream and follow Perl5's features, APIs,
  compatibility requirements, and contributor workflow. Keep their patches,
  comments, tests, documentation, commit messages, and PR descriptions free
  of XPerl references and dependencies. Do not apply XPerl-specific skills or
  conventions to Perl5 work.
- XPerl branches target XPerl upstream and use XPerl's interpreter, features,
  APIs, and applicable skills. Keep changes suitable for Perl5 separable
  from changes to fork-specific behavior, as described above.

When moving a change between projects, review and adapt it for the receiving
project. Recheck its wording, dependencies, tests, and upstream destination.
Do not treat a backport or forward port as a change of project identity for
the original branch.

## Commit messages

Use a concise explanatory voice. Start with the purpose and intended
outcome, then explain the broad change and why it achieves that outcome.
Give the reason and effect as much attention as the implementation. Keep
the message as short as the explanation allows. Avoid inventories of facts,
files, edits, or implementation details. Include detail only when it helps
a future reader understand a design decision or constraint.

Passing tests are expected. Do not report test counts or routine validation
results in commit messages. Mention added or removed test files and explain
new coverage at a high level when relevant.

Compose messages with `git-compose-commit`. Use its structured paragraphs,
details, lists, tables, or footers when they help tell the narrative, rather
than forcing every message into the same format. Do not use structure to
turn the explanation into a change inventory. If the tool is unavailable,
tell the user instead of silently substituting `git commit -m`.

## Code readability

Write readable code in every language, including scripts and one-liners
saved as project tools. Separate logical sections and distinct thoughts
with whitespace. Avoid dense walls of statements or compressed expressions
that make control flow difficult to follow. Use section comments or line
ending comments where they explain purpose, constraints, or a surprising
step. Do not add comments that merely repeat the code.

## Comment and commit quality

High-quality comments and commit messages are a requirement. Before
finalizing either, review the text against the applicable writing rules.
Check technical accuracy, clarity, purpose, outcome, and project identity.
Remove unsupported claims, redundant wording, and unnecessary detail.

For subtle, consequential, or uncertain explanations, obtain a second
review from a more capable agent or a human when needed. Give the reviewer
the relevant code and rules. Resolve substantive concerns before treating
the text as ready. Do not substitute a claim of review for an actual review.

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
