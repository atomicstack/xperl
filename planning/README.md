# Development planning

This directory contains proposals, investigations and review tools for
Perl-core development. Installed documentation belongs in `pod/`; generated
HTML, model responses and temporary build output belong under the workspace
`tmp/` directory.

For XPerl exceptions and diagnostics, start with:

- [Perl interface](../pod/perlexcept.pod) and
  [implementation details](../pod/perlexcephack.pod).
- [Remaining work](perl-core-structured-errors.md) and the
  [translation language queue](diagnostic-language-queue.md).
- [Generated table layout](diagnostic-data-layout.md).
- [Classification reports](diagnostic-classification.md) and
  [producer-based review workflow](diagnostic-classification-review.md).
- [Class browser and source-reference tools](exception-system-guide/README.md).

The registry, previous classification assignments and source-context files
are inputs to the review tools. Previous assignments are review evidence;
the catalog defines the current runtime classes.
