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

A simple, dependency free boolean satisfiability solver.

See the [documentation](https://hexdocs.pm/simple_sat) for more.

## Benchmark branch

This is the `sat_bench` branch. It ships the released solver plus three
candidates (`SimpleSat.DPLL`, `SimpleSat.DPLLOptimized`, `SimpleSat.CDCL`)
and a `mix sat.bench` task that records every formula your test suite hands
the SAT solver and times each solver on exactly those formulas. To try it in
an Ash app, swap the dependency for the branch and run the task in the test
environment:

```elixir
{:simple_sat, github: "KasparKipp/simple_sat", branch: "sat_bench", override: true},
# Also bench against optimised picosat
{:picosat_elixir, "~> 0.2", env: :prod},
```

```sh
rm -rf _build/test
MIX_ENV=test mix deps.get
MIX_ENV=test mix sat.bench
```

`MIX_ENV=test mix help sat.bench` has the details. Everything below is the regular README.

## Installation

```elixir
def deps do
  [
    {:simple_sat, "~> 0.1.4"}
  ]
end
```
