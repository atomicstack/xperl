# Diagnostic translation review

Status: design review, 2026-11-19. This records Matt Koscica and Claude's
proposal from agent-comms on 2026-11-18. No CLI or public API is approved by
this note.

The proposal is useful: show a native speaker real English and translated
diagnostics from the same small program, then prepare a correction report.
Keep translation edits in the normal review process. Preparing an issue
should not publish it without the reviewer's explicit action.

## Corpus and execution

Start with a source-tree tool under Porting and a corpus beside it. An
installed tool needs a deliberate data installation path. A new top-level
directory by itself does not settle that problem.

Use existing croak and warning fixtures as seeds, then check every extracted
case against structured output. Some fixtures need helper files, switches,
platform conditions or several diagnostics, so copying their snippets alone
will not reproduce their meaning. Store those requirements with each case.
Validate diagnostic codes and parameters. Treat selector_key as derived
compatibility data, rather than the identity of a translated message.

Report coverage by code and by template case. Require useful coverage for
new user-facing diagnostics once the corpus format is established. Internal
panics need not have runnable examples. Label examples built from sample
parameters as rendered examples, never as observed interpreter output.

Each snippet runs in a fresh child process with a timeout and a temporary
working directory. Record the source revision, language, locale, switches,
exit status and output encoding with the result. A failed child must not
silently become a successful example.

## Rendering and feedback

Existing diagnostic objects can render in an explicitly chosen language.
Their constructor is private. Core has template-rendering functions and
XS::APItest fixtures, but these are not an installed public Perl API for
constructing arbitrary diagnostics. Prefer a source-tree adapter initially.
Review any public rendering API separately, including parameter validation.

Keep the issue destination configurable until the project chooses a repo
and label. A report should include the code, parameters, source program,
English output, translated output, suggested wording and revision. Do not
freeze catalogue counts from the proposal into the implementation.

## Encoding report

Claude reported Latin-1 German output on an installed macOS build. On the
current Linux build, the strict-vars fatal diagnostic is valid UTF-8 on a
pseudo-terminal in the C.UTF-8 locale. A warning containing a non-ASCII
message behaves the same way. Both paths also produce valid UTF-8 through
explicit :utf8 and :encoding(UTF-8) stderr layers.

Redirected default or :raw stderr retains Perl's byte-stream behavior and
can contain Latin-1. This does not reproduce the reported terminal failure.
The current util.c code detects raw UTF-8 terminals separately from encoded
streams. Do not change pipe encoding globally on the evidence available.

The macOS report still needs the actual isatty result, LC_CTYPE locale,
PerlIO stderr layers and build revision. Check the same fatal and warning
cases there before choosing a platform fix. The review CLI should decode
its captured output explicitly instead of assuming a pipe behaves like a
terminal.
