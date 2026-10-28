CLDR supplemental data
======================

This directory retains supplemental JSON from the cldr-core package in
unicode-org/cldr-json. The current package is cldr-core 49.0.0, for CLDR
release 49. It reports Unicode 16.0.0; that version describes the CLDR
package and is independent of the Unicode version used by this Perl checkout.
The version file pins the CLDR release used for local regeneration.

The JSON files are retained as upstream inputs. LICENSE and package.json are
the corresponding package metadata. plural.pl is derived from those inputs by
Porting/update_cldr.pl. Its provenance section records SHA-256 hashes of all
imported upstream files.

To import another cldr-core release, obtain the official package archive or
checkout locally and run:

    perl Porting/update_cldr.pl --source-dir /path/to/cldr-core

The directory must contain package.json, LICENSE, and the two plural JSON
files under supplemental/. When supplemental/parentLocales.json is present,
the importer filters it to plural-relevant regional mappings and retains only
that subset. A source directory without the full parent-locale file can
provide the reduced pluralParents.json instead. The importer validates the
package and supplemental versions before copying inputs and regenerating
plural.pl. No network access is used by the script. To regenerate or check
the retained release, run:

    perl Porting/update_cldr.pl
    perl Porting/update_cldr.pl --check
    ./perl -Ilib t/porting/cldr_import.t

The generated table stores cardinal and ordinal locale-to-rule mappings and
shares identical rule sets. Each category keeps its normalized condition and
integer sample terms with their exact decimal values. The generated Perl
source quotes numeric-looking strings that do not fit the host's integer
range, so 32-bit hosts do not truncate large samples. Compact integer samples
are kept separately and are not plain integer cases. Each integer sample set
records whether CLDR's ellipsis marks it as non-exhaustive. Decimal sample
text is retained for reference, including categories that have decimal
samples but no integer samples.

The focused test checks the release pin, locale and rule-set counts, and
representative conditions and samples. Review and update those assertions
when importing a new release.

For a future integer-only evaluator, CLDR's operands reduce to n=i=input and
v=w=f=t=c=e=0 for a nonnegative integer input. This import preserves rule
conditions and samples but does not evaluate rules or add runtime lookup
behavior. Locale mappings use the exact identifiers in the plural files.
The importer retains only regional parent mappings that select a different
explicit plural rule from normal subtag removal. For CLDR 49, pt has a
cardinal one rule for i=0..1, while pt-PT has it only for i=1 and v=0. The
eleven pt-* regions that inherit from pt-PT therefore need an explicit
cardinal override. This release has no ordinal regional overrides.
General aliases, script-parent policies, and root/default inheritance are
outside this import. Locale normalization and runtime fallback remain future
work.

Locale counts describe the canonical JSON locale maps. They do not add
alternate identifiers or synthesize the root locale.
