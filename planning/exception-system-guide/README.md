# Diagnostic review tools

Build the interactive class browser from the current catalog and review
reports, from the Perl checkout:

```sh
python3 -B planning/exception-system-guide/class_tree.py --output ../tmp/diagnostic-classes.html
```

The HTML contains its styles, script and data. Python 3 and the environment
Perl are required to generate it. No web server is required to view it.

`class_tree.py` also provides `--review-evidence INPUT OUTPUT` for the
[classification review driver](../diagnostic-classification-review.md).
`source_owners.py` finds enclosing definitions. `source_reference.py` builds
the file/function reference index:

```sh
python3 -B planning/exception-system-guide/source_reference.py
```

The tools read the retained class registry, previous review assignments,
source-context index and focused source notes in the parent directory.
Source hashes distinguish fresh notes from stale reviews. Previous reviews
do not establish the correctness of current classifications.

For the illustrated exception manuals, use
[`Porting/render_except_docs.pl`](../../Porting/render_except_docs.pl).
