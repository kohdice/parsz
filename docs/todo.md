# parsz Implementation TODO

## Working Rules

- [ ] Keep each phase small enough to ship as one PR.
- [ ] Keep this TODO as a review-friendly PR breakdown of the 4 delivery phases in `plan.md`.
- [ ] Keep it explicit that the numbered phases below are PR phases, not a one-to-one restatement of the delivery-phase numbers in `plan.md`.
- [ ] Keep detailed phase-by-phase test-porting plans in `test.md`.
- [ ] Use the Zig standard library only.
- [ ] Keep schema field wrapper types as the single source of truth for CLI definitions.
- [ ] Preserve zero-copy behavior for borrowed string values from caller-owned `argv`.
- [ ] Add tests in the same PR that introduces behavior.
- [ ] Keep code comments and project docs in English.

## MVP Boundaries

- [ ] Do not add environment variable integration in the MVP.
- [ ] Do not add config file loading in the MVP.
- [ ] Do not add shell completion generation in the MVP.
- [ ] Do not add maps in the MVP.
- [ ] Do not add nested embedded option groups in the MVP.
- [ ] Do not add rich validation hooks or custom decoders in the MVP.
- [ ] Do not add repeated option values in the MVP.
- [ ] Do not add repeated short-count flags such as `-vvv` in the MVP.
- [ ] Do not add case-insensitive enum parsing in the MVP.
- [ ] Do not add user-specified non-null default values beyond `Flag(false)`, `?T = null`, and empty repeated positional slices in the MVP.

## Phase 1 / PR 1: Bootstrap the library skeleton and public schema wrappers

Goal

- [x] Establish the initial source layout and the public schema declaration API.

Scope

- [x] Add the initial module layout described in the plan:
  - [x] `src/parsz.zig`
  - [x] `src/field.zig`
  - [x] `src/schema.zig`
  - [x] `src/parsed.zig`
  - [x] `src/parse.zig`
  - [x] `src/convert.zig`
  - [x] `src/deinit.zig`
  - [x] `src/error.zig`
  - [x] `test/schema_declaration_test.zig`
- [x] Add the minimum Zig entry/test wiring needed to compile and run library tests.

Implementation TODO

- [x] Export the intended public API surface from `src/parsz.zig`.
- [x] Lock the single public parsing API contract in `src/parsz.zig`:
  - [x] `pub fn parse(comptime Schema: type, allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Parsed(Schema)`
  - [x] `pub fn deinit(comptime Schema: type, allocator: std.mem.Allocator, value: *Parsed(Schema)) void`
- [x] Keep allocator acceptance explicit in the public API even when a specific parse performs no allocation.
- [x] Keep process argument acquisition out of the parsing API so the library only parses caller-provided `argv`.
- [x] Define public wrapper constructors in `src/field.zig`:
  - [x] `Flag(meta)`
  - [x] `Option(T, meta)`
  - [x] `Positional(T, meta)`
  - [x] `Subcommand(T)`
- [x] Define the internal compile-time contract exposed by wrapper types:
  - [x] field kind
  - [x] parsed value type
  - [x] field metadata
- [x] Define the metadata shapes needed by the MVP:
  - [x] field-level metadata
  - [x] command-level `meta`
  - [x] root command `meta` supports `name`, `version`, and `about`
  - [x] subcommand payload `meta` supports `about`
- [x] Add compile-only smoke tests for representative root command schemas and subcommand schemas.

Exit Criteria

- [x] A user can declare a CLI schema using the public wrapper types.
- [x] The public type-level contract is stable enough for follow-up PRs.

## Phase 2 / PR 2: Implement `Parsed(Schema)` type generation

Goal

- [x] Generate plain runtime value types from declarative schema types.

Implementation TODO

- [x] Implement `Parsed(Schema)` in `src/parsed.zig`.
- [x] Transform command schema structs into plain parsed structs.
- [x] Transform `Flag(...)` into `bool`.
- [x] Transform `Option(T, ...)` into `T`.
- [x] Transform `Positional(T, ...)` into `T`.
- [x] Transform `Subcommand(union(enum))` into a recursively transformed parsed tagged union.
- [x] Preserve optional types exactly as declared in schema payloads.
- [x] Preserve repeated positional slice shapes exactly as declared in schema payloads.

Tests

- [x] Add positive tests for representative parsed type shapes.
- [x] Add tests for nested subcommand result types.
- [x] Add tests for optional and repeated positional result types.

Exit Criteria

- [x] `parsz.Parsed(Schema)` is stable enough to anchor later parser and cleanup work.

