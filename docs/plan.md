# parsz MVP Implementation Plan

## Goals

- Standard library only.
- GNU-style CLI parser with POSIX-inspired core rules.
- Declarative CLI definitions using public `parsz` schema field types as a single source of truth.
- Compile-time validation with `@typeInfo` and `@compileError`.
- Fast parsing with zero-copy behavior when the caller owns `argv`.
- Automatic help/version generation later, but the schema model should support it from the start.

## Non-Goals for MVP

- Auto-generated help and version output.
- Environment variable integration.
- Config file loading.
- Shell completion generation.
- Rich validation hooks and custom decoders beyond a narrow built-in type set.
- User-specified non-null default values beyond `Flag(false)`, `?T = null`, and empty variadic positional slices.

## Key Design Decisions

### 1. Use one public parse entry point

The library should expose a single parsing API:

```zig
pub fn parse(
    comptime Schema: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ParseError!Parsed(Schema)

pub fn deinit(
    comptime Schema: type,
    allocator: std.mem.Allocator,
    value: *Parsed(Schema),
) void
```

`parse` is the core API.

- It is easy to test.
- It allows zero-copy string borrowing from the caller-owned `argv`.
- It keeps ownership explicit.
- It avoids mixing argument acquisition with argument parsing.

The allocator is always accepted, even when a particular parse performs no allocation. That keeps the API stable and allows dynamic collections when needed.

### 2. Model every command scope with the same schema struct rules

The root CLI and every subcommand payload should follow the same command-schema rules.

A command schema is a non-tuple `struct` that:

- may declare `pub const meta`
- contains `parsz` schema field types
- may contain at most one `parsz.Subcommand(...)` field

This means the library only needs one schema extractor and one validator for command scopes. The root CLI is simply the top-level command schema, while each subcommand payload is another command schema reached recursively through a subcommand union.

Example:

```zig
const Cli = struct {
    pub const meta = .{
        .name = "demo",
        .version = "0.1.0",
        .about = "Demo application",
    };

    verbose: parsz.Flag(.{
        .short = 'v',
        .help = "Enable verbose output",
    }),

    output: parsz.Option(?[]const u8, .{
        .long = "output",
        .value_name = "PATH",
    }),

    input: parsz.Positional([]const u8, .{
        .help = "Input file",
    }),

    command: parsz.Subcommand(Command),
};

const Command = union(enum) {
    init: struct {
        pub const meta = .{
            .about = "Create a new project",
        };

        bare: parsz.Flag(.{}),
    },
    fmt: struct {
        pub const meta = .{
            .about = "Format input paths",
        };

        check: parsz.Flag(.{}),
        paths: parsz.Positional([]const []const u8, .{}),
    },
};
```

This means:

- `Cli` is the root command schema
- each subcommand payload struct is also a command schema
- `Command` is the subcommand union that selects one command schema payload
- field-level schema lives in `Flag`, `Option`, `Positional`, and `Subcommand`
- command-level metadata lives in `pub const meta`

This is the main reason to prefer wrapper types for schema declarations in this project. The wrappers are public API, but the implementation still depends only on the Zig standard library.

### 3. Separate schema types from parsed value types

The schema type is not the runtime result type. It is a declarative description that `parse` reads at comptime.

`Parsed(Schema)` should derive the runtime value type from the schema:

```zig
const ParsedCli = parsz.Parsed(Cli);
```

Conceptually, this becomes:

```zig
const ParsedCli = struct {
    verbose: bool,
    output: ?[]const u8,
    input: []const u8,
    command: union(enum) {
        init: struct {
            bare: bool,
        },
        fmt: struct {
            check: bool,
            paths: []const []const u8,
        },
    },
};
```

This split gives the best of both approaches:

- the schema stays fully declarative and single-source
- the parsed result is plain data that is pleasant to use
- users do not need to handle wrapper instances after parsing

In practice, most callers will rely on type inference:

```zig
const cli = try parsz.parse(Cli, allocator, argv);
```

