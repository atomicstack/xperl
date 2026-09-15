# XPerl as a Language for AI Agents

## Objective

One of XPerl's explicit goals should be to become an unusually good language
for AI agents to use for software engineering, system exploration, automation,
data transformation, and general-purpose "hacking".

Perl is already naturally strong in this role. It has a broad built-in
capability set, extremely dense expressive power, excellent text handling,
easy access to operating-system facilities, and a long history as a language
for connecting otherwise unrelated systems.

A relatively small Perl program can often replace a chain of shell tools,
one-off Python scripts, `sed`, `awk`, `grep`, JSON processors, file walkers,
and glue programs.

The opportunity for XPerl is therefore not primarily to add "AI features" to
the language. It is to make Perl an excellent **agent execution substrate**:

- easy to discover
- easy to inspect
- deterministic where practical
- easy to invoke
- easy to modify safely
- structured rather than prose-oriented
- powerful without dependency setup
- compact in both source code and interaction cost
- straightforward to verify and recover when something goes wrong

A useful statement of intent would be:

> **XPerl should be the best general-purpose language for an autonomous software agent to invoke, inspect, generate, modify, and reason about.**

That is a stronger objective than merely making Perl easy for an LLM to write.

An agent repeatedly performs a loop resembling:

```text
discover -> inspect -> decide -> execute -> verify -> recover
```

XPerl should be designed to make every stage of that loop cheap and reliable.

---

## Why Perl Is Already Well Suited to Agents

Coding agents spend a large proportion of their time doing things Perl has
historically excelled at:

- traversing filesystems
- searching files
- parsing logs
- transforming text
- manipulating JSON and structured data
- invoking subprocesses
- inspecting repositories
- making source changes
- generating patches
- querying operating-system state
- interacting with HTTP services
- combining unrelated tools and formats
- writing small programs that are discarded after solving one problem

Perl also has an important practical advantage: **code density**.

Agent interaction has a cost associated with:

- generating code
- transmitting it
- reviewing it
- retrying it
- reasoning about it

A concise language therefore has real value.

Perl's problem is not that it lacks capability. Its problems are more often:

- fragmented tooling
- inconsistent APIs accumulated over decades
- hidden context-sensitive behavior
- APIs whose contracts are encoded in conventions rather than structure
- diagnostics designed only for humans
- weak standardized reflection
- dependency uncertainty
- several competing ways to perform common tasks
- insufficient machine-readable metadata

XPerl can address those issues without giving up Perl's power.

---

# Core Design Principle

AI friendliness and human friendliness overlap considerably.

An API that is easy for an agent to use reliably will usually also be easier
for a human to learn and maintain.

New XPerl facilities should generally prefer:

- one obvious spelling for common operations
- consistent naming
- explicit signatures
- stable argument ordering
- explicit semantics
- structured errors
- introspection
- deterministic output where reasonable
- canonical examples
- machine-readable documentation
- small orthogonal APIs
- powerful escape hatches underneath

This does **not** mean reducing Perl's flexibility.

The goal should be:

> Make the obvious path easy to discover and difficult to misunderstand, while
> preserving the ability to do unusual or sophisticated things when necessary.

---

# 1. A Unified XPerl Toolchain

This may be more important for agents than many language-level changes.

Traditional Perl development involves a collection of tools and conventions such as:

```text
perl
prove
perldoc
cpan
cpanm
Makefile.PL
Build.PL
perlcritic
perltidy
```

A human Perl developer learns this ecosystem.

An agent entering an unfamiliar repository must first discover it.

XPerl should provide a single predictable command-line entry point.

For example:

```text
xperl run foo.pl
xperl eval '...'
xperl check lib/
xperl test
xperl test t/foo.t
xperl fmt
xperl lint
xperl doc Graph
xperl add Some::Module
xperl deps
xperl repl
xperl inspect Foo::Bar
```