## Phase 3 / PR 3: Implement schema extraction and compile-time validation

Goal

- [x] Extract normalized schema metadata and reject invalid schema definitions at compile time.
- [ ] Follow `test.md` -> `PR 3 Checklist` for the implementation-order task breakdown.

Implementation TODO

- [x] Implement schema extraction in `src/schema.zig` using reflection.
- [x] Run `validateSchema(Schema)` from `parse`.
- [x] Make the validation path the canonical rejection point for unsupported schema shapes before `Parsed(Schema)` would otherwise build partial runtime types.
- [x] Reject non-struct root schemas.
- [x] Reject tuple structs.
- [x] Reject fields that are not `parsz` schema field types.
- [x] Validate supported payload types for `Option` and `Positional`.
- [x] Validate duplicate long names within one command scope.
- [x] Validate duplicate short names within one command scope.
- [x] Validate positional ordering rules:
  - [x] no positional fields after a variadic positional
  - [x] no required positional fields after optional positional fields
- [x] Validate that each command schema has at most one `Subcommand(...)` field.
- [x] Validate that `Subcommand(T)` receives a tagged union.
- [x] Validate that each subcommand payload is a command schema struct.
- [x] Validate duplicate subcommand names in the same scope.
- [x] Validate command metadata rules:
  - [x] root command schemas may define `name`, `version`, and `about`
  - [x] subcommand payload schemas may define `about`
  - [x] subcommand payload schemas do not define independent `version` values
- [x] Reject reserved names such as `help` and `version` for the MVP.
- [x] Normalize omitted metadata:
  - [x] long names from field names
  - [x] subcommand names from union field names
  - [x] value names from uppercased field names
- [x] Keep positional order sourced from field declaration order with no separate public positional index.
- [x] Produce field-qualified `@compileError` messages that identify the failing path clearly.

Tests

- [x] Add positive tests for normalized metadata defaults.
- [x] Add positive tests for valid positional ordering.
- [x] Add targeted validation tests for each supported field kind.
- [x] Track detailed upstream validation seeds in `test.md`.

Exit Criteria

- [x] Invalid schemas fail fast at compile time with actionable diagnostics.
- [x] Follow-up runtime parser work can depend on normalized extracted schema data.

## Phase 4 / PR 4: Implement scalar conversion and the base runtime parser

Goal

- [x] Parse flags, options, and positional values for a single command scope.
- [ ] Follow `test.md` -> `PR 4 Checklist` for the implementation-order task breakdown.

Implementation TODO

- [x] Implement runtime parse errors in `src/error.zig`.
- [x] Implement scalar conversion helpers in `src/convert.zig`:
  - [x] integers via `std.fmt.parseInt`
  - [x] floats via `std.fmt.parseFloat`
  - [x] enums via `std.meta.stringToEnum`
  - [x] booleans from `true` and `false`
  - [x] borrowed string-like values from `argv`
- [x] Implement the parser state machine in `src/parse.zig`.
- [x] Skip `argv[0]` and parse over `argv[1..]`.
- [x] Track the `--` terminator.
- [x] Build compile-time long option lookup with `std.StaticStringMap(...).initComptime(...)`.
- [x] Support long options:
  - [x] `--name=value`
  - [x] `--name value`
- [x] Support short options and flags:
  - [x] `-v`
  - [x] `-o value`
- [x] Consume positional values in declaration order.
- [x] Treat omitted `Option(?T, ...)` values as `null`.
- [x] Treat omitted `Positional(?T, ...)` values as `null`.
- [x] Report runtime errors for:
  - [x] unknown option
  - [x] missing option value
  - [x] missing required positional
  - [x] unexpected argument
  - [x] duplicate single-use option
  - [x] invalid scalar value
- [x] Keep string results zero-copy when borrowing from `argv`.

Tests

- [x] Add runtime tests for simple flags.
- [x] Add runtime tests for required and optional options.
- [x] Add runtime tests for optional positional omission.
- [x] Add runtime tests for positional parsing order.
- [x] Add runtime tests for `--` handling.
- [x] Add runtime tests for enum parsing.
- [x] Track detailed upstream runtime seeds in `test.md`.

Exit Criteria

- [x] A single command schema without repeated positionals or subcommands can be parsed end to end.

## Phase 5 / PR 5: Add repeated positionals, allocation ownership, and `deinit`

Goal

- [ ] Support dynamic positional slices without breaking the ownership model.
- [ ] Follow `test.md` -> `PR 5 Checklist` for the implementation-order task breakdown.

Implementation TODO

