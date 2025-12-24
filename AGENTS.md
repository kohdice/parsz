# AGENTS.md

This file provides guidance to AI agents and agentic coding tools when working with code in this repository.

## Project Overview

parsz is a command-line argument parser library using only the Zig standard library. It adopts a 3-stage pipeline design based on compiler theory (v1 targets single commands only, no subcommands).

## Build Commands

```bash
zig build test          # Run tests
zig build test --fuzz   # Fuzz testing (crash resistance)
zig build examples      # Build examples
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

## References

- Zig 0.15.2 Documentation: https://ziglang.org/documentation/0.15.2/
- POSIX Utility Syntax Guidelines: https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html
