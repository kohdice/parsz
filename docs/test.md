# parsz Test Plan

This file is the phase-oriented test plan for `parsz`.
It is also the canonical upstream portability audit for the current roadmap.
The phase-by-phase checklists and the audit rationale live in this one file so
the implementation plan remains self-contained even if older survey notes are
removed.

## Scope

This plan follows:

- `plan.md`
- `todo.md`

This plan also uses upstream test suites as references, not as API contracts:

- `clap-rs/clap` at `70f3bb31874ff24233f18c394982407ca90d0dcc`
- `alecthomas/kong` at `258b13ac944d17b24a683ff23200933c89555fb7`

## Porting Rules

- Port behavior, not upstream APIs.
- Rewrite tests against `parsz.parse`, `parsz.deinit`, and `parsz.Parsed`.
- Prefer small Zig-native fixtures over direct one-to-one transliterations when the upstream API model is different.
- Keep compile-fail validation coverage in standalone fixtures.
- Do not port upstream coverage for explicit non-goals:
  - env
  - config
  - completion
  - clap derive / proc-macro behavior
  - user-defined non-null defaults
  - repeated option values
  - repeated short-count flags
  - aliases
  - conflicts / groups / xor / and
  - custom decoders and custom mapper plumbing

## Phase 1 / PR 1

Phase goal:

- bootstrap the public wrapper types and library skeleton

Primary local tests:

- compile-only smoke tests for representative root schemas
- compile-only smoke tests for representative subcommand schemas
- compile-only smoke tests that the wrapper constructors expose the internal comptime contract needed by schema extraction

Upstream reference value:

- no direct upstream test should be ported here
- this phase is about `parsz` surface shape, not parser behavior
- keep this phase local-first

Exit expectation:

- a user can declare stable command schemas without relying on parser implementation details

## Phase 2 / PR 2

Phase goal:

- implement `Parsed(Schema)` type generation

Primary local tests:

- schema struct -> plain parsed struct transformation
- `Flag(...) -> bool`
- `Option(T, ...) -> T`
- `Positional(T, ...) -> T`
- `Subcommand(union(enum))` -> recursively transformed tagged union
- optional payload preservation
- repeated positional slice preservation

Upstream reference value:

- use upstream suites only as structural references
- do not force one-to-one upstream ports in this phase
- the most relevant comparison points are:
  - nested command-tree structure from `kong/model_test.go`
  - subcommand result-shape expectations implied by `clap/tests/builder/subcommands.rs`

Exit expectation:

- `parsz.Parsed(Schema)` is stable enough to anchor parser and cleanup tests in later phases

## Phase 3 / PR 3

Phase goal:

- schema extraction and compile-time validation

Must-have local coverage:

- reject non-struct roots
- reject tuple structs
- reject non-wrapper fields
- reject unsupported payload types
- reject duplicate long names
- reject duplicate short names
- reject required positional after optional positional
- reject positional after variadic positional
- reject multiple `Subcommand(...)` fields
- reject non-tagged-union `Subcommand(T)` payloads
- reject non-schema subcommand payloads
- reject duplicate subcommand names
- reject reserved names such as `help` and `version`
- normalize long names, subcommand names, and value names

Port these upstream seeds:

- `clap/tests/builder/unique_args.rs`
  - duplicate short name
  - duplicate long name
- `clap/tests/builder/positionals.rs`
  - required positional after optional positional
  - positional field must not also claim short / long names
- `clap/tests/builder/subcommands.rs`
  - duplicate subcommand definitions
- `kong/kong_test.go`
  - `TestUnsupportedFieldErrors`
  - `TestInvalidRequiredAfterOptional`
  - `TestDuplicateFlag`
  - `TestDuplicateFlagOnPeerCommandIsOkay`
  - `TestDuplicateShortflags`
  - `TestDuplicateNestedShortFlags`
  - `TestDuplicateName`
  - `TestDuplicateChildName`
  - `TestChildNameCanBeDuplicated`
  - `TestCumulativeArgumentLast`
  - `TestCumulativeArgumentNotLast`
- `kong/tag_test.go`
  - invalid short-flag name as a validation idea only

Implementation note:

- convert the invalid cases above into standalone compile-fail fixtures instead of inline unit tests whenever the failure must happen during comptime schema analysis

## Phase 4 / PR 4

Phase goal:

- scalar conversion and the base runtime parser for a single command scope

Must-have local coverage:

- skip `argv[0]`
- parse flags
- parse short options with separate values
- parse long options with `--name value`
- parse long options with `--name=value`
- positional consumption in declaration order
- optional option omission -> `null`
- optional positional omission -> `null`
- `--` terminator
- unknown option
- missing option value
- missing required positional
- unexpected argument
- duplicate single-use option
- invalid scalar value
- zero-copy borrowed string results

Port these upstream seeds:

- `clap/tests/builder/flags.rs`
  - `flag_using_short`
  - `flag_using_long`
  - `flag_using_mixed`
  - `multiple_flags_in_single`
  - `flag_using_long_with_literals`
- `clap/tests/builder/opts.rs`
  - `opts_using_short`
  - `opts_using_long_space`
  - `opts_using_long_equals`
  - `opts_using_mixed`
  - `opts_using_mixed2`
  - `stdin_char`
  - `double_hyphen_as_value`
  - `leading_hyphen_fail`
