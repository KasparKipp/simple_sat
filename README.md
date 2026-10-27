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

Benchmarking branch for [simple_sat PR #28](https://github.com/ash-project/simple_sat/pull/28) built on top of the DPLL rewrite (`feat_performance_refactor`).

Using [Benchee](https://benchee.hexdocs.pm) comparing three solvers:

| Solver | What it is |
| ------ | ---------- |
| [picosat](https://picosat-elixir.hexdocs.pm/) | `picosat_elixir`, a C NIF running a CDCL solver (clause learning, non-chronological backtracking) |
| [simple_sat 0.1.4](https://simple-sat.hexdocs.pm/0.1.4) | The last released SimpleSat, vendored into `test/support/simple_sat_v014.ex` as `SimpleSatV014` |
| `simple_sat` | `lib/simple_sat.ex` from branch `feat_performance_refactor`: the DPLL rewrite plus its `perf:` commits |

### Running it

```sh
mix deps.get
mix bench          # full comparison, writes ./comparison_bench_results.txt
mix bench --quick  # picosat vs staged (git index) vs working tree on the small cases, ~35 s
```

`--quick` is the inner loop for optimisation work. It runs picosat, the
pre-optimisation DPLL (`SimpleSatDpll`, vendored in `test/support` from
revision `d4c18c8`), the staged `lib/simple_sat.ex` compiled from the git index,
and the working tree in one Benchee session, so a change is always measured
against both the last accepted version and the starting point.

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
| voting (3 vars, 4 clauses) | 2.5µs   | 792ns    | 333ns    | 2.4x faster      | 7.5x faster        |
| select one of 20           | 21.2µs  | 405.6µs  | 8.1µs    | 50x faster       | 2.6x faster        |
| select one of 50           | 93.0µs  | 5.91ms   | 51.2µs   | 115x faster      | 1.8x faster        |
| 100 unit clauses           | 11.3µs  | 495.0µs  | 3.7µs    | 134x faster      | 3.0x faster        |
| 1000 unit clauses          | 69.0µs  | 58.11ms  | 116.3µs  | 500x faster      | 1.7x slower        |
| N-Queens n=8               | 90.5µs  | 71.36ms  | 235.0µs  | 304x faster      | 2.6x slower        |
| N-Queens n=12              | 261.7µs | 1.02s    | 1.65ms   | 615x faster      | 6.3x slower        |
| pigeonhole holes=4 (UNSAT) | 22.3µs  | 112.63ms | 45.7µs   | 2464x faster     | 2.0x slower        |
| pigeonhole holes=5 (UNSAT) | 100.3µs | 3.29s    | 454.3µs  | 7232x faster     | 4.5x slower        |
| random 3-SAT n=20 (×10)    | 163.0µs | 949.37ms | 312.9µs  | 3034x faster     | 1.9x slower        |
| random 3-SAT n=100 (×10)   | 8.5ms   | > 5s     | 941.15ms | n/a              | 111x slower        |

#### Claude Summary for results

What the numbers show:

- **Tiny and small formulas (up to ~50 variables, the web-app band):** the
  current SimpleSat is faster than picosat on every row: 7.5x on the voting
  formula, 2.6x on select-one-of-20, 1.8x on select-one-of-50, 2.0x on queens 4
  and 1.6x on pigeonhole 3. Picosat pays a fixed ~3.5µs per call for marshalling and
  solver setup that the Elixir solver never does, and the solver itself is now
  cheap enough to stay ahead until roughly 50-60 variables.
- **Against the first DPLL version (commit `dpll impl`):** the `perf:` commits
  on `feat_performance_refactor` gained 2.7x on the tiny rows, 5-8x on
  select-one, 3x on 1000 unit clauses, 5x on queens 8 and 3-SAT n=20, and cut
  allocations 2-8x. The big levers were one fused pass per search step instead
  of three Enum passes, integer comparison instead of MapSet hashing, and
  trying the positive polarity first (select-one-of-50 went from 49 decisions
  to 1).
- **Tuple-indexed assignment:** the assignment map became a tuple indexed by variable when the
  largest variable is at most 256, with the map kept above that. Measured
  against the map version in the same session: 2x on 100 unit clauses, 1.4x
  on coloring V=20, 1.2-1.8x on queens 8-16 and pigeonhole 4-6, 1.6x on
  3-SAT n=100. Formulas of 1-10 clauses pay 5-18 ns for the extra max-variable
  pass and tuple allocation, 2-7% of their 50-250 ns.
- **Against 0.1.4:** faster on every case, from 2.7x to over 4000x, and 0.1.4
  still hits the 5 s cap on 9 of the 24 cases; the current solver hits it on
  none.
- **Larger formulas:** the gap to picosat grows with search depth, from 2-6x
  on 64-144 variable structured instances to ~110x on 100-variable random
  3-SAT. That is the cost of plain DPLL without clause learning, and it is out
  of scope here: a separate CDCL experiment showed no benefit on small formulas.
