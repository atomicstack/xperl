# Mainline Perl and policy reference inventory

This document catalogs references in the XPerl tree to mainline Perl
development, Perl branches, P5P rules and policy, compatibility expectations,
and Perl build/version identity. It is an inventory for future policy work;
it does not prescribe changes and is not exhaustive at the individual-match
level.

## Core development assumes `blead`

Perl's porting tools commonly treat a branch named `blead` as the canonical
development branch:

- `make_patchnum.pl` detects `blead` and `maint/*` branches and records branch,
  remote, merge, commit, and Git-description information in generated metadata.
- `Porting/add-package.pl` creates package branches from `blead`.
- `Porting/bisect.pl` and `Porting/bisect-runner.pl` use `blead` as a default
  comparison endpoint and describe stable releases as its ancestors.
- `Porting/bench.pl` uses `blead` as the reference executable in examples.
- `Porting/core-cpan-diff` treats the Perl copy in `blead` as canonical for
  relevant distributions.
- `Porting/sync-with-cpan` describes synchronization between CPAN and copies
  in `blead`.
- `Porting/test-dist-modules.pl` has special handling for tests using blead's
  test infrastructure.

Other branch terminology appears in `Porting/make-rmg-checklist`, release
documentation, and historical comments: `maint/*`, `BLEAD-POINT`,
`BLEAD-FINAL`, `MAINT`, and release-candidate branches.

## P5P ownership and contribution policy

The principal references are:

- `Porting/Maintainers.pl`, which maps `UPSTREAM => 'blead'` modules to Perl 5
  Porters and defines P5P ownership;
- `Porting/corelist-perldelta.pl`, which identifies modules owned by P5P;
- `Porting/release_managers_guide.pod`, which describes release testing,
  announcements, synchronization, and changes sent to P5P;
- `Porting/perldelta_template.pod` and `pod/perldelta.pod`, which define the
  standard Perl release-note and compatibility language;
- `Porting/podcheck.t`, which recognizes blead links and CPAN/blead pod
  conventions.

There are also historical P5P references in contributor records, tests,
historical perldelta files, and bundled-distribution changelogs. Those are
usually attribution or historical record rather than active policy.

## CPAN versus blead ownership

The bundled-distribution machinery distinguishes at least these cases:

```text
UPSTREAM => 'blead'   Perl's copy is canonical.
UPSTREAM => 'cpan'    CPAN's distribution is canonical.
other values           Separate or special ownership models.
```

This model appears in `Porting/Maintainers.pl`, `Porting/core-cpan-diff`,
`Porting/sync-with-cpan`, `Porting/corelist.pl`,
`Porting/release_managers_guide.pod`, and `Porting/test-dist-modules.pl`.
It also governs customized files, CPAN version comparisons, upstream patches,
and which test infrastructure is authoritative.

## Versioning and release assumptions

The release machinery assumes Perl's traditional stable/development version
model:

- `Configure` uses odd/even version conventions and provides `-v`/`-V`;
- `patchlevel.h` defines the Perl revision, version, subversion, and version
  string;
- `make_patchnum.pl` generates branch, commit, snapshot, and Git metadata;
- `Porting/makemeta`, `Porting/makerel`, and `Porting/make-rmg-checklist`
  assume official Perl release numbering and release stages;
- `Porting/release_schedule.pod` and `Porting/release_managers_guide.pod`
  describe the traditional release cycle;
- `configpm`, `Config.pm`, and `lib/Config.t` propagate configured version
  information;
- `perl.c` produces `perl -v` and `perl -V` output;
- `installman`, `t/porting/copyright.t`, and `t/run/switches.t` validate
  version, copyright, and configuration output.

Users are directed to provide `perl -v` or `perl -V` output by `INSTALL`,
`utils/perlbug.PL`, `lib/Benchmark.t`, and `pod/perlembed.pod`.

## Configure and platform build assumptions