- `clap/tests/builder/empty_values.rs`
  - empty string with separate value
  - empty string with `--name=`
  - empty string with `-o=`
- `clap/tests/builder/positionals.rs`
  - `only_pos_follow`
  - `positional`
  - `positional_multiple_2`
  - `missing_required_2`
- `clap/tests/builder/error.rs`
  - `kind_formats_validation_error`
  - `rich_formats_validation_error`
  - `unknown_argument_option`
  - `unknown_argument_flag`
- `clap/tests/builder/possible_values.rs`
  - valid enum value
  - invalid enum value
- `clap_lex/tests/testsuite/lexer.rs`
  - `zero_copy_parsing`
- `clap_lex/tests/testsuite/parsed.rs`
  - `to_long_no_value`
  - `to_long_with_empty_value`
  - `to_long_with_value`
  - `to_short`
  - `is_negative_number`
  - `is_escape`
  - `is_stdio`
- `clap_lex/tests/testsuite/shorts.rs`
  - `next_flag`
  - `next_flag_with_value`
  - `next_flag_with_no_value`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestRequiredFlag`
  - `TestOptionalArg`
  - `TestRequiredArg`
  - `TestShort`
  - `TestEnum`
  - `TestEnumMeaningfulOrder`
  - `TestLoneHpyhen`
- `kong/mapper_test.go`
  - `TestSliceConsumesRemainingPositionalArgs`
  - `TestNumbers`
  - `TestValuesThatLookLikeFlags`
- `kong/scanner_test.go`
  - `TestScannerTake`
  - `TestScannerPeek`

Do not port from upstream in this phase:

- clap `posix_compatible.rs` last-one-wins overrides
- kong negatable flags
- kong aliases
- kong passthrough mode
- kong map and file mappers

## Phase 5 / PR 5

Phase goal:

- repeated positionals, ownership, and cleanup

Must-have local coverage:

- repeated scalar positionals
- repeated string positionals
- empty repeated positionals
- parser-owned slice allocation
- recursive `deinit`
- do not free borrowed string storage from caller-owned `argv`

Port these upstream seeds:

- `clap/tests/builder/positionals.rs`
  - `lots_o_vals`
  - `positional_multiple`
  - `positional_multiple_3`
  - `last_positional`
  - `last_positional_no_double_dash`
  - `last_positional_second_to_last_mult`
- `clap/tests/builder/multiple_values.rs`
  - only the repeated-positional and trailing-value shape ideas
  - do not port repeated-option behavior
- `kong/kong_test.go`
  - `TestArgSlice`
  - `TestCumulativeArgumentLast`
  - `TestCumulativeArgumentNotLast`

Implementation note:

- this phase is where ownership assertions matter most; add explicit allocator accounting tests rather than relying only on behavioral assertions

## Phase 6 / PR 6

Phase goal:

- recursive subcommand parsing

Must-have local coverage:

- one-level subcommands
- nested subcommands
- unknown subcommand
- root options plus subcommand-local arguments
- option values that should remain option values instead of being misclassified as subcommands

Port these upstream seeds:

- `clap/tests/builder/subcommands.rs`
  - `subcommand`
  - `subcommand_none_given`
  - `subcommand_multiple`
  - `issue_1031_args_with_same_name`
  - `issue_1031_args_with_same_name_no_more_vals`
  - `issue_1722_not_emit_error_when_arg_follows_similar_to_a_subcommand`
  - `subcommand_after_argument`
  - `issue_2494_subcommand_is_present`
  - `subcommand_not_recognized`
  - `duplicate_subcommand`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestBranchingArgument` as a structure reference only
  - `TestDuplicateFlagOnPeerCommandIsOkay`

Do not port from upstream in this phase:

- clap alias subcommands
- clap multicall
- clap external subcommands
- kong default commands
- kong dynamic commands

## Phase 7 / PR 7

Phase goal:

- compile-fail fixtures and better diagnostics

Must-have local coverage:

- non-wrapper field types
- duplicate names
- unsupported payload types
- invalid subcommand definitions
- illegal positional ordering
- clear runtime error messages
- reusable argv test helpers

Port these upstream seeds:

- `clap/tests/builder/unique_args.rs`
- `clap/tests/builder/positionals.rs`
- `clap/tests/builder/subcommands.rs`
- `clap/tests/builder/error.rs`
- `kong/kong_test.go`
- `kong/tag_test.go`

Implementation note:

- use upstream wording as a guide for coverage shape, not as exact text to preserve
- `parsz` should optimize for actionable Zig field-path diagnostics instead of matching clap or kong message text exactly

## Phase 8 / PR 8

Phase goal:

- help and version output after the core parser is stable

Must-have local coverage:

- root help output
- subcommand help output
- version output
- snapshot-style regression tests
- reserved-name behavior for `help` and `version`

Port these upstream seeds:

- `clap/tests/builder/help.rs`
- `clap/tests/builder/version.rs`
- `clap/tests/builder/template_help.rs`
- `clap/tests/builder/hidden_args.rs` where relevant
- `kong/help_test.go`
- `kong/model_test.go`
- `kong/util_test.go` for version-flag shape only

Do not port from upstream in this phase:

- clap env-aware help
- clap shell completion snapshots
- clap man-page snapshots
- kong help wrapping version splits that are runtime-version-specific unless `parsz` explicitly wants them