`Parsed(Schema)` still matters because it defines the public contract of `parse`, `deinit`, tests, and diagnostics.

### 4. Use command schema structs plus subcommand unions

Each command scope should be represented by a command schema struct. Subcommand choice should be represented by a `union(enum)` wrapped by `parsz.Subcommand(...)`.

This keeps command trees explicit:

- a command schema is a struct
- a subcommand choice is a tagged union
- each subcommand payload is another command schema

`command: parsz.Subcommand(Command)` therefore means: this command schema selects exactly one payload from the `Command` subcommand union.

## Command Metadata Rules

`pub const meta` is container-level metadata for a command schema.

For the MVP:

- the root command schema may define `name`, `version`, and `about`
- subcommand command schemas may define `about`
- subcommand names default from union field names
- subcommands do not define independent `version` values

## Internal Schema Contract

Each public schema field constructor should produce a type that exposes a small compile-time contract through declarations. The exact declaration names can be finalized during implementation, but the schema extractor should be able to read at least:

- the field kind
- the parsed value type
- the field metadata

For example, generated wrapper types may expose declarations equivalent in spirit to:

- `pub const parsz_kind = .flag`
- `pub const Value = bool`
- `pub const meta = ...`

This avoids brittle name-based detection in `schema.zig` and lets validation work entirely through reflection.

## Supported Field Kinds in MVP

The MVP should support these schema field constructors:

- `Flag(meta)`
  - parsed value type: `bool`
  - omitted flag value becomes `false`
- `Option(T, meta)`
  - parsed value type: `T`
  - `T` may be:
    - `bool`
    - integers
    - floats
    - enums
    - `[]const u8`
    - `[:0]const u8`
    - `?U` where `U` is one of the supported scalar/string types
- `Positional(T, meta)`
  - parsed value type: `T`
  - `T` may be:
    - the same scalar/string types as `Option`
    - `[]const U` for repeated positional values, where `U` is a supported scalar/string type
- `Subcommand(T)`
  - `T` must be a tagged union whose payloads are schema structs
  - parsed value type: a recursively transformed tagged union

String slices remain scalar string values. For example:

- `Positional([]const u8, ...)` means one string positional argument
- `Positional([]const []const u8, ...)` means a repeated string positional argument

Recommended MVP exclusions:

- maps
- nested embedded option groups
- custom parsers
- repeated option values
- repeated short-count flags like `-vvv`
- case-insensitive enums

Those can be added after the base architecture is stable.

## Optionality Rules

Optionality should be expressed by the schema field type itself:

- `Flag(...)` is always optional and defaults to `false`
- `Option(?T, ...)` is optional and yields `null` when omitted
- `Positional(?T, ...)` is optional and yields `null` when omitted
- repeated positional fields use slice payloads such as `[]const u32` or `[]const []const u8` and consume zero or more values
- all other `Option(T, ...)` and `Positional(T, ...)` fields are required

This keeps requiredness in one place and avoids a second optionality mechanism.

## Compile-Time Validation Rules

`parse` should trigger `comptime validateSchema(Schema)`.

The validator should reject:

- non-struct CLI roots
- tuple structs
- fields whose types are not `parsz` schema field types
- unsupported `Option` or `Positional` payload types
- duplicate long names inside the same command scope
- duplicate short names inside the same command scope
- positional fields after a variadic positional
- required positional fields after optional positional fields
- more than one subcommand field in the same command struct
- invalid `Subcommand(T)` arguments
- subcommand payloads that are not schema structs
- duplicate subcommand names inside the same command scope
- reserved names like `help` and `version` in MVP

The validator should also normalize:

- long names defaulting from field names when omitted
- subcommand names defaulting from union field names
- value names defaulting from field names transformed to uppercase

Positional order should come from field declaration order. No separate positional index table should exist in the public schema.

All validation failures should use `@compileError` with field-qualified messages so users can fix definitions quickly.

