---
name: perl-regex-engine
description: "Use when changing or analyzing Perl regex internals: regcomp/regexec, regnodes, optimizer/study logic, tries, ANYOF/EXACT handling, regex generated files, regex debug output, or t/re tests."
---

# Perl Regex Engine

Regex internals are high-risk. Separate compile-time behavior, execution behavior, optimizer behavior, generated node metadata, and user-visible semantics before editing.

Regex property lists and folding APIs normally use native-Unicode code points:
native numbering below 256 and standard Unicode numbering above 255. Do not
insert `UNI_TO_NATIVE()` between native-Unicode interfaces, including iteration of
`PL_HasMultiCharFold` followed by `to_uni_fold()`. Read the reference's folding
and representation guidance when changing character conversions or fold tests.

## Workflow

1. Identify whether the issue is compile, execute, optimize/study, debug display, generated metadata, or public regex API.
2. Read the relevant source files, `pod/perlreguts.pod`, and `pod/perlreapi.pod` for public regex engine API changes.
3. Never hand-edit generated regex headers; edit generator inputs/scripts and regenerate.
4. Add the narrowest regex tests first, then expand for Unicode, locale, thread, or API coverage as needed. Never hardcode character values below `0x100` unless explicitly permitted by `pod/perlhacktips.pod`, "Assuming the character set is ASCIIish", or converted with a helper from `t/charset_tools.pl`. Apply this to patterns, subjects, and expected debug output. See the reference's test portability guidance.
5. Ask for project context before changing behavior whose historical rationale is unclear.

Read [references/regex-engine-map.md](references/regex-engine-map.md) for source maps, generated files, tests, and risk searches.