## Suggested Execution Order

1. Phase 3 validation fixtures
2. Phase 4 base parser runtime tests
3. Phase 5 ownership and repeated positional tests
4. Phase 6 subcommand tests
5. Phase 7 diagnostic and compile-fail harness hardening
6. Phase 8 help/version snapshots

## Detailed PR Checklists

The following checklists are intentionally execution-oriented.

- each PR checklist should be completable without depending on a later PR
- later PRs may refine earlier tests, but should not be required to make an earlier PR coherent

### PR 3 Checklist

Goal:

- land schema extraction and compile-time validation with enough local coverage that runtime parser work can trust normalized schema metadata

Preparation:

- [x] Decide the internal normalized schema representation returned by schema extraction.
- [x] Decide the internal representation for:
  - [x] command metadata
  - [x] field metadata
  - [x] positional ordering
  - [x] subcommand tables
- [x] Decide the field-path format used in `@compileError` messages.
- [x] Decide where temporary invalid schema fixtures will live before the dedicated compile-fail harness lands in PR 7.

Implementation:

- [x] Implement wrapper-type detection through the internal comptime contract rather than field-name guessing.
- [x] Implement root command schema validation.
- [x] Implement field-kind extraction for:
  - [x] `Flag`
  - [x] `Option`
  - [x] `Positional`
  - [x] `Subcommand`
- [x] Implement payload-type validation for supported `Option` and `Positional` payloads.
- [x] Implement command metadata extraction from `pub const meta`.
- [x] Implement long-name normalization from field names.
- [x] Implement subcommand-name normalization from union field names.
- [x] Implement value-name normalization from uppercased field names.
- [x] Implement duplicate long-name validation in one command scope.
- [x] Implement duplicate short-name validation in one command scope.
- [x] Implement positional ordering validation:
  - [x] no positional after variadic positional
  - [x] no required positional after optional positional
- [x] Implement `Subcommand(T)` validation:
  - [x] tagged union required
  - [x] payloads must be schema structs
  - [x] only one subcommand field per command scope
  - [x] duplicate subcommand names rejected
- [x] Implement reserved-name validation for `help` and `version`.
- [x] Make `parse` trigger `validateSchema(Schema)` at comptime.

Tests to add in this PR:

- [x] Positive unit tests for normalized defaults:
  - [x] inferred long names
  - [x] inferred value names
  - [x] inferred subcommand names
- [x] Positive unit tests for valid positional layouts.
- [ ] Negative validation tests for:
  - [x] non-struct root
  - [x] tuple struct
  - [x] non-wrapper field
  - [x] unsupported payload type
  - [x] duplicate long name
  - [x] duplicate short name
  - [x] positional after variadic positional
  - [x] required positional after optional positional
  - [x] multiple subcommand fields
  - [x] invalid `Subcommand(T)` argument
  - [ ] duplicate subcommand name
  - [x] reserved `help` / `version` names

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/unique_args.rs`
- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/subcommands.rs`
- [ ] `kong/kong_test.go`
- [ ] `kong/tag_test.go`

Done when:

- [x] normalized schema extraction is reusable by parser code
- [x] invalid schemas fail during comptime with actionable field-qualified diagnostics
- [x] the PR does not rely on runtime parser behavior for validation coverage

### PR 4 Checklist

Goal:

- land scalar conversion and a complete single-command runtime parser

Preparation:

- [x] Decide the runtime parser state structure.
- [x] Decide the long-option lookup table layout.
- [x] Decide the short-option lookup strategy.
- [x] Decide the runtime error payload shape and error set.
- [x] Decide how zero-copy borrowed string outputs are asserted in tests.

Implementation:

- [x] Implement scalar conversion helpers for:
  - [x] signed integers
  - [x] unsigned integers
  - [x] floats
  - [x] enums
  - [x] booleans
  - [x] borrowed `[]const u8`
  - [x] borrowed `[:0]const u8`
- [x] Implement parser startup that skips `argv[0]`.
- [x] Implement token processing before `--`.
- [x] Implement `--name=value`.
- [x] Implement `--name value`.
- [x] Implement short flags.
- [x] Implement short options with separate values.
- [x] Implement combined short flag clusters.
- [x] Implement positional consumption in declaration order.
- [x] Implement `--` terminator handling.
- [x] Implement omission behavior for:
  - [x] flags -> `false`
  - [x] `Option(?T)` -> `null`
  - [x] `Positional(?T)` -> `null`
- [x] Implement runtime failures for:
  - [x] unknown option
  - [x] missing option value
  - [x] missing required positional
  - [x] unexpected argument
  - [x] duplicate single-use option
  - [x] invalid scalar value
- [x] Keep string values borrowed from caller-owned `argv`.

Tests to add in this PR:

- [x] Flag parsing tests:
  - [x] short flag
  - [x] long flag
  - [x] mixed short and long flags
  - [x] combined short flags
  - [x] reject explicit value on plain flag
- [ ] Option parsing tests:
  - [x] short option with separate value
  - [x] long option with separate value
  - [x] long option with `=`
  - [ ] `-` as a value
  - [x] empty string value
  - [ ] leading-hyphen value rejection when not supported