## Runtime Parsing Model

The runtime parser should be a small state machine over `argv[1..]`:

1. Skip `argv[0]`.
2. Track whether `--` has been seen.
3. Before `--`:
   - `--name=value`
   - `--name value`
   - short flags and short options like `-v` / `-o value`
4. After `--`, everything is positional.
5. Positional fields are consumed in schema declaration order.
6. When a subcommand field is reached, match the next token against the compile-time subcommand table and recurse into the chosen payload schema.

For lookup:

- long names and subcommand names should use `std.StaticStringMap(...).initComptime(...)`
- short names can use a compact comptime-built lookup table or a small linear scan

This keeps lookup overhead small and pushes most work into compile time.

## Conversion Rules

Scalar conversion should rely on the standard library where possible:

- integers: `std.fmt.parseInt`
- floats: `std.fmt.parseFloat`
- enums: `std.meta.stringToEnum`
- booleans:
  - `Flag` fields set `true` when present
  - `Option(bool, ...)` and `Positional(bool, ...)` can accept `true` / `false`

String-like values should be borrowed from the caller-provided `argv` in `parse`.

Repeated values should use:

- zero allocation for fixed-size scalar fields
- allocation only when the destination field is a dynamic slice like `[]const T`

## Ownership and Lifetime Model

This is the most important design constraint.

- `[]const u8` and `[:0]const u8` results borrow from the caller-provided `argv`
- repeated dynamic values allocate only their result slice storage
- `deinit` frees only storage allocated by the parser itself
- the caller is responsible for ensuring that `argv` outlives the parsed result

If an application wants to parse process arguments, it should first obtain them with `std.process` and then pass them into `parse`. This keeps the parsing library focused on schema validation, tokenization, and conversion rather than process-level argument ownership.

## Internal Module Layout

Recommended initial file layout:

```text
src/parsz.zig          // public exports
src/field.zig          // Flag/Option/Positional/Subcommand type constructors
src/schema.zig         // comptime schema extraction and validation
src/parsed.zig         // Parsed(Schema) type generation
src/parse.zig          // runtime token parser
src/convert.zig        // token-to-type conversion
src/deinit.zig         // generic cleanup for dynamically allocated fields
src/error.zig          // parse errors and formatting helpers
test/schema_declaration_test.zig  // schema declaration contract tests
```

## Error Model

Separate definition-time errors from runtime parse errors.

Definition-time errors:

- reported with `@compileError`
- include the field path and violated rule

Runtime errors:

- unknown option
- missing option value
- missing required positional
- unexpected argument
- duplicate single-use option
- invalid scalar value
- unknown subcommand

Prefer a small typed error set plus a diagnostic payload struct for formatting.

## Testing Plan

### Runtime tests

- simple flags
- required and optional options
- positional arguments in declaration order
- repeated positional arguments
- subcommands
- enum parsing
- `Parsed(Schema)` shape for representative schemas
- `--` terminator behavior

### Compile-fail tests

Use standalone invalid fixtures compiled by the test harness or build script, because the standard test API is not designed around inline `expectCompileError` checks for whole type definitions.

Fixtures should cover:

- non-wrapper field types
- duplicate names
- unsupported payload types
- invalid subcommand definitions
- illegal positional ordering

## Delivery Order

### Phase 1

- project skeleton
- public schema field types
- `Parsed(Schema)`
- schema extraction
- compile-time validation

### Phase 2

- scalar parsing
- option and positional parsing
- repeated values
- deinit support

### Phase 3

- subcommands
- better diagnostics
- compile-fail fixture tests

### Phase 4

- help/version metadata plumbing
- help/version generation

## Recommendation Summary

Start with:

- public schema field types as the single source of truth
- `Parsed(Schema)` as the runtime value type generator
- `parse` as the only public parsing API
- tagged unions for subcommands
- `@typeInfo` + `@compileError` for validation

This keeps the MVP small, testable, and correct while eliminating schema duplication in public CLI definitions.
