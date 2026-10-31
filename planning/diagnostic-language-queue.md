# Diagnostic translation language queue

The registered packs are `ar cy de en es fa fi fr he hu is it nl pt ru sr tr uk zh`.
They have been imported and tested; native linguistic review is separate.
The builtin integer cardinal and ordinal functions cover the retained CLDR
languages independently of installed packs. Adding a pack requires translated
sentences, vocabulary and grammatical forms, not just plural categories.

## Queue

Serbian (`sr`) uses Cyrillic and Mandarin Chinese (`zh`) uses Simplified
Chinese. The next priorities are Swedish, then Hindi. Refine the remaining
order when real translation contexts expose different requirements.

| Language | Code | Main question |
|---|---|---|
| Swedish | `sv` | Phrase agreement and independent ordinal rules |
| Hindi | `hi` | Devanagari text and agreement |
| Polish | `pl` | Case, agreement and phrase forms |
| Czech | `cs` | Independent Slavic phrase forms |
| Irish | `ga` | Five cardinal categories and contextual forms |
| Scottish Gaelic | `gd` | Four cardinal categories; independent from Irish |
| Korean | `ko` | Technical wording and phrase construction |
| Japanese | `ja` | Whole-sentence reordering and phrase forms |
| Thai | `th` | Technical wording and layout |
| Cantonese | `yue` | Independent wording and support for a three-letter code |

The current pack interface uses two-letter codes;
Cantonese requires an interface decision, not an invented alias or
substitution of Mandarin wording.

## Workflow for each language

1. Inspect actual sentence and operation-word consumers before choosing forms.
   Keep complete phrases and grammatical choices in language data.
2. Check the retained CLDR cardinal and ordinal rules independently. Reuse a
   configured rule only when its mappings agree, not just its category names.
3. Translate and audit vocabulary before consumer sentences. Use the shared
   translation export, repair, review and import commands.
4. Resolve requests for forms or selectors from real contexts. Avoid copying
   English case structure or adding unnecessary opcode-specific templates.
5. Audit coverage, stale provenance and word dependencies. Check runtime
   messages, canonical data, hooks and structured output.
6. Build and test each complete addition. Label machine drafts separately
   from linguistic review. Keep transient worksheets and model checkpoints
   under the workspace `tmp/` directory.

When adding a pack to an already configured build, keep `config.sh` extension
lists consistent: selected `dynamic_ext`, combined `extensions`, and discovered
`known_extensions`. `Configure -S` regenerates supplied settings rather than
rediscovering these lists. After refreshing Config and building, check
`lib/Config/Extensions.t`, `t/porting/FindExt.t` and the pack tests.

For Arabic and Persian, review mixed-direction display in HTML and terminals.
Correct Unicode storage does not establish the intended visual ordering of
punctuation, paths and embedded source syntax.