- [x] Positional tests:
  - [x] declaration-order consumption
  - [x] optional positional omission
  - [x] extra positional becomes error in non-variadic schemas
  - [x] missing required positional becomes error
- [x] Terminator tests:
  - [x] `--` makes following tokens positional
  - [x] `--` itself is not consumed as a value unless syntax says so
- [ ] Scalar conversion tests:
  - [ ] integer boundaries
  - [x] float parsing
  - [x] enum success
  - [x] enum failure
  - [x] bool option and bool positional string forms
- [x] Borrowing tests:
  - [x] parsed strings point into caller-owned `argv`
  - [x] no allocation required for non-slice scalar outputs

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/flags.rs`
- [ ] `clap/tests/builder/opts.rs`
- [ ] `clap/tests/builder/empty_values.rs`
- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/error.rs`
- [ ] `clap/tests/builder/possible_values.rs`
- [ ] `clap_lex/tests/testsuite/lexer.rs`
- [ ] `clap_lex/tests/testsuite/parsed.rs`
- [ ] `clap_lex/tests/testsuite/shorts.rs`
- [ ] `kong/kong_test.go`
- [ ] `kong/mapper_test.go`
- [ ] `kong/scanner_test.go`

Done when:

- [x] one command scope can be parsed end-to-end without subcommands or repeated positionals
- [x] runtime failures are typed and test-covered
- [x] zero-copy behavior for scalar string values is explicit in tests

### PR 5 Checklist

Goal:

- land repeated positionals, parser-owned slice storage, and cleanup

Preparation:

- [ ] Decide the internal accumulation strategy for repeated positionals.
- [ ] Decide where allocation bookkeeping lives.
- [ ] Decide how `deinit` discovers which fields own heap storage.
- [ ] Decide allocator-test helpers for leak-sensitive coverage.

Implementation:

- [ ] Implement repeated positional parsing for scalar payloads.
- [ ] Implement repeated positional parsing for borrowed string payloads.
- [ ] Allocate only result slice storage for repeated fields.
- [ ] Preserve zero-copy string element borrowing inside repeated string slices.
- [ ] Produce empty slices for omitted repeated positionals.
- [ ] Implement recursive `deinit` for:
  - [ ] parsed structs
  - [ ] parsed tagged unions
  - [ ] repeated positional slice storage
- [ ] Ensure `deinit` frees parser-owned allocations only.

Tests to add in this PR:

- [ ] Repeated scalar positional tests:
  - [ ] many values
  - [ ] zero values
  - [ ] interleaving with root flags where valid
- [ ] Repeated string positional tests:
  - [ ] many values
  - [ ] values after `--`
  - [ ] trailing-last positional behavior
- [ ] Ownership tests:
  - [ ] repeated result storage is allocated
  - [ ] element strings still borrow from `argv`
  - [ ] `deinit` frees owned slice storage
  - [ ] `deinit` does not free borrowed `argv` memory
- [ ] Validation interaction tests:
  - [ ] repeated positional must be last positional
  - [ ] required-after-optional rule still holds

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/positionals.rs`
- [ ] selected repeated-positional shape cases from `clap/tests/builder/multiple_values.rs`
- [ ] `kong/kong_test.go`

Done when:

- [ ] repeated positionals work for supported payloads
- [ ] ownership boundaries are explicit and regression-tested
- [ ] `parsz.deinit` is required and sufficient for parser-owned storage

### PR 6 Checklist

Goal:

- land recursive subcommand parsing on top of the shared schema model

Preparation:

- [ ] Decide the compile-time subcommand lookup representation.
- [ ] Decide how recursive parse state is passed into child command scopes.
- [ ] Decide unknown-subcommand diagnostic context format.

Implementation:

- [ ] Build subcommand lookup tables from normalized schema data.
- [ ] Detect when the next token should be interpreted as a subcommand.
- [ ] Recurse into the chosen payload schema.
- [ ] Return the parsed tagged-union shape defined by `Parsed(Schema)`.
- [ ] Preserve root-scope option parsing before subcommand dispatch.
- [ ] Preserve subcommand-local option and positional parsing after dispatch.
- [ ] Report unknown subcommand errors with command-scope context.

Tests to add in this PR:

- [ ] One-level subcommand tests:
  - [ ] select first subcommand
  - [ ] select among siblings
  - [ ] no subcommand selected when field is optional by schema shape
- [ ] Nested subcommand tests:
  - [ ] recurse one additional level
  - [ ] parse local arguments at nested scope
- [ ] Ambiguity / classification tests:
  - [ ] option value should remain option value, not subcommand
  - [ ] positional value should remain positional when schema allows it
  - [ ] subcommand after earlier positional when schema still permits it
- [ ] Error tests:
  - [ ] unknown subcommand
  - [ ] duplicate subcommand definitions should still be compile-time failures

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/subcommands.rs`
- [ ] `kong/kong_test.go`

Done when:

- [ ] root and subcommand scopes share one parser model
- [ ] parsed subcommand results match `Parsed(Schema)`
- [ ] error coverage includes wrong-token classification at command boundaries

### PR 7 Checklist

Goal:

- land a durable compile-fail harness and improve diagnostics enough to prevent validation regressions

Preparation:

- [x] Decide fixture directory layout.
- [x] Decide naming convention for compile-fail cases.
- [x] Decide how expected failures are matched in CI.
- [ ] Decide shared argv helper API for runtime tests.