Configuration and platform-specific assumptions occur in:

- `Configure`, `configure.com`, `config_h.SH`, and `Makefile.SH`;
- `Cross/`, `Porting/config.sh`, and `Porting/config_H`;
- `plan9/`, `vms/`, `win32/`, and `hints/`;
- platform `README.*` files and installation scripts.

These references concern version and patchlevel, generated configuration,
version-specific `@INC` paths, compiler/platform compatibility, installation
paths, and release-file inclusion. They are not all language compatibility
policy.

## Backward compatibility has several meanings

The repository uses “compatibility” for at least three different concerns:

1. Perl language and runtime behavior;
2. C, XS, embedding, and binary interfaces;
3. operating-system, compiler, and platform behavior.

The XPerl mission explicitly relaxes the first category when useful, but
does not automatically imply relaxing the second or third. Active references
are found in `XPERL-MISSION.md`, `BLEAD-DELTA.md`, `AGENTS.md`,
`Porting/Glossary`, `Porting/pumpkin.pod`, `INSTALL`, `Configure`,
`Makefile.SH`, `perl.c`, `XSUB.h`, `handy.h`, `vutil.h`, and the bundled
distribution tests and Changes files.

## Tests and porting checks

The relevant infrastructure includes:

- `t/porting/podcheck.t`;
- `t/porting/copyright.t`;
- `t/porting/manifest.t`;
- `Porting/test-dist-modules.pl`;
- `Porting/core-cpan-diff`;
- `Porting/sync-with-cpan`;
- `Porting/bisect*.pl`;
- `Porting/bench.pl`;
- `Porting/make-rmg-checklist`;
- `Porting/release_managers_guide.pod`;
- `t/harness` and `cpan/Test-Harness/`.

Together these encode expectations about release contents, test selection,
CPAN/blead ownership, branch comparisons, generated files, and official Perl
release procedure.

## Generated identity and diagnostic output

Potentially user-visible branch or build identity is propagated through:

- `make_patchnum.pl`;
- generated `git_version.h` and `lib/Config_git.pl`;
- `perl.c`;
- `patchlevel.h`;
- `configpm`;
- `plan9/`, `vms/`, `win32/`, and `Cross/` configuration files.

This can expose branch names, Git descriptions, commit IDs, snapshot status,
Perl version, compiler options, target architecture, and configuration paths.
It should be considered if XPerl develops its own identity in `perl -v`,
`perl -V`, bug reports, crash output, or generated metadata.

## Historical and incidental references

Many matches are not active policy and should not be changed automatically:

- old bundled-distribution `ChangeLog` entries;
- historical `perldelta` documents;
- contributor and copyright references;
- comments about past merges between maint and mainline;
- platform documentation for old Perl versions;
- test data containing the word “mainline”.

These should remain separate from current XPerl policy work.

## Existing XPerl policy material

The project-specific policy is currently concentrated in:

- `XPERL-MISSION.md`, which defines the experimental, batteries-included,
  AI-focused, independently stewarded project and its compatibility posture;
- `BLEAD-DELTA.md`, which summarizes current divergence from `origin/blead`;
- `AGENTS.md` and `.agent/skills/`, which define AI-agent workspace guidance;
- `planning/`, which contains design and policy working material.

## Policy questions exposed by the inventory

Future policy work should decide:

- whether `blead` is only a comparison baseline or also an upstream source;
- whether XPerl needs its own branch and remote conventions in porting tools;
- whether CPAN versus XPerl requires a third ownership state;
- how XPerl identifies itself in `perl -v`, `perl -V`, bug reports, and
  generated metadata;
- whether odd/even release numbering remains appropriate;
- which guarantees apply to Perl source, XS/API, embedding ABI, binary
  compatibility, configuration, and installation paths;
- which P5P release instructions remain useful and which are upstream-only;
- whether `perldelta` is sufficient or needs an XPerl companion;
- which historical references should remain untouched.
