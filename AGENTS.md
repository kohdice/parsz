# AGENTS.md

This file provides guidance to AI agents and agentic coding tools when working with code in this repository.

## Project Overview

parsz is a command-line argument parser library using only the Zig standard library. It adopts a 3-stage pipeline design based on compiler theory (v1 targets single commands only, no subcommands).

## Build Commands

```bash
zig build test          # Run library tests (src/parsz.zig)
zig build test-comptime # Run comptime validation error tests
zig build test --fuzz   # Fuzz testing (crash resistance)
zig build examples      # Build examples to zig-out/bin/
zig fmt --check .       # Format check (CI runs this)
```

## Architecture

```
argv[] → Tokenizer → Token[] → Parser → RawResult → Validator → ParseResult
                                ↑                      ↑
                          Command            Command + constraints
```

This 3-stage pipeline mirrors compiler design:
- **Tokenizer**: Lexical analysis (argv to Token array)
- **Parser**: Syntax analysis (Token array to RawResult)
- **Validator**: Semantic analysis (type conversion, constraint checking)

### Module Structure

```
src/
  parsz.zig       # Public API entry point (re-exports definitions/errors)
  definitions.zig # Arg, Command, validateArg/validateCommand (comptime)
  errors.zig      # ParseError (runtime error set)
```

### Arg Kind Constraints (enforced at comptime)

| Constraint           | flag | option | positional |
|---------------------|------|--------|------------|
| value_type=boolean  | ✓ required | optional | optional |
| short/long          | ✓ at least one | ✓ at least one | ✗ forbidden |
| required            | ✗ forbidden | optional | optional |
| default             | ✗ forbidden | optional | optional |
| multiple            | ✗ forbidden | optional | optional |

Additional cross-field rules:
- `required` and `default` cannot both be set
- `multiple` cannot have `default`
- Positional after `multiple` positional is forbidden

## Coding Conventions

### Memory Management

- All functions explicitly receive an Allocator
- Use `defer` / `errdefer` to separate cleanup for success/failure paths

### Testing

- Property-based tests use `std.testing.fuzz`
- Reference design doc properties in test comments:
  ```zig
  // **Feature: zig-cli-parser, Property 1: Command definition validation**
  ```

### Adding Comptime Error Tests

1. Create `test/comptime/<test_name>.zig` with code that should fail to compile
2. Register in `build.zig` under `error_tests` with the expected error substring:
   ```zig
   .{ "test/comptime/<test_name>.zig", "expected error message substring" },
   ```

## References

- Zig 0.15.2 Documentation: https://ziglang.org/documentation/0.15.2/
- POSIX Utility Syntax Guidelines: https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html
