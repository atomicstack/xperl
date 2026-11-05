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

The command reports the archive's SHA-256 digest for reproducibility. This
checkpoint calculates the digest but does not yet authenticate it against
independent CPAN checksum metadata. Install writes phase logs and a JSON
receipt under the cache's `work/` directory. It stops before installation
when configuration, build, or tests fail. Only dependencies declared in CPAN
metadata are resolved; dynamic configuration and optional prerequisites are
not handled yet. `Build.PL` distributions need their build tool, commonly
`Module::Build`, installed or declared as a required build prerequisite.
