# XPerl installer (development)

The installer resolves a module through CPAN's `02packages` index, fetches its
original release archive, and can build, test, and install a `Makefile.PL`
distribution into an explicit prefix. The CLI uses XPerl's `dispatch/on`
syntax. Recursive prerequisites and registry lookup are later checkpoints.

From the Perl source checkout, run:

```sh
./perl -Ilib xperl-installer/bin/xperl resolve Sereal::Decoder
./perl -Ilib xperl-installer/bin/xperl fetch Sereal::Decoder
./perl -Ilib xperl-installer/bin/xperl install --prefix ../tmp/xperl-local Example::Tiny
```

`--cache DIR` selects a cache directory. `--mirror URL` selects an HTTPS CPAN
mirror. A local mirror directory with `modules/` and `authors/id/` subtrees is
supported for tests. `--refresh` fetches the index and archive again.

The command reports the archive's SHA-256 digest for reproducibility. This
checkpoint calculates the digest but does not yet authenticate it against
independent CPAN checksum metadata. Install writes phase logs and a JSON
receipt under the cache's `work/` directory. It stops before installation
when configuration, build, or tests fail. The installer does not yet resolve
prerequisites, so a release may fail if a required module is missing.
