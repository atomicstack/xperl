# Diagnostic review tools

Build the interactive class browser from the current catalog and review
reports, from the Perl checkout:

```sh
./perl -Ilib planning/exception-system-guide/class_tree.pl --output ../tmp/diagnostic-classes.html
```

The HTML contains its styles, script and data. The checkout's Perl generates
it, and no web server is required to view it.

`class_tree.pl` also provides `--review-evidence INPUT OUTPUT` for the
[classification review driver](../diagnostic-classification-review.md).
`SourceOwners.pm` finds enclosing definitions. `source_reference.pl` builds
the file/function reference index:

```sh
./perl -Ilib planning/exception-system-guide/source_reference.pl
```

The tools read the retained class registry, previous review assignments,
source-context index and focused source notes in the parent directory.
Source hashes distinguish fresh notes from stale reviews. Previous reviews
do not establish the correctness of current classifications.

For the illustrated exception manuals, use
[`Porting/render_except_docs.pl`](../../Porting/render_except_docs.pl).
