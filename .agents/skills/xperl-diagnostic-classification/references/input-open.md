# Worked example: INPUT_OPEN_TOO_MANY_ARGUMENTS

This review was applied as `ERROR_IO_OPEN_STDIN_TOO_MANY_ARGUMENTS`, under
`Error::IO::Open`. Locate current source using the code and enclosing function
rather than relying on line numbers.

## Evidence

Before review, catalog number 1462 had class Error::Argument::Arity, tags
`condition:size_count_range` and `subject:call_callback_contracts`, and English
wording `More than one argument to '<%{arg2}' open`. The parameter name `arg2`
does not reveal what is displayed.

The source reference is in `doio.c`, inside `Perl_do_open6()`. The relevant path:

1. The operation parses an input-open mode (`IoTYPE_RDONLY`).
2. It recognizes `IoTYPE_STD` with an appropriate mode terminator.
3. It selects `PerlIO_stdin()`.
4. If `num_svs > 1`, it emits this diagnostic, passing `IoTYPE_STD`.

`sv.h` defines IoTYPE_RDONLY as '<' and IoTYPE_STD as '-'. The displayed character
therefore completes '<-'. Earlier code distinguishes explicit name operands from
the mode string. `num_svs` is not the total number of Perl arguments including
the handle and mode.

Nearby output-open, descriptor-duplication and layer checks are comparisons to
review; they are not interchangeable merely because they mention extra arguments.

## Contract and classification

Contract: the standard-input form of open rejects extra name operands.

The count is meaningful because of the selected operation and mode. This is not a
failure to bind an ordinary subroutine signature, not invalid parameter-declaration
syntax, and not an operating-system open failure. The guard is explicit user-input
validation rather than a panic or core invariant failure.

The reviewed class is Error::IO::Open. The code
`ERROR_IO_OPEN_STDIN_TOO_MANY_ARGUMENTS` uses that family's prefix and identifies
the restricted standard-input case. Producer review of the neighboring open
diagnostics established this grouping before the authorized rename.

The size/count condition is supported by the predicate. An IO/open subject tag
fits better than a callback subject. Prefer an accurate existing IO subject tag;
propose a dedicated file-open tag only if it improves the wider taxonomy.
The low-information parameter name also deserves a separate semantic-parameter
review; classification does not authorize changing that schema.

## What could change this recommendation?

- Another producer might use the same code for a different mode or contract.
- Broader review might establish a useful shared operation-contract family.
- Input/output checks might share an explicit mode/direction selector and be
  candidates for one diagnostic. Compare their schemas, translations and delivery
  before proposing a merge. Keep stable numbers during review.

Python would motivate comparing this with ValueError versus TypeError, because the
operation rejects the chosen mode/operand combination. That analogy alone does not
determine the XPerl class.

## Evidence lookup

```sh
rg -n -C 15 'PERL_THROW_ERROR_IO_OPEN_STDIN_TOO_MANY_ARGUMENTS' doio.c
rg -n 'IoTYPE_RDONLY|IoTYPE_STD' sv.h
rg -n 'Perl_do_open6|New style explicit name|num_svs' doio.c
```

Inspect the full enclosing branches when a snippet does not explain a predicate.
A count comparison alone is insufficient evidence for Error::Argument::Arity.
