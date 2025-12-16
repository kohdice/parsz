# AGENTS.md

This file provides guidance to AI agents and agentic coding tools when working with code in this repository.

## Project Overview

parsz is a command-line argument parser library using only the Zig standard library. It adopts a 3-stage pipeline design based on compiler theory.

## Build and Test

```bash
# Run tests
zig build test

# Fuzz testing (crash resistance verification)
zig build test --fuzz
```

## Architecture

### Pipeline Structure

```
argv[] → Tokenizer → Token[] → Parser → RawResult → Validator → ParseResult
                                ↑                      ↑
                          CommandDef            CommandDef + constraints
```

### Core Components

1. **Definition Layer** (`CommandDef`, `ArgDef`): Declarative CLI specification
2. **Tokenizer**: Converts argv to Token array (lexical analysis)
3. **Parser**: Generates RawResult from Token array (syntax analysis)
4. **Validator**: Type conversion and constraint checking (semantic analysis)
5. **API Layer**: Builder API (procedural), Spec API (compile-time reflection)

### File Structure

- `src/parsz.zig`: Main module

## Coding Conventions

### Memory Management

- All functions explicitly receive an Allocator
- Use `defer` / `errdefer` to separate cleanup for success/failure paths
- Guarantee reliable memory cleanup on errors

### Error Design

- `ParseError` holds diagnostic information (structured data)
- Display is handled by a separate rendering layer
- Report multiple errors at once when possible

### Testing Strategy

- Unit tests: Concrete examples and edge cases
- Property-based tests: Use `std.testing.fuzz`
- Each property test should include a comment referencing the design document property number:
  ```zig
  // **Feature: zig-cli-parser, Property 1: Command definition validation**
  ```

## References

- Zig 0.15.2 Documentation: https://ziglang.org/documentation/0.15.2/
- POSIX Utility Syntax Guidelines: https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap12.html