Implementation:

- [x] Implement the compile-fail harness in the build or test pipeline.
- [x] Move temporary invalid-schema cases into dedicated fixtures.
- [ ] Add reusable argv fixture builders in `src/testing.zig`.
- [ ] Add runtime diagnostic payload formatting helpers.
- [ ] Normalize error wording for:
  - [ ] compile-time field-path diagnostics
  - [ ] runtime parse failures

Fixtures and tests to add in this PR:

- [ ] Compile-fail fixtures:
  - [x] non-wrapper field
  - [x] duplicate long name
  - [x] duplicate short name
  - [x] unsupported payload type
  - [x] invalid subcommand union
  - [x] subcommand payload not a schema struct
  - [ ] duplicate subcommand name
  - [x] required positional after optional positional
  - [x] positional after variadic positional
  - [x] reserved `help`
  - [x] reserved `version`
- [ ] Runtime diagnostic tests:
  - [ ] unknown option message shape
  - [ ] missing option value message shape
  - [ ] missing required positional message shape
  - [ ] invalid scalar value message shape
  - [ ] unknown subcommand message shape

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/unique_args.rs`
- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/subcommands.rs`
- [ ] `clap/tests/builder/error.rs`
- [ ] `kong/kong_test.go`
- [ ] `kong/tag_test.go`

Done when:

- [x] invalid schema regressions are caught by fixture compilation
- [ ] runtime diagnostics are consistent and easy to act on
- [ ] test helpers reduce duplication in later PRs

### PR 8 Checklist

Goal:

- land help and version output on top of the stabilized schema and parser core

Preparation:

- [ ] Decide the normalized metadata shape needed by help rendering.
- [ ] Decide snapshot format for help and version tests.
- [ ] Decide whether help rendering tests compare exact strings or normalized snapshots.

Implementation:

- [ ] Finalize metadata plumbing for `name`, `version`, and `about`.
- [ ] Implement root help generation.
- [ ] Implement subcommand help generation.
- [ ] Implement version output generation.
- [ ] Preserve reserved-name behavior for `help` and `version`.
- [ ] Update README examples that expose the user-facing help/version UX.

Tests to add in this PR:

