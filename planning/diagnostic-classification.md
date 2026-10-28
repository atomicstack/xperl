# Diagnostic classification reports

The catalog defines runtime classes and capabilities. Generate a local
workbook and refresh the class registry with:

```sh
perl regen/diag_mapping.pl > planning/diagnostic-classification.tsv
```

The workbook is optional generated output, not a checked-in migration record.
`diagnostic-class-registry.tsv` is retained because the class browser and
review command read it. `diagnostic-error-family-proposal.tsv` contains
curated previous review assignments and rationales. Those judgments provide
context; they do not override the catalog.

The generator loads the shared warning tree from `regen/warnings_data.pm`.
It validates class parents and cycles, warning category coverage, complete
catalog assignment, and renderer-helper and leaf constraints. Dynamic
warning rows compute a runtime warning-tree lowest common ancestor and
retain exact category metadata. Formatting helpers have no instantiable
class.

Use the [review workflow](diagnostic-classification-review.md) to inspect
producer contracts before proposing changes.