Internally, some commands could initially delegate to existing implementations.

The important property is that an agent sees **one coherent interface**.

Machine-readable help should be available:

```text
xperl help --json
```

Likewise, individual commands should support structured output where relevant:

```text
xperl check --format=json
xperl test --format=json
xperl inspect Foo --format=json
```

The inspiration from Elixir's `mix` and Rust's `cargo` is useful here, but the
resulting interface should remain distinctly Perl-oriented.

---

# 2. Machine-Readable Compiler Diagnostics

Agents should not need to parse human error messages with regular expressions.

Traditional output such as:

```text
Global symbol "$foo" requires explicit package name
at thing.pl line 17.
```

should still exist for humans, but the compiler should also expose a
structured diagnostic format.

For example:

```json
{
  "severity": "error",
  "code": "XPERL-E0123",
  "message": "Global symbol \"$foo\" requires explicit declaration",
  "file": "thing.pl",
  "span": {
    "start": {
      "line": 17,
      "column": 8
    },
    "end": {
      "line": 17,
      "column": 12
    }
  },
  "suggestions": []
}
```

Stable diagnostic codes would be especially useful:

```text
xperl explain XPERL-E0123
```

This benefits:

- agents
- IDEs
- editors
- CI systems
- static analysis tools
- humans searching documentation

The general principle should be:

> **No XPerl tool should require an agent to scrape prose if structured
> information can reasonably be supplied instead.**

---

# 3. Rich Reflection and Introspection

Perl already supports basic runtime reflection such as:

```perl
$obj->can("foo");
```

XPerl should go much further.

If a program contains:

```perl
class Foo :implements(Bar) {
    field $name :param;

    method frobnicate($count, $flags = 0) {
        ...
    }
}
```

XPerl should be able to expose metadata such as:

```text
class Foo

roles:
    Bar

fields:
    name

methods:
    frobnicate(count, flags = 0)

source:
    lib/Foo.pm:27
```

Programmatically, this might look conceptually like:

```perl
my $meta = Meta::class("Foo");

$meta->methods;
$meta->fields;
$meta->roles;
$meta->source;
```

The same idea should apply to ordinary modules:

- exports
- signatures
- constants
- classes
- roles
- functions
- documentation
- source locations
- experimental status
- deprecation status

The command line should expose the same metadata:

```text
xperl inspect Foo --json
```

This would let an agent understand unfamiliar code without scraping POD or
scanning source files manually.

Given the new class, role, namespace, and signature work already happening in
XPerl, this could become a major advantage.

---

# 4. A Supported Parser, AST, and CST API

This could be one of XPerl's most consequential features.

AI coding agents constantly modify source code.

Perl is a particularly difficult language to edit safely using text
substitution alone because its syntax is exceptionally rich.

XPerl controls the actual parser, so it has the opportunity to expose that
parser as a supported public API.

Ideally, two representations would be available:

```text
AST     semantic program representation
CST     concrete source-preserving syntax tree
```

The AST is useful for understanding code.

The CST is necessary for modifying code while preserving:

- comments
- whitespace
- layout
- formatting
- source locations

A conceptual interface might look like:

```perl
my $doc = Perl::Syntax->parse_file("Foo.pm");

for my $sub ($doc->subroutines) {
    ...
}

$method->rename("foo");

$doc->write;
```

A supported parser API could become the common substrate for:

- formatters
- linters
- refactoring tools
- IDE support
- source indexing
- documentation extraction
- static analysis
- agent-driven code modification

The key principle is:

> **Tools that understand Perl should use the same parser Perl itself uses.**

That is far preferable to maintaining a separate approximation of Perl grammar.

---

# 5. First-Class Filesystem and Path APIs

Agents manipulate files constantly.

XPerl should make filesystem work easy, structured, and safe.

A modern path abstraction might allow:

