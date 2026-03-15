# Code Review Notes

## Scope

This review covered:

- All files under `src/`
- `build.zig`
- `build.zig.zon`

No blocking issues were found in `build.zig` or `build.zig.zon`.

## Findings

### 1. High: `help()` and `usage()` do not validate subcommand payloads as deeply as `parse()`

#### What happens

The public APIs do not agree on which CLI definitions are considered valid.

- `parse()` computes the subcommand field and enters recursive parsing for each subcommand payload.
- `help()` and `usage()` validate the top-level type, then call `validateSubcommandConfig()`.
- `validateSubcommandConfig()` only descends into a variant payload when that variant appears inside the config struct.

This means a malformed subcommand payload can be accepted by `help()` or `usage()` while the same CLI definition fails when `parse()` is instantiated.

#### Why it happens

The parse path and the help/usage path do not share the same recursive validation rules.

- `parse()` passes `cmd_spec.subcommand_field` into the parser.
- The parser then expands recursive `parseCore(sf.type, ...)` calls for subcommand variants.
- `help()` and `usage()` stop at top-level validation unless variant-specific config is present.

#### Impact

This creates an API inconsistency:

- The user can successfully generate help text for a CLI definition that is not actually parseable.
- Validation failures move from a predictable compile-time boundary to whichever public API happens to be used first.
- Bugs inside subcommand payloads are easier to miss because help generation can appear healthy.

#### Recommendation

Make `help()` and `usage()` validate subcommand payload types unconditionally, even when the user provides no variant-specific config.

One practical fix is to extend `validateSubcommandConfig()` so it always walks every variant payload and calls `validate()` recursively with either the variant config or `.{}` when the variant has no explicit config entry.

#### Evidence

- `src/parsz.zig:66-90`
- `src/validator.zig:346-417`
- `src/parser.zig:168-180`
- `src/parser.zig:261-287`

### 2. Medium: `.positional = true` on `bool` is accepted but cannot work

#### What happens

A `bool` field can be configured as positional without a compile-time error, but it will never be treated as a positional argument.

Instead:

- `argKind()` classifies `bool` as `.flag` before it considers `.positional`.
- The positional dispatcher skips the field because it is not seen as positional.
- A user-provided positional token eventually falls through as `TooManyPositionals`.

#### Why it happens

The field classification order makes `bool` special before config is fully considered, and the validator does not reject the invalid combination.

#### Impact

This is a bad user experience:

- The config looks valid.
- Help/usage will describe the field as an option/flag rather than a positional argument.
- The real failure is deferred until runtime, where it appears as a positional parsing error instead of a targeted configuration error.

#### Recommendation

Reject `bool + .positional = true` during validation.

If positional booleans are intentionally unsupported, the validator should emit a compile-time error with a message that clearly explains the limitation.

#### Evidence

- `src/spec/arg.zig:11-19`
- `src/validator.zig:254-267`
- `src/parser.zig:702-749`

### 3. Medium: `parser.parseArgs()` silently disables subcommand support

#### What happens

`parser.parseArgs()` calls `parseCore()` with `subcmd_field_name = null`, which bypasses the subcommand path entirely.

The exported wrapper in `parsz.zig` does not do this. It computes the subcommand field and passes it into `parseCore()`.

#### Why it happens

`parser.parseArgs()` is implemented as a convenience wrapper, but it hardcodes the parser into non-subcommand mode.

#### Impact

There are two concrete problems:

- Importing `src/parser.zig` directly gives different behavior from importing the public `parsz` API.
- The unit tests inside `src/parser.zig` use this helper extensively, so they do not directly exercise the subcommand branch in the file that contains that logic.

Even though `src/parsz.zig` has broader coverage, this still weakens the local test signal around the most complex control flow in `src/parser.zig`.

#### Recommendation

Either:

- make `parser.parseArgs()` compute and pass the subcommand field exactly like `parsz.parse()`, or
- stop exposing it as a `pub` function if it is only intended for non-subcommand internal use.

#### Evidence

- `src/parser.zig:159-165`
- `src/parsz.zig:38-48`
- `src/parser.zig:936-1331`

## Validation

- `zig build test` initially failed inside the sandbox because the comptime test step could not read Zig stdlib files from `/nix/store/.../std.zig` (`PermissionDenied`).
- The same command was rerun outside the sandbox and completed successfully.

This means the observed sandbox failure was environmental, not a repository defect.

## Source Material

Primary repository sources used for this review:

- `build.zig`
- `build.zig.zon`
- `src/parsz.zig`
- `src/parser.zig`
- `src/tokenizer.zig`
- `src/errors.zig`
- `src/validator.zig`
- `src/spec/arg.zig`
- `src/spec/command.zig`
- `src/spec/constraint.zig`
- `src/constraint/engine.zig`
- `src/help/usage.zig`
- `src/help/render.zig`

Validation command used:

- `zig build test`
