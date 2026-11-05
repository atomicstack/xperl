# XPerl installer (development)

The first checkpoint resolves a module through CPAN's `02packages` index and
fetches its original release archive. The CLI uses XPerl's `dispatch/on`
syntax. Build, test, install, and registry lookup are later checkpoints.

From the Perl source checkout, run:

```sh
./perl -Ilib xperl-installer/bin/xperl resolve Sereal::Decoder
./perl -Ilib xperl-installer/bin/xperl fetch Sereal::Decoder
```

`--cache DIR` selects a cache directory. `--mirror URL` selects an HTTPS CPAN
mirror. A local mirror directory with `modules/` and `authors/id/` subtrees is
supported for tests. `--refresh` fetches the index and archive again.

The command reports the archive's SHA-256 digest for reproducibility. This
checkpoint calculates the digest but does not yet authenticate it against
independent CPAN checksum metadata. Do not treat the fetch output as an
installation receipt.