```perl
my $path = Path->new("lib", "Foo.pm");

$path->exists;
$path->is_file;
$path->parent;
$path->extension;
$path->read_text;
$path->write_text($content);
```

But object use should not be mandatory.

Simple procedural forms should remain available:

```perl
FS::read_text("lib/Foo.pm");
FS::write_text("lib/Foo.pm", $content);
```

For agents, additional mutation-safety operations would be particularly valuable.

For example:

```perl
FS::atomic_write($path, $contents);
```

and compare-and-swap style replacement:

```perl
FS::replace(
    $path,
    expected => $old,
    with     => $new,
);
```

If the file changed after the agent inspected it, the operation should fail
rather than silently overwrite newer content.

That is directly useful for autonomous editing.

---

# 6. Diff and Patch as Standard Primitives

Diff and patch operations are basic agent infrastructure.

They should not require an external package or shelling out.

A conceptual API might be:

```perl
my $patch = Diff->between($old, $new);

$patch->check($path);
$patch->apply($path);
$patch->reverse;
```

Useful capabilities could include:

- unified diff generation
- patch parsing
- patch validation
- fuzzy application where explicitly requested
- reverse patches
- hunk inspection
- source location information
- structured patch representation

This would allow agents to modify files transactionally rather than relying
entirely on raw rewrites.

---

# 7. A Modern Process API

Running subprocesses is central to coding-agent behavior.

The obvious API should avoid shell interpolation unless the caller explicitly
asks for a shell.

For example:

```perl
my $result = Process::run(
    ["git", "status", "--porcelain"],
    cwd     => $repo,
    timeout => 30,
    capture => true,
);

$result->success;
$result->exit_code;
$result->stdout;
$result->stderr;
```

Pipelines should also be expressible structurally:

```perl
my $result = Process::pipeline(
    ["git", "log"],
    ["grep", "foo"],
    ["head", "-20"],
);
```

Important features should include:

- explicit argument arrays
- environment control
- current-directory control
- timeout handling
- stdout/stderr capture
- streaming
- exit status
- signals
- pipelines
- cancellation

This is both safer and easier for an agent to reason about than generating
shell command strings.

---

# 8. Structured Errors

New XPerl APIs should avoid making free-form strings their public error
contract.

Instead, errors should share a common structured interface.

For example:

```perl
$error->code;
$error->message;
$error->cause;
$error->data;
$error->file;
$error->line;
$error->trace;
```

Human-readable formatting can be layered on top.

Machine-readable serialization can use the same underlying object.

Ideally, core libraries such as:

- `FS`
- `Process`
- `HTTP`
- `JSON`
- `Graph`
- parsers
- package management
- compiler diagnostics

would all expose compatible error semantics.

This allows an agent to write generic recovery logic.

---

# 9. Batteries Included for Agent Workloads

Dependency installation is expensive for an agent.

It introduces:

- extra tool calls
- more state
- network dependency
- version uncertainty
- installation failures
- additional reasoning

XPerl should therefore include the formats and protocols agents encounter
constantly.

High-value examples include:

```text
JSON
JSONL
CSV
TSV
TOML
URI
HTTP
Base64
hex
gzip
zstd
tar
zip
hashing
HMAC
```

Perl should be able to replace tools such as `jq`, `awk`, `sed`, and small
Python scripts without needing a package-installation phase.

JSON-lines processing in particular could become an excellent command-line
capability.

Conceptually:

```text
xperl --json-lines ...
```

The exact syntax is less important than making structured stream
processing trivial.

---

# 10. MCP Support

Model Context Protocol support fits XPerl particularly well.

Perl is naturally suited to implementing small service adapters and
glue programs.

An MCP server API could be straightforward:

```perl
use MCP;

my $server = MCP::Server->new(...);

$server->tool(...);
$server->run;
```

However, XPerl has an opportunity to go beyond simply providing an MCP library.

Because XPerl is gaining:

- signatures
- classes
- roles
- structural matching
- richer introspection