- [ ] Implement repeated positional parsing for `[]const T` payloads.
- [ ] Allocate only the slice storage owned by the parser.
- [ ] Keep scalar and borrowed string values zero-copy where possible.
- [ ] Implement parser-owned allocation tracking if needed by the chosen representation.
- [ ] Implement recursive cleanup in `src/deinit.zig`.
- [ ] Ensure `deinit` frees only parser-owned allocations.
- [ ] Ensure empty repeated positionals produce empty slices rather than errors.
- [ ] Verify optional and repeated positional behavior does not violate ordering rules enforced by validation.

Tests

- [ ] Add runtime tests for repeated scalar positionals.
- [ ] Add runtime tests for repeated string positionals.
- [ ] Add allocation and cleanup tests for parser-owned slices.
- [ ] Add tests for empty repeated positional results.
- [ ] Track detailed repeated-positional seed coverage in `test.md`.

Exit Criteria

- [ ] Dynamic slices work correctly and can be cleaned up safely with `parsz.deinit`.

## Phase 6 / PR 6: Add subcommand parsing and recursive command scopes

Goal

- [ ] Support nested command trees using the same schema rules as the root command.
- [ ] Follow `test.md` -> `PR 6 Checklist` for the implementation-order task breakdown.

Implementation TODO

- [ ] Build the compile-time subcommand lookup table.
- [ ] Use `std.StaticStringMap(...).initComptime(...)` for subcommand name lookup.
- [ ] Recurse into the selected payload schema when a subcommand field is reached.
- [ ] Preserve the normalized subcommand naming rules from schema extraction.
- [ ] Return the transformed tagged union shape defined by `Parsed(Schema)`.
- [ ] Report unknown subcommand errors with the correct command scope context.
- [ ] Confirm that option/positional parsing behavior remains correct inside subcommand payloads.

Tests

- [ ] Add runtime tests for one-level subcommands.
- [ ] Add runtime tests for nested subcommand payload parsing.
- [ ] Add runtime tests for unknown subcommand errors.
- [ ] Add runtime tests combining root options and subcommand-local arguments.
- [ ] Track detailed subcommand seed coverage in `test.md`.

Exit Criteria

- [ ] Root commands and subcommands share one consistent parsing and validation model.

## Phase 7 / PR 7: Improve diagnostics and add compile-fail fixtures

Goal

- [ ] Make schema and runtime failures easier to debug and harder to regress.
- [ ] Follow `test.md` -> `PR 7 Checklist` for the implementation-order task breakdown.

Implementation TODO

- [x] Add a fixture-based compile-fail test harness.
- [x] Add invalid fixture coverage for:
  - [x] non-wrapper field types
  - [x] duplicate names
  - [x] unsupported payload types
  - [x] invalid subcommand definitions
  - [x] illegal positional ordering
- [ ] Add runtime diagnostic payloads or formatting helpers for parse failures.
- [ ] Review error messages for field path clarity and consistent wording.
- [ ] Add reusable `argv` test helpers in `src/testing.zig`.
- [ ] Convert the selected upstream validation seeds from `test.md` into standalone compile-fail fixtures.

Exit Criteria

- [ ] The project has stable regression coverage for both compile-time and runtime failures.

## Phase 8 / PR 8: Post-MVP help/version support

Goal

- [ ] Add user-facing help and version output after the core parser is stable.
- [ ] Follow `test.md` -> `PR 8 Checklist` for the implementation-order task breakdown.

Implementation TODO

- [ ] Finalize metadata plumbing for `name`, `version`, and `about`.
- [ ] Implement help text generation from normalized schema metadata.
- [ ] Implement version output generation from root command metadata.
- [ ] Preserve MVP reserved-name behavior for `help` and `version`.
- [ ] Add snapshot-style tests for help and version output.
- [ ] Update README usage examples to include the new UX.
- [ ] Revisit detailed help/version snapshot seeds from `test.md` after the core parser stabilizes.

Exit Criteria

- [ ] Help and version output are generated from the same schema source of truth.

## Cross-Phase Review Checklist

- [ ] The PR sequence remains traceable back to the 4 delivery phases in `plan.md`.
- [ ] Each PR keeps the public API coherent and reviewable on its own.
- [ ] Each PR lands with tests that cover the newly added behavior.
- [ ] Zero-copy guarantees remain explicit in code and tests.
- [ ] Allocation ownership remains explicit in code and tests.
- [ ] Compile-time validation remains the first line of defense for bad schemas.

## Source Material

- [ ] `plan.md`
- [ ] `plan_ja.md`
- [ ] `README.md`
- [ ] `test.md`
