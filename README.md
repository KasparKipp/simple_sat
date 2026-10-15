<!--
SPDX-FileCopyrightText: 2020 Zach Daniel
SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs.contributors>

SPDX-License-Identifier: MIT
-->
![Elixir CI](https://github.com/ash-project/simple_sat/workflows/CI/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Hex version badge](https://img.shields.io/hexpm/v/simple_sat.svg)](https://hex.pm/packages/simple_sat)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/simple_sat)
[![REUSE status](https://api.reuse.software/badge/github.com/ash-project/simple_sat)](https://api.reuse.software/info/github.com/ash-project/simple_sat)


# SimpleSat

Benchmarking branch for [PR #TODO](TODO) built on top of the DPLL rewrite (`feat_performance_refactor`).

Using [Benchee](https://benchee.hexdocs.pm) comparing three solvers:

| Solver | What it is |
| ------ | ---------- |
| [picosat](https://picosat-elixir.hexdocs.pm/) | `picosat_elixir`, a C NIF running a CDCL solver (clause learning, non-chronological backtracking) |
| [simple_sat 0.1.4](https://simple-sat.hexdocs.pm/0.1.4) | The last released SimpleSat, vendored into `test/support/simple_sat_v014.ex` as `SimpleSatV014` |
| `simple_sat` | `lib/simple_sat.ex` from branch `feat_performance_refactor` |

### Running it

```sh
mix deps.get
mix bench
```

Output is written to `./comparison_bench_results.txt`

### How it measures

- **Families of formulas**, ordered from most to least relevant to web apps:
  tiny formulas (the typical web-app workload), trivial unit clauses
  (input-size overhead), planted 3-coloring, N-Queens, pigeonhole (UNSAT), and
  random 3-SAT at the 4.26 clause/variable phase transition (synthetic worst
  case).
- **Batches:** each row is one batch, and a job solves the whole batch. Random
  families use 10 instances generated from a fixed seed, so every run sees the
  same formulas.
- **Validation:** before timing, each solver solves the batch once. Every
  solution is checked against its clauses, and all solvers must agree on
  SAT/UNSAT for each instance, or the bench raises.
- **5 s cap:** Benchee has no timeout, so a solver whose validation pass takes
  over 5 s is left out of that case's timing and shows as `> 5s`.
- **Benchee settings:** 0.5 s warmup, 2 s time and 0.5 s memory_time per job.
  The summary shows medians.
- **Memory** is Benchee's count of BEAM allocations, including garbage. Memory
  allocated inside a NIF is invisible to it, so the `picosat*` column only
  covers marshalling the clause lists and can't be compared with the Elixir
  solvers.

### Results run on an Apple M3 Max with Elixir 1.20.4 / OTP 29.1.1

Full output is in [comparison_bench_results.txt](./comparison_bench_results.txt).

| Case                       | picosat | 0.1.4    | current | current vs 0.1.4 | current vs picosat |
| -------------------------- | ------- | -------- | ------- | ---------------- | ------------------ |
| voting (3 vars, 4 clauses) | 3.5µs   | 833ns    | 792ns   | 1.1x faster      | 4.5x faster        |
| select one of 20           | 24.2µs  | 335.5µs  | 72.5µs  | 4.6x faster      | 3x slower          |
| 1000 unit clauses          | 93.8µs  | 57.35ms  | 372.5µs | 154x faster      | 4x slower          |
| N-Queens n=12              | 293.7µs | 828.36ms | 8.28ms  | 100x faster      | 28x slower         |
| pigeonhole holes=5 (UNSAT) | 108.8µs | 3.28s    | 1.73ms  | 1897x faster     | 16x slower         |
| random 3-SAT n=20 (×10)    | 205.1µs | 956.17ms | 851.6µs | 1123x faster     | 4x slower          |
| random 3-SAT n=100 (×10)   | 8.61ms  | > 5s     | 3.18s   | n/a              | 370x slower        |


#### Claude Summary for results

What the numbers show:

- **Tiny formulas:** the current SimpleSat beats picosat, because a few clauses
  solve faster in Elixir than picosat's fixed per-call cost (marshalling the
  clauses, setting up the solver). By 16–20 variables picosat is level or
  ahead.
- **Against 0.1.4:** the current solver is faster in every case, from 1.1x on
  the smallest formula to three orders of magnitude on search-heavy ones, and
  allocates up to ~1000x less. 0.1.4 hits the 5 s cap on 9 of the 23 cases;
  the current solver hits it on none.
- **Against picosat on larger formulas:** the gap grows with search difficulty,
  from a few times slower on easy structured instances to ~370x slower on
  100-variable random 3-SAT. That is the cost of having no clause learning.