it may eventually be possible to expose ordinary Perl callables as agent tools
with minimal boilerplate.

Conceptually:

```perl
tool search_files($query, $path) {
    ...
}
```

The exact syntax is not important at this stage.

The important design goal is:

> **A Perl callable should be cheaply exposable as an AI-agent tool.**

Tool schemas could potentially be derived from:

- signatures
- type or shape information
- documentation
- metadata
- default values

That could make XPerl exceptionally effective for building agent integrations.

---

# 11. Capability-Based Execution

A more ambitious feature would be a restricted execution mode intended for
generated or semi-trusted code.

For example:

```text
xperl run \
    --allow-read=. \
    --allow-write=./tmp \
    --allow-net=api.example.com \
    --allow-run=git,make \
    agent-script.pl
```

Any operation outside those declared capabilities would fail.

Potential capabilities might include:

```text
filesystem read
filesystem write
network access
subprocess execution
environment access
dynamic module loading
FFI
device access
```

This is conceptually closer to a modern permission system than to traditional
Perl sandboxing.

Because XPerl controls the runtime, it could potentially enforce these
restrictions more reliably than an ordinary CPAN module could.

Such a capability mode would be particularly valuable for
agent-generated programs.

---

# 12. Deterministic and Canonical Output

Agents frequently need to answer:

> Did my change alter anything?

Incidental output variation makes this harder.

New XPerl facilities should therefore prefer deterministic behavior whenever
doing so does not compromise important semantics.

Good candidates include:

- canonical JSON
- stable diagnostics
- stable reflection output
- deterministic formatting
- stable graph serialization
- stable test output
- explicit random-number control

The existing XPerl RNG work already fits this philosophy.

A future mode such as:

```text
xperl --deterministic ...
```

could potentially standardize additional behavior for:

- testing
- reproducible builds
- agent execution
- debugging

Its exact semantics would need careful definition.

---

# 13. Standard Project Metadata

Agents often spend significant effort discovering how to work with a repository.

They may need to inspect:

```text
Makefile.PL
Build.PL
cpanfile
META.json
README
CI configuration
Makefiles
shell scripts
developer documentation
```

A standard XPerl project description could make this much easier.

Conceptually:

```toml
[project]
name = "foo"

[commands]
test = "..."
lint = "..."
format = "..."

[dependencies]
...
```

The format need not necessarily be TOML.

The important thing is to establish a canonical location for:

- project identity
- dependency information
- build commands
- test commands
- formatting
- linting
- generated files
- repository conventions
- minimum XPerl version

This would reduce repository-discovery overhead substantially.

---

# 14. Documentation Should Be Machine-Readable

Human-readable documentation remains essential, but XPerl should consider
documentation metadata part of the API.

For example, an agent should be able to ask:

```text
xperl doc Graph --json
```

and receive:

- summary
- callable names
- signatures
- argument descriptions
- return semantics
- examples
- error conditions
- source links
- related APIs

This does not require replacing POD.

It may instead mean compiling documentation into structured metadata alongside
the human presentation.

The result would reduce token usage and improve API discovery.

---

# 15. Language Features That Improve Agent Use

Several existing XPerl directions already contribute to this goal.

## Signatures

Explicit signatures are much easier to inspect and reason about than
implicit `@_`.

## Classes and Roles

These provide stronger structural intent and better metadata than ad-hoc
package conventions.

## Lexical Namespaces

These can make name resolution clearer and large systems easier to
reason about.

## Generators and Iterators

These provide a standard abstraction for streaming operations and reduce the
need for custom callback conventions.

## Dispatch/On

Structural matching makes data-processing intent explicit and may eventually
share concepts with validation and schema description.

## RNG Providers

Explicit random-number providers improve reproducibility and allow
deterministic agent runs.

All of these features contribute to an environment where program intent can be
discovered rather than inferred.

---

# 16. Avoid Excessive Context-Sensitive API Behavior

