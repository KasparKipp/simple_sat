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
| voting (3 vars, 4 clauses) | 2.4µs   | 791ns    | 292ns   | 2.7x faster      | 8.1x faster        |
| select one of 20           | 19.9µs  | 345.6µs  | 7.7µs   | 45x faster       | 2.6x faster        |
| select one of 50           | 87.8µs  | 5.83ms   | 50.2µs  | 116x faster      | 1.7x faster        |
| 100 unit clauses           | 10.7µs  | 486.2µs  | 3.7µs   | 131x faster      | 2.9x faster        |
| 1000 unit clauses          | 66.2µs  | 57.8ms   | 119.6µs | 483x faster      | 1.8x slower        |
| N-Queens n=8               | 88.3µs  | 71.41ms  | 236.1µs | 302x faster      | 2.7x slower        |
| N-Queens n=12              | 268.7µs | 1.02s    | 1.16ms  | 879x faster      | 4.3x slower        |
| pigeonhole holes=4 (UNSAT) | 21.8µs  | 113.74ms | 44.2µs  | 2570x faster     | 2.0x slower        |
| pigeonhole holes=5 (UNSAT) | 99.5µs  | 3.28s    | 455.5µs | 7205x faster     | 4.6x slower        |
| random 3-SAT n=20 (×10)    | 163.7µs | 989.27ms | 320.8µs | 3084x faster     | 2.0x slower        |
| random 3-SAT n=100 (×10)   | 8.75ms  | > 5s     | 1.32s   | n/a              | 151x slower        |

#### Claude Summary for results

What the numbers show:

- **Tiny and small formulas (up to ~50 variables, the web-app band):** the
  current SimpleSat is faster than picosat on every row: 8.1x on the voting
  formula, 2.6x on select-one-of-20, 1.7x on select-one-of-50, 2.0x on queens 4
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
  on coloring V=20, 1.2-1.8x on queens 8-16 and pigeonhole 4-6. Formulas of
  1-10 clauses pay 5-18 ns for the extra max-variable
  pass and tuple allocation, 2-7% of their 50-250 ns.
- **Against 0.1.4:** faster on every case, from 2.7x to over 4000x, and 0.1.4
  still hits the 5 s cap on 9 of the 24 cases; the current solver hits it on
  none.
- **Larger formulas:** the gap to picosat grows with search depth, from 2-5x
  on 64-144 variable structured instances to ~150x on 100-variable random
  3-SAT. That is the cost of plain DPLL without clause learning, and it is out
  of scope here: a separate CDCL experiment showed no benefit on small formulas.
