# XPerl installer (development)

The installer resolves a module through CPAN's `02packages` index, fetches its
original release archive, and can build, test, and install a `Makefile.PL` or
`Build.PL` distribution into an explicit prefix. It recursively installs
declared required prerequisites. With `--registry DIR`, it applies known
patches from the local `xperl-cpan-ports` repository before building. The CLI
uses XPerl's `dispatch/on` syntax.

From the Perl source checkout, run:

```sh
./perl -Ilib xperl-installer/bin/xperl resolve Sereal::Decoder
./perl -Ilib xperl-installer/bin/xperl fetch Sereal::Decoder
./perl -Ilib xperl-installer/bin/xperl install --prefix ../tmp/xperl-local Example::Tiny
```

To install the current Sereal releases with local compatibility patches:

```sh
./perl -Ilib xperl-installer/bin/xperl install --cache ../tmp/xperl-sereal-cache --prefix ../tmp/xperl-sereal-prefix --registry ../xperl-cpan-ports Sereal::Decoder
./perl -Ilib xperl-installer/bin/xperl install --cache ../tmp/xperl-sereal-cache --prefix ../tmp/xperl-sereal-prefix --registry ../xperl-cpan-ports Sereal::Encoder
```

`--cache DIR` selects a cache directory. `--mirror URL` selects an HTTPS CPAN
mirror. A local mirror directory with `modules/` and `authors/id/` subtrees is
supported for tests. `--refresh` fetches the index and archive again. Registry
lookup is optional and does not require an AI agent.

The registry root contains `registry.json`. The installer combines the CPAN
author from the resolved archive with its distribution name, then uses jump
consistent hash to choose a data repository and a fixed SipHash prefix to
find that author's patch index. A registry without `registry.json` retains
the original flat layout for compatibility. The current shared registry has
one active data repository.

The command reports the archive's SHA-256 digest for reproducibility. This
checkpoint calculates the digest but does not yet authenticate it against
independent CPAN checksum metadata. Install writes phase logs and a JSON
receipt under the cache's `work/` directory. It stops before installation
when configuration, build, or tests fail. A configure step must create its
Makefile or Build script even if the process exits zero. Only dependencies
declared in CPAN metadata are resolved. Older metadata is converted before
validation, so fixable fields such as a missing abstract do not block
dependency resolution. Dynamic configuration and optional
prerequisites are not handled yet. `Build.PL` distributions need their build
tool, commonly `Module::Build`, installed or declared as a required build
prerequisite.

The runner uses cpanm's noninteractive build signals. Configure, build, and
test set `PERL_MM_USE_DEFAULT=1`; test also sets
`NONINTERACTIVE_TESTING=1`. Configure sets the CPAN-running markers used by
some older build scripts, plus `PERL5_CPAN_IS_EXECUTING` for Makefile.PL.
Each build phase identifies the current interpreter through `PERL` and sets
`PERL_USE_UNSAFE_INC` from
the distribution's `x_use_unsafe_inc` metadata when present, or to `1` for
older distributions, while preserving an explicit caller setting. The
variables are scoped to the child command. The installer does not set
`AUTOMATED_TESTING`, which denotes smoke testing rather than installation,
and it leaves color settings such as `NO_COLOR` to the distribution's tests.

## Optional repair command

`--repair-command PATH` enables an external repair program after a failed
configure, build, or test phase. `--repair-attempts N` limits repair calls;
the default is two. `--repair-timeout SECONDS` limits each call; the default
is 600 seconds. The installer never calls a repair program unless this
option is present. The command must be an executable file. It runs with the
distribution source directory as its working directory and receives one
argument: the absolute path to a JSON request file.

The request has `schema: 1`, the module and CPAN archive identity, source
digest, XPerl executable and version, attempt number, source directory,
failed phase, command, and log path. When a registry patch set names migration
recipes, `recipes` contains their IDs and absolute Markdown paths. The
program should edit the source tree and exit zero when ready for another
build. A nonzero exit stops installation. The installer reruns configuration,
build, and tests after each successful repair call, and records every phase
and request in the receipt. Installation runs only after the tests pass.

After a successful repair, the installer writes `proposal.patch` next to the
receipt. It compares repaired source files with the untouched CPAN archive,
includes files added by registry patches or the repair command, and leaves
ordinary build products out. The patch includes any known registry changes
so it applies directly to the original release. A dry run against a fresh
copy of that release must pass before installation. The receipt records the
proposal path, file list, and SHA-256 digest for review.

The repair program can be any agent wrapper that accepts this protocol. The
installer does not bundle an AI service or submit generated patches yet.