Perl's context sensitivity is powerful, but it can also make APIs harder for
agents and humans to reason about.

New XPerl libraries should be cautious about APIs where scalar and list
context fundamentally change meaning.

Prefer explicit operations such as:

```perl
$seq->first;
$seq->count;
$seq->to_list;
```

over APIs whose return semantics depend heavily on implicit context.

This is not an argument for removing Perl context.

It is an argument for avoiding unnecessary contextual cleverness in new
standard APIs.

---

# 17. Performance Matters for Agent Workloads

Agent-generated utility programs are often short-lived.

Startup time therefore matters.

XPerl should avoid requiring large dependency graphs or expensive runtime
initialization for common tasks.

Important considerations include:

- fast interpreter startup
- cheap module loading
- efficient filesystem traversal
- efficient JSON parsing
- compact native data structures
- efficient subprocess handling
- native implementations where representation matters

The existing Tensor work demonstrates an appropriate philosophy:

> Use native implementation where it materially improves representation or
> performance, while retaining a simple Perl-facing API.

The same principle can apply elsewhere.

---

# 18. An Agent-Oriented Standard Library

The broader XPerl standard-library work should be evaluated partly through
this lens.

Particularly valuable modules include:

```text
Seq / Stream
Set
Bag / Counter
Deque
Heap
Graph
Tensor
Matrix
Vector
Stats
Path
FS
Process
Duration
Instant
DateTime
Bytes / Buffer
JSON
HTTP
URI
Diff / Patch
MCP
```

These cover a very large proportion of the operations agents perform.

The important constraint is that they should form a coherent library rather
than an assortment of unrelated bundled modules.

---

# 19. Design Priorities

If prioritizing specifically for AI-agent use, a reasonable sequence would be:

## Tier 1: Foundation

1. Unified `xperl` CLI
2. Machine-readable compiler diagnostics
3. Reflection and inspection API
4. `Path` / `FS`
5. `Process`
6. Structured errors

## Tier 2: Source Manipulation

7. Supported parser API
8. AST
9. Source-preserving CST
10. Diff / Patch

## Tier 3: Data and Integration

11. JSON / JSONL
12. CSV / TSV
13. URI / HTTP
14. compression formats
15. bytes / buffer abstraction

## Tier 4: Agent Integration

16. MCP client/server support
17. callable-to-tool metadata
18. machine-readable documentation
19. standard project metadata

## Tier 5: Controlled Execution

20. capability-based execution
21. deterministic execution mode
22. reproducibility tooling

---

# 20. The Highest-Leverage Initiative

If only one major initiative were chosen specifically to improve XPerl for
coding agents, the strongest candidate would probably be:

> **A unified XPerl toolchain backed by a supported parser, introspection API,
> and structured diagnostics.**

That would give agents a canonical way to perform:

```text
inspect
check
test
format
document
refactor
modify
verify
```

while receiving structured machine-readable information at every stage.

Combined with Perl's existing ability to serve as:

```text
sed
awk
grep
shell glue
structured-data processor
network client
general-purpose programming language
```

inside a single compact program, this could make XPerl unusually attractive
for autonomous software-engineering tasks.

---

# Conclusion

The central opportunity is not to make XPerl "an AI language".

It is to recognize that AI agents have a workload that is exceptionally close
to the workload Perl was historically designed to solve:

> inspect messy systems, manipulate data, invoke tools, transform text, and
> glue everything together.

Perl already has much of the raw power.

XPerl can add the missing properties modern autonomous tooling needs:

- coherence
- discoverability
- introspection
- structured interfaces
- reproducibility
- safe execution
- canonical tooling
- batteries included
- source-aware program manipulation

The result should remain recognizably Perl.

The ambition is not to simplify Perl until an AI can understand it.

The ambition is to make **the full power of Perl easier for both agents and
humans to discover, invoke, verify, and control**.