- [ ] Root help snapshot.
- [ ] Subcommand help snapshot.
- [ ] Nested subcommand help snapshot.
- [ ] Version output snapshot.
- [ ] Reserved-name validation remains intact when help/version features are enabled.
- [ ] Help output uses the same normalized schema source of truth as parsing and validation.

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/help.rs`
- [ ] `clap/tests/builder/version.rs`
- [ ] `clap/tests/builder/template_help.rs`
- [ ] `clap/tests/builder/hidden_args.rs` where relevant
- [ ] `kong/help_test.go`
- [ ] `kong/model_test.go`
- [ ] `kong/util_test.go`

Done when:

- [ ] help and version behavior are stable enough for snapshot regression tests
- [ ] metadata is rendered from one schema source of truth
- [ ] public documentation matches actual parser behavior

## Companion Documents

- `todo.md`

## Upstream Audit Appendix

This appendix keeps the full upstream audit material inside the main test plan.

Its purpose is different from the PR checklists above:

- the PR checklists tell us what to implement next
- this appendix records why a given upstream area is in scope, later scope, or out of scope
- this appendix preserves the full portability review so the project can justify both inclusions and exclusions

### Survey basis

- Local plan: `plan.md`
- Local task breakdown: `todo.md`
- `clap-rs/clap` inspected at `70f3bb31874ff24233f18c394982407ca90d0dcc` (`2026-03-12`, `chore: Release`)
- `alecthomas/kong` inspected at `258b13ac944d17b24a683ff23200933c89555fb7` (`2026-02-07`, `fix: Do not open the default file that might be non existent if the value was already set (#580)`)

### Verdict legend

- `Adopt now`: directly portable to the current `plan.md` / `todo.md`
- `Later`: useful only after later planned work
- `Skip`: not a fit for `parsz` because of scope mismatch, API mismatch, or an explicit MVP exclusion

### parsz scope anchor

The current plan says the MVP is:

- standard library only
- GNU-style parsing with POSIX-inspired rules
- declarative wrapper types: `Flag`, `Option`, `Positional`, `Subcommand`
- compile-time schema validation
- zero-copy borrowed strings from caller-owned `argv`
- scalar conversion for bool / ints / floats / enums / strings
- repeated positional slices
- recursive subcommands

The current plan explicitly excludes:

- environment-variable integration
- config loading
- shell completion generation
- custom decoders / custom parsers
- maps
- repeated option values
- repeated short-count flags such as `-vvv`
- rich relation logic such as conflicts / groups / xor / and
- user-defined non-null defaults beyond the narrow MVP defaults

### Highest-value imports

These are the upstream tests that were identified as the best early imports.

#### Phase 3: schema extraction and compile-time validation

- `clap/tests/builder/unique_args.rs`
  - duplicate long names
  - duplicate short names
- `clap/tests/builder/subcommands.rs`
  - duplicate subcommand names
- `clap/tests/builder/positionals.rs`
  - required positional after optional positional should fail
  - positional fields must not also have short / long names
- `kong/kong_test.go`
  - `TestUnsupportedFieldErrors`
  - `TestInvalidRequiredAfterOptional`
  - `TestDuplicateFlag`
  - `TestDuplicateFlagOnPeerCommandIsOkay`
  - `TestDuplicateShortflags`
  - `TestDuplicateNestedShortFlags`
  - `TestDuplicateName`
  - `TestDuplicateChildName`
  - `TestChildNameCanBeDuplicated`
  - `TestCumulativeArgumentLast`
  - `TestCumulativeArgumentNotLast`

#### Phase 4: base runtime parser

- `clap/tests/builder/flags.rs`
  - `flag_using_short`
  - `flag_using_long`
  - `flag_using_mixed`
  - `multiple_flags_in_single`
  - `flag_using_long_with_literals`
- `clap/tests/builder/opts.rs`
  - `opts_using_short`
  - `opts_using_long_space`
  - `opts_using_long_equals`
  - `opts_using_mixed`
  - `opts_using_mixed2`
  - `stdin_char`
  - `double_hyphen_as_value`
  - `leading_hyphen_fail`
- `clap/tests/builder/positionals.rs`
  - `only_pos_follow`
  - `positional`
  - `positional_multiple_2`
  - `missing_required_2`
- `clap/tests/builder/error.rs`
  - `kind_formats_validation_error`
  - `rich_formats_validation_error`
  - `unknown_argument_option`
  - `unknown_argument_flag`
- `clap_lex/tests/testsuite/parsed.rs`
  - `to_long_no_value`
  - `to_long_with_empty_value`
  - `to_long_with_value`
  - `to_short`
  - `is_negative_number`
  - `is_escape`
- `clap_lex/tests/testsuite/shorts.rs`
  - `next_flag`
  - `next_flag_with_value`
  - `next_flag_with_no_value`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestRequiredFlag`
  - `TestOptionalArg`
  - `TestRequiredArg`
  - `TestShort`
  - `TestEnum`
  - `TestEnumMeaningfulOrder`
  - `TestLoneHpyhen`
- `kong/mapper_test.go`
  - `TestSliceConsumesRemainingPositionalArgs`
  - `TestNumbers`
  - `TestValuesThatLookLikeFlags`
- `kong/scanner_test.go`
  - `TestScannerTake`
  - `TestScannerPeek`

#### Phase 5: repeated positionals and ownership

- `clap/tests/builder/positionals.rs`
  - `lots_o_vals`
  - `positional_multiple`
  - `positional_multiple_3`
  - `last_positional`
  - `last_positional_no_double_dash`
- `clap/tests/builder/multiple_values.rs`
  - keep only the repeated-positional / `--` / trailing-value parts
  - do not copy repeated-option tests
- `kong/kong_test.go`
  - `TestArgSlice`
  - `TestArgSliceWithSeparator` only as a negative reference because `parsz` does not split positional strings by separator

#### Phase 6: subcommands

- `clap/tests/builder/subcommands.rs`
  - `subcommand`
  - `subcommand_none_given`
  - `subcommand_multiple`
  - `issue_1031_args_with_same_name`
  - `issue_1031_args_with_same_name_no_more_vals`
  - `subcommand_after_argument`
  - `issue_2494_subcommand_is_present`
  - `subcommand_not_recognized`
  - `duplicate_subcommand`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestBranchingArgument` only as a structural reference
  - `TestDuplicateFlagOnPeerCommandIsOkay`

### Full clap audit

#### Repo-wide verdict

- `tests/builder/*`: mixed; this is the main source of reusable runtime/parser cases
- `tests/derive/*`: `Skip` as direct ports; these files are tightly coupled to Rust derive / proc-macro behavior
- `tests/derive_ui/*` and `tests/derive_ui.rs`: `Skip`; compile-fail coverage is about proc-macro diagnostics, not a `@compileError`-driven Zig schema surface
- `tests/ui/*` and `tests/ui.rs`: `Later` only for help/version snapshot behavior
- `clap_lex/tests/testsuite/*`: `Adopt now`; this is the best upstream source for tokenization and zero-copy borrowing ideas
- `clap_complete/tests/*`, `clap_complete_nushell/tests/*`, `clap_mangen/tests/*`: `Skip`; shell completion and man-page generation are outside current `parsz` scope

#### `tests/builder/*`

| File                                    | Verdict             | Notes                                                                                                                                                   |
| --------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tests/builder/action.rs`               | Skip                | Clap `ArgAction` API is not `parsz` API. Core boolean/set semantics are better covered elsewhere.                                                       |
| `tests/builder/app_settings.rs`         | Later (partial)     | Keep only subcommand-required and selected hyphen-handling ideas. Skip inference, external subcommands, global color, and other clap-specific switches. |
| `tests/builder/arg_aliases.rs`          | Skip                | Aliases are not in the current plan.                                                                                                                    |
| `tests/builder/arg_aliases_short.rs`    | Skip                | Short aliases are not in the current plan.                                                                                                              |
| `tests/builder/arg_matches.rs`          | Skip                | This is about `clap::ArgMatches` API shape, not `parsz` runtime behavior.                                                                               |
| `tests/builder/borrowed.rs`             | Skip                | This validates clap builder object reuse, not zero-copy parsed values.                                                                                  |
| `tests/builder/cargo.rs`                | Skip                | Cargo metadata helpers are unrelated.                                                                                                                   |
| `tests/builder/command.rs`              | Skip                | Builder smoke test, low value for `parsz`.                                                                                                              |
| `tests/builder/conflicts.rs`            | Skip                | Conflicts / exclusivity / groups are outside MVP.                                                                                                       |
| `tests/builder/default_missing_vals.rs` | Skip                | Missing-value defaults are outside MVP.                                                                                                                 |
| `tests/builder/default_vals.rs`         | Skip                | User-defined defaults are outside MVP.                                                                                                                  |
| `tests/builder/delimiters.rs`           | Skip                | Mostly repeated-option delimiter behavior, which `parsz` excludes.                                                                                      |
| `tests/builder/derive_order.rs`         | Later               | Help / display-order behavior only.                                                                                                                     |
| `tests/builder/display_order.rs`        | Later               | Help / display-order behavior only.                                                                                                                     |
| `tests/builder/double_require.rs`       | Skip                | Complex requirement composition is outside MVP.                                                                                                         |
| `tests/builder/empty_values.rs`         | Adopt now (partial) | Good source for empty-string option values and missing-value error precedence.                                                                          |
| `tests/builder/env.rs`                  | Skip                | Environment-variable integration is explicitly out of MVP.                                                                                              |
| `tests/builder/error.rs`                | Adopt now (partial) | Good source for unknown-argument and missing-value error kinds. Rich formatting is useful later.                                                        |
| `tests/builder/flag_subcommands.rs`     | Skip                | Flag subcommands are not in the plan.                                                                                                                   |
| `tests/builder/flags.rs`                | Adopt now (partial) | Core short/long/clustered flag parsing. Skip counted/repeated flag behavior and flag-with-optional-value cases.                                         |
| `tests/builder/global_args.rs`          | Skip                | Global-argument propagation is not planned.                                                                                                             |
| `tests/builder/groups.rs`               | Skip                | Argument groups are outside MVP.                                                                                                                        |
| `tests/builder/help.rs`                 | Later               | Post-MVP help generation and formatting.                                                                                                                |
| `tests/builder/help_env.rs`             | Skip                | Help plus env integration, both outside current scope.                                                                                                  |
| `tests/builder/hidden_args.rs`          | Later               | Help visibility only.                                                                                                                                   |
| `tests/builder/ignore_errors.rs`        | Skip                | Error-ignoring mode is not in the plan.                                                                                                                 |
| `tests/builder/indices.rs`              | Skip                | Argument index bookkeeping is not part of the public `parsz` contract.                                                                                  |
| `tests/builder/macros.rs`               | Skip                | Clap macro API coverage, not `parsz` behavior.                                                                                                          |
| `tests/builder/main.rs`                 | Skip                | Test harness entrypoint only.                                                                                                                           |
| `tests/builder/multiple_occurrences.rs` | Skip                | Repeated flag occurrence counting is outside MVP.                                                                                                       |
| `tests/builder/multiple_values.rs`      | Adopt now (partial) | Keep repeated positional and `--`/trailing parsing cases. Skip repeated-option and delimiter-heavy cases.                                               |
| `tests/builder/occurrences.rs`          | Skip                | Grouped occurrences / repeated option grouping are outside MVP.                                                                                         |
| `tests/builder/opts.rs`                 | Adopt now (partial) | Best source for short/long options, `--name=value`, `--name value`, hyphen-looking values, and empty/equals edge cases. Skip defaults and inference.    |
| `tests/builder/positionals.rs`          | Adopt now (partial) | Best source for declaration-order consumption, `--` terminator, repeated positionals, and positional validation errors.                                 |
| `tests/builder/posix_compatible.rs`     | Skip                | `parsz` currently wants duplicate single-use option errors, not last-one-wins override semantics.                                                       |
| `tests/builder/possible_values.rs`      | Adopt now (partial) | Good enum/allowed-value coverage. Skip aliases, case-insensitive matching, and help rendering.                                                          |
| `tests/builder/propagate_globals.rs`    | Skip                | Global propagation is not planned.                                                                                                                      |
| `tests/builder/require.rs`              | Later (partial)     | Keep only the simplest missing-required positional/option coverage. Most conditional-require logic is outside MVP.                                      |
| `tests/builder/subcommands.rs`          | Adopt now (partial) | Main upstream source for recursive subcommand dispatch, unknown subcommand, and duplicate subcommand validation. Skip aliases, suggestions, multicall.  |
| `tests/builder/template_help.rs`        | Later               | Help templating only.                                                                                                                                   |
| `tests/builder/tests.rs`                | Adopt now (partial) | Useful as compact integration combinations once the core parser exists. Skip clap-specific output plumbing.                                             |
| `tests/builder/unicode.rs`              | Skip                | Case-insensitive possible-values behavior is explicitly excluded.                                                                                       |
| `tests/builder/unique_args.rs`          | Adopt now           | Direct analogue for duplicate long / short validation in one command scope.                                                                             |
| `tests/builder/utf16.rs`                | Skip                | OS-specific UTF-16 / `OsString` behavior is not a direct match for current `[]const u8` `parsz` API.                                                    |
| `tests/builder/utf8.rs`                 | Skip                | Mostly invalid-UTF8 / external-subcommand behavior. The current `parsz` API is byte-slice based and not targeting clap's `OsStr` matrix.                |
| `tests/builder/utils.rs`                | Skip                | Test helper only.                                                                                                                                       |
| `tests/builder/version.rs`              | Later               | Post-MVP version flag behavior.                                                                                                                         |

#### `clap_lex/tests/testsuite/*`

| File                                 | Verdict   | Notes                                                                                               |
| ------------------------------------ | --------- | --------------------------------------------------------------------------------------------------- |
| `clap_lex/tests/testsuite/lexer.rs`  | Adopt now | `zero_copy_parsing` is directly relevant to `parsz` borrowed-string design.                         |
| `clap_lex/tests/testsuite/main.rs`   | Skip      | Harness file only.                                                                                  |
| `clap_lex/tests/testsuite/parsed.rs` | Adopt now | Excellent source for `--`, `-`, `--name=`, short-cluster, and negative-number token classification. |
| `clap_lex/tests/testsuite/shorts.rs` | Adopt now | Excellent source for short-cluster iteration and short-with-inline-value handling.                  |

### Full kong audit

| File                     | Verdict                          | Notes                                                                                                                                                                                                                                                                               |
| ------------------------ | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `benchmark_test.go`      | Skip                             | Performance benchmark, not correctness coverage.                                                                                                                                                                                                                                    |
| `config_test.go`         | Skip                             | Config loading is outside MVP.                                                                                                                                                                                                                                                      |
| `defaults_test.go`       | Skip                             | Broad default application is outside MVP.                                                                                                                                                                                                                                           |
| `global_test.go`         | Skip                             | Internal bad-build handling, low direct value.                                                                                                                                                                                                                                      |
| `help_test.go`           | Later                            | Post-MVP help text and usage rendering.                                                                                                                                                                                                                                             |
| `helpwrap1.18_test.go`   | Later                            | Help wrapping only.                                                                                                                                                                                                                                                                 |
| `helpwrap1.19_test.go`   | Later                            | Help wrapping only.                                                                                                                                                                                                                                                                 |
| `interpolate_test.go`    | Skip                             | Variable interpolation is not planned.                                                                                                                                                                                                                                              |
| `kong_test.go`           | Adopt now / later / skip (mixed) | Main source for schema validation, required/optional args, short flags, enum validation, duplicate names, lone `-`, and cumulative last positional. Skip negatable flags, aliases, xor/and, hooks, plugins, providers, default commands, passthrough commands, pointers, callbacks. |
| `mapper_linux_test.go`   | Skip                             | OS path mappers are outside scope.                                                                                                                                                                                                                                                  |
| `mapper_test.go`         | Adopt now (partial)              | Keep `TestSliceConsumesRemainingPositionalArgs`, `TestNumbers`, and `TestValuesThatLookLikeFlags` as references. Skip maps, file mappers, custom mapper plumbing, JSON resolver cases, and passthrough mode.                                                                        |
| `mapper_windows_test.go` | Skip                             | OS path/file mappers are outside scope.                                                                                                                                                                                                                                             |
| `model_test.go`          | Later (partial)                  | `TestModelApplicationCommands` is a mild reference for command-tree leaf paths. The rest is help formatting.                                                                                                                                                                        |
| `options_test.go`        | Skip                             | Callback / provider / binding API is not planned.                                                                                                                                                                                                                                   |
| `resolver_test.go`       | Skip                             | Env / JSON / resolver layering is outside MVP.                                                                                                                                                                                                                                      |
| `scanner_test.go`        | Adopt now                        | Simple but useful tokenizer expectations, especially that lone `-` behaves like a positional value.                                                                                                                                                                                 |
| `signature_test.go`      | Skip                             | Function-signature-based command generation is unrelated to `parsz`.                                                                                                                                                                                                                |
| `tag_test.go`            | Skip as direct ports             | This is about Go struct-tag parsing. Keep only the conceptual lessons around invalid short names and duplicate aliases.                                                                                                                                                             |
| `util_test.go`           | Skip                             | Config/version/chdir helper behavior is unrelated.                                                                                                                                                                                                                                  |

### Practical porting order

1. Start from `clap_lex` token tests and `kong/scanner_test.go`.
2. Port the simplest `clap/tests/builder/flags.rs`, `opts.rs`, and `positionals.rs` cases.
3. Add `kong/kong_test.go` validation cases for duplicate names and positional ordering.
4. Add `clap/tests/builder/subcommands.rs` after recursive schema extraction exists.
5. Add selected `kong/mapper_test.go` numeric-boundary tests once scalar conversion is implemented.
6. Leave all help/version/env/config/alias/conflict/group/default-command work for after the current roadmap reaches those features.

### Source links

- Local scope documents:
  - `plan.md`
  - `todo.md`
- clap repository revision:
  - <https://github.com/clap-rs/clap/tree/70f3bb31874ff24233f18c394982407ca90d0dcc>
- Kong repository revision:
  - <https://github.com/alecthomas/kong/tree/258b13ac944d17b24a683ff23200933c89555fb7>
- Key clap files:
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/flags.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/opts.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/positionals.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/subcommands.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/unique_args.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/clap_lex/tests/testsuite/lexer.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/clap_lex/tests/testsuite/parsed.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/clap_lex/tests/testsuite/shorts.rs>
- Key kong files:
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/kong_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/mapper_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/scanner_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/tag_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/help_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/resolver_test.go>
