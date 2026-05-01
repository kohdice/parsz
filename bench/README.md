# Parser Benchmarks

This directory contains local parser benchmarks for `parsz`.

## Running

```sh
zig build bench
```

The benchmark executable is built with `ReleaseFast` by default. To choose a
different optimization mode:

```sh
zig build bench -Dbench-optimize=ReleaseSmall
```

To override the iteration count, pass one positional argument after `--`:

```sh
zig build bench -- 1000000
```

## Latest Local Score

Scores are machine-dependent and should be used as a local baseline, not as a
portable pass/fail threshold.

- Date: 2026-05-01
- Platform: Darwin 25.4.0 arm64
- Zig: 0.16.0
- Optimize: ReleaseFast
- Iterations: 100000

| Benchmark                 | Total ns | ns/iter | Peak bytes |
| ------------------------- | -------: | ------: | ---------: |
| basic options and operand |  2833208 |      28 |          0 |
| gnu-style permutation     |  2910625 |      29 |          0 |
| append options            |  5611458 |      56 |         64 |
| subcommand                |  1423875 |      14 |          0 |
