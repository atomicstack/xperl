# Core Portability Reference

## Canonical Docs

- `pod/perlhacktips.pod`: C portability, macros, debugging, and platform notes.
- `pod/perlport.pod`: Perl-level portability behavior.
- `pod/perlebcdic.pod`: EBCDIC and native character set handling.
- `pod/perllocale.pod`: locale behavior and risks.
- `pod/perlthrtut.pod`: thread behavior visible to users.
- `INSTALL`, `README.*`, `Porting/README.pod`: build and platform guidance.

## Key Files

- `perl.h`, `handy.h`, `config.h`, `config_h.SH`: core portability macros and config-derived feature gates.
- `utf8.h`, `ebcdic_tables.h`, `regen/charset_translations.pl`: native/Unicode/EBCDIC mapping.
- `locale.c`, `locale_table.h`, `regen/locale.pl`: locale state and generated tables.
- `intrpvar.h`, `perlvars.h`, `thread.h`: interpreter globals, thread-local state, multiplicity.
- `hints/`, `Cross/`, `win32/`, `vms/`, `os2/`, `README.*`: platform-specific build and code conventions.
- `makedef.pl`, `embed.fnc`, `mathoms.c`: exports and binary compatibility surface.

## Risk Checks

- C dialect: avoid assuming C99/C11 features, GNU extensions, declaration-after-statement support, or compiler warnings semantics unless established nearby.
- Characters: use native-aware macros instead of ASCII constants when semantics are character-based; check EBCDIC.
- Locale: avoid process-global locale surprises; account for UTF-8 locale, thread safety, and `LC_*` categories.
- Threads/multiplicity: avoid direct globals where interpreter-local state is required; check clone, teardown, and `PERL_IMPLICIT_CONTEXT`.
- Platforms: do not assume Unix paths, file descriptors, fork, symlinks, signals, case-sensitive filesystems, or ELF exports.

## Character Representation Contracts

The interfaces below use **native-Unicode code points**. This is a hybrid
numbering convention: values 0..255 use native character numbering, while
values above 255 use standard Unicode numbering. On ASCII platforms these
agree throughout. On EBCDIC platforms the low 256 values differ. A
native-Unicode code point is not restricted to one byte.

Use this term to disambiguate the numbering, rather than replacing "Unicode"
with "native" and leaving the range unclear. Do not add a conversion just
because code handles Unicode or needs to work on EBCDIC.

Before adding a conversion, identify both contracts: what representation does
the producer return, and what representation does the consumer accept? If both
use native-Unicode numbering, pass the value directly. Check the implementation and API docs
rather than inferring the contract from the function name.

| Producer or consumer | Representation |
|---|---|
| Members of `PL_HasMultiCharFold` | Native-Unicode code points |
| `valid_utf8_to_uv()` result | Native-Unicode code point decoded from native UTF-8 |
| `to_uni_fold()` / `toFOLD_uvchr()` input and code-point result | Native-Unicode code points; the full fold is written separately as native UTF-8 |
| `to_uni_upper()` / `toUPPER_uvchr()` input and code-point result | Native-Unicode code points, including values above 255; the full uppercase mapping is written separately as native UTF-8 |
| `uvchr_to_utf8()` / `uv_to_utf8()` input | Native-Unicode code point |
| `UNI_TO_NATIVE()` | Standard Unicode numbering to native-Unicode numbering; values above 255 are unchanged |
| `NATIVE_TO_UNI()` | Native-Unicode numbering to standard Unicode numbering; values above 255 are unchanged |

For example, a value obtained by iterating `PL_HasMultiCharFold` is already
suitable for `to_uni_fold()`. Applying `UNI_TO_NATIVE()` first is wrong. ASCII
tests cannot expose this mistake because the conversion is an identity there.
Conversely, `UNI_TO_NATIVE(0xDF)` is appropriate when a literal Unicode U+00DF
number is being introduced into native-Unicode processing.

The API documentation states this hybrid convention explicitly under
`UVCHR_IS_INVARIANT` in `pod/perlapi.pod` (source: `utf8.h`). That POD also
documents `NATIVE_TO_UNI` and `UNI_TO_NATIVE`. `pod/perlebcdic.pod`, "Function
Differences", illustrates the distinction using `pack("U", ...)` for standard
Unicode numbering and `pack("W", ...)` for native-Unicode numbering. Some
individual APIs describe their input merely as "Unicode" or "native";
check their implementations before treating that wording as a precise contract.

Keep codepoint numbering separate from byte encoding. `UNI_TO_NATIVE()` does
not decode a UTF-8 string. Native UTF-8 means UTF-8 on ASCII platforms and
UTF-EBCDIC on EBCDIC platforms; use the core encoders, decoders and boundary
macros for encoded data.

### Test Fixtures

Numeric character escapes below `0x100` select native values, not portable
Unicode characters. Use the exceptions in `pod/perlhacktips.pod`, "Assuming
the character set is ASCIIish", or convert intended Unicode characters with
`t/charset_tools.pl`. For example:

```perl
my $sharp_s = uni_to_native("\x{DF}");
my $subject = "Stra${sharp_s}e";
```

Convert the intended character before composing the pattern or subject. Do
not pass an arbitrary mixed string such as `"Stra\x{DF}e"` to that helper:
its ordinary letters already use native numbering, and the helper converts
every character. Preserve the fixture's UTF-8 flag when byte versus upgraded
representations are part of the test. Use Perl's `'a' .. 'z'` range instead of
arithmetic on `ord('a')`, since EBCDIC letters are not contiguous.

Distinguish character constants from intentional native-byte enumeration:
testing every value in `0 .. 255` does not require converting those values.
Check pattern construction, subjects and expected debug output together.

These contracts address Karl Williamson's review of Perl/perl5 PR #24937,
especially comments 4321407197 and 4317353478. Source contracts belong beside
the APIs and data declarations as well as in contributor guidance.

## Tests

```sh
./perl -Ilib t/porting/globvar.t
./perl -Ilib t/porting/libperl.t
./perl -Ilib t/porting/regen.t
make test_harness TEST_FILES='run/locale.t op/threads.t op/utf8*.t io/utf8.t uni/*.t'
make test_harness TEST_FILES='../ext/XS-APItest/t/locale.t ../ext/XS-APItest/t/thread.t ../ext/XS-APItest/t/win32.t'
```

Use platform-specific smoke results when local hardware cannot exercise the risk.

## Useful Searches

```sh
rg -n "UTF_EBCDIC|EBCDIC|NATIVE_TO_(LATIN1|UNI)|LATIN1_TO_NATIVE|UNI_TO_NATIVE|NATIVE_UTF8_TO_I8|I8_TO_NATIVE_UTF8" handy.h utf8.h ebcdic_tables.h regen/charset_translations.pl pod/perlebcdic.pod
rg -n "locale|LC_|setlocale|uselocale|sync_locale|utf8 locale" locale.c perl.h pod/perllocale.pod t/run/locale.t ext/XS-APItest/t/locale.t
rg -n "MULTIPLICITY|PERL_IMPLICIT_CONTEXT|dTHX|pTHX|aTHX|thread" perl.h intrpvar.h perlvars.h thread.h sv.c mg.c t/op/threads.t ext/XS-APItest/t/thread.t
rg -n "WIN32|VMS|OS2|AIX|HAS_|I_\\w+|d_\\w+" Configure config_h.SH hints Cross win32 vms os2 README.*
```
