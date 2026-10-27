# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule ComparisonBench do
  @moduledoc """
  Benchee comparison of Picosat (C NIF), the released SimpleSat v0.1.4
  (`SimpleSatV014`, vendored in test/support) and the current SimpleSat.

  Run with `mix bench` (runs under MIX_ENV=test so `SimpleSatV014` is
  compiled). Benchee's detailed statistics are printed per case; a summary
  table per family is printed at the end and written to
  `comparison_bench_results.txt` in the project root.

  `mix bench --quick` is the fast inner loop for optimisation work: picosat vs
  the pre-optimisation DPLL (`SimpleSatDpll`, vendored in test/support) vs the
  staged SimpleSat (git index) vs the working tree, on the small-formula cases
  only. It prints a single table and writes no file.

  Each case is a batch of instances (one for deterministic formulas,
  `@batch_size` seeded instances for random families); a job solves the
  whole batch. Before timing, every solver solves the batch once under a
  `@cap_ms` cap: results are validated against the clauses and the solvers
  must agree on SAT/UNSAT per instance. Solvers that hit the cap are left out
  of that case's Benchee run, since Benchee itself has no timeout.

  Memory is Benchee's measurement of BEAM allocations (including garbage) in
  the benchmarking process. Memory allocated by NIFs is not visible, so the
  Picosat column only covers marshalling the clause lists and is not
  comparable to the pure Elixir solvers.

  Families, in report order (most relevant to web applications first):

    * Tiny formulas — the realistic web-application workload.
    * Trivial unit clauses — input-size scaling on easy instances.
    * Planted 3-coloring — structured "pick one per item, no conflicts" SAT.
    * N-Queens — structured SAT with dense exclusivity constraints.
    * Pigeonhole PHP(h+1, h) — UNSAT, over-constrained choices.
    * Random 3-SAT at the phase transition — synthetic, search-heavy worst case.
  """

  @results_path Path.expand("../comparison_bench_results.txt", __DIR__)
  @cap_ms 5_000
  @batch_size 10
  @phase_transition_ratio 4.26

  @warmup 0.5
  @time 2
  @memory_time 0.5

  # `mix bench --quick` is the inner loop for optimisation experiments: shorter
  # runs, no memory measurement, and only the small-formula band web apps
  # actually hit.
  @quick %{
    warmup: 0.3,
    time: 1,
    memory_time: 0,
    solvers: ["picosat", "dpll", "staged", "simple_sat"],
    cases: [
      "voting (3 vars, 4 clauses)",
      "select one of 5",
      "select one of 20",
      "select one of 50",
      "100 unit clauses",
      "500 unit clauses",
      "V=20 E=40",
      "n=4 vars=16",
      "n=8 vars=64",
      "holes=3 vars=12",
      "holes=4 vars=20",
      "n=20 m=85"
    ]
  }

  @full %{
    warmup: @warmup,
    time: @time,
    memory_time: @memory_time,
    solvers: ["picosat", "simple_sat 0.1.4", "simple_sat"],
    cases: :all
  }

  def run(argv) do
    ensure_optimized_picosat!()

    if "--quick" in argv, do: run_quick(), else: run_full()
  end

  defp run_full do
    results =
      for {title, cases} <- families() do
        {title, Enum.map(cases, &bench_case(title, &1, @full))}
      end

    report = render(results)
    IO.puts(report)
    File.write!(@results_path, report)
  end

  defp run_quick do
    load_staged_solver!()

    results =
      for {title, cases} <- families(),
          {name, _instances} = kase <- cases,
          name in @quick.cases do
        {title, bench_case(title, kase, @quick)}
      end

    IO.puts(render_quick(results))
  end

  defp solvers(%{solvers: names}) do
    all = [
      {"picosat", &Picosat.solve/1},
      {"simple_sat 0.1.4", &SimpleSatV014.solve/1},
      {"dpll", &SimpleSatDpll.solve/1},
      # SimpleSatStaged is compiled at run time, in quick mode only; a run-time
      # capture keeps the full run free of an undefined-module warning.
      {"staged", Function.capture(SimpleSatStaged, :solve, 1)},
      {"simple_sat", &SimpleSat.solve/1}
    ]

    for {name, _solve} = solver <- all, name in names, do: solver
  end

  # Quick mode measures the working-tree solver against the last accepted
  # one, which lives in the git index. Compile `:lib/simple_sat.ex` from the
  # index under another module name so both run in the same Benchee session,
  # which cancels out most machine drift between runs.
  defp load_staged_solver! do
    root = Path.expand("..", __DIR__)

    case System.cmd("git", ["show", ":lib/simple_sat.ex"], cd: root, stderr_to_stdout: true) do
      {source, 0} ->
        source
        |> String.replace("defmodule SimpleSat do", "defmodule SimpleSatStaged do")
        |> Code.compile_string("simple_sat_staged.ex")

      {output, status} ->
        Mix.raise("cannot read staged lib/simple_sat.ex (git exit #{status}): #{output}")
    end
  end

  defp families do
    [
      tiny_formulas(),
      trivial_unit_clauses(),
      planted_graph_coloring(),
      n_queens(),
      pigeonhole_principle(),
      random_3sat_phase_transition()
    ]
  end

  # ----------------------------------------------------------------------
  # Families: {title, [{case name, [instance]}]}
  # ----------------------------------------------------------------------

  defp tiny_formulas do
    {"Tiny formulas (typical web-app constraints)",
     [
       {"voting (3 vars, 4 clauses)", [[[1, 2, -3], [2, 3], [-2], [-1, 3]]]},
       {"select one of 5", [select_one(5)]},
       {"select one of 20", [select_one(20)]},
       {"select one of 50", [select_one(50)]}
     ]}
  end

  defp trivial_unit_clauses do
    {"Trivial unit clauses (no search, pure overhead)",
     for(n <- [100, 500, 1_000], do: {"#{n} unit clauses", [for(v <- 1..n, do: [v])]})}
  end

  defp planted_graph_coloring do
    seed_rng()

    {"Planted graph 3-coloring (satisfiable), #{@batch_size} instances per case",
     for v <- [20, 50, 100] do
       {"V=#{v} E=#{2 * v}", batch(fn -> planted_coloring(v, 2 * v, 3) end)}
     end}
  end

  defp n_queens do
    {"N-Queens (satisfiable)",
     for(n <- [4, 8, 12, 16], do: {"n=#{n} vars=#{n * n}", [queens(n)]})}
  end

  defp pigeonhole_principle do
    {"Pigeonhole PHP(h+1 pigeons, h holes), all UNSAT",
     for(h <- 3..7, do: {"holes=#{h} vars=#{(h + 1) * h}", [pigeonhole(h)]})}
  end

  defp random_3sat_phase_transition do
    seed_rng()

    {"Random 3-SAT, clause/var ratio #{@phase_transition_ratio}, #{@batch_size} instances per case",
     for n_vars <- [20, 40, 60, 80, 100] do
       n_clauses = round(n_vars * @phase_transition_ratio)
       {"n=#{n_vars} m=#{n_clauses}", batch(fn -> random_3sat(n_vars, n_clauses) end)}
     end}
  end

  defp batch(generate), do: for(_ <- 1..@batch_size, do: generate.())

  # ----------------------------------------------------------------------
  # Measurement: capped pre-screen with validation, then Benchee
  # ----------------------------------------------------------------------

  defp bench_case(title, {name, instances}, config) do
    screened =
      for {solver, solve} <- solvers(config), do: {solver, solve, screen(solve, instances)}

    finished = for {solver, _solve, {:ok, results}} <- screened, do: {solver, results}
    verdict = validate!(name, instances, finished)

    jobs =
      for {solver, solve, {:ok, _results}} <- screened, into: %{} do
        {solver, fn instances -> Enum.each(instances, solve) end}
      end

    suite =
      Benchee.run(jobs,
        title: title,
        inputs: [{name, instances}],
        warmup: config.warmup,
        time: config.time,
        memory_time: config.memory_time,
        print: [benchmarking: false, configuration: false, fast_warning: false],
        formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
      )

    measured =
      Map.new(suite.scenarios, fn scenario ->
        {scenario.job_name,
         {scenario.run_time_data.statistics.median, scenario.memory_usage_data.statistics.median}}
      end)

    %{
      name: name,
      verdict: verdict,
      measured: measured,
      system: suite.system
    }
  end

  defp screen(solve, instances) do
    task = Task.async(fn -> Enum.map(instances, solve) end)

    case Task.yield(task, @cap_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, results} -> {:ok, results}
      {:exit, reason} -> raise "solver crashed: #{inspect(reason)}"
      nil -> :timeout
    end
  end

  defp validate!(name, instances, finished) do
    for {solver, results} <- finished,
        {clauses, result} <- Enum.zip(instances, results),
        do: check_result!(solver, name, clauses, result)

    per_solver = for {solver, results} <- finished, do: {solver, Enum.map(results, &sat?/1)}

    case per_solver |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [sat_flags] -> verdict(sat_flags)
      _disagreement -> raise "solvers disagree on #{name}: #{inspect(per_solver)}"
    end
  end

  defp check_result!(_solver, _name, _clauses, {:error, :unsatisfiable}), do: :ok

  defp check_result!(solver, name, clauses, {:ok, solution}) do
    assignment = MapSet.new(solution)

    violated =
      Enum.find(clauses, fn clause -> not Enum.any?(clause, &MapSet.member?(assignment, &1)) end)

    if violated do
      raise "#{solver} solution for #{name} violates clause #{inspect(violated)}"
    end
  end

  defp sat?({:ok, _solution}), do: true
  defp sat?({:error, :unsatisfiable}), do: false

  defp verdict(sat_flags) do
    case Enum.count(sat_flags, & &1) do
      0 -> "UNSAT"
      n when n == length(sat_flags) -> "SAT"
      n -> "#{n}/#{length(sat_flags)} SAT"
    end
  end

  # picosat.c is full of `assert`s, which embed the source file name unless
  # compiled with -DNDEBUG. Picosat's Makefile sets -O3 and -DNDEBUG together,
  # so a NIF without that string is the optimized build.
  defp ensure_optimized_picosat! do
    nif = Path.join(:code.priv_dir(:picosat_elixir), "picosat_nif.so")

    case File.read(nif) do
      {:ok, binary} ->
        if String.contains?(binary, "picosat.c") do
          Mix.raise("""
          picosat NIF is a debug build (asserts compiled in), timings would be skewed.
          Rebuild it optimized with: mix deps.compile picosat_elixir --force
          """)
        end

      {:error, reason} ->
        Mix.raise("cannot read picosat NIF at #{nif}: #{:file.format_error(reason)}")
    end
  end

  # ----------------------------------------------------------------------
  # Instance generators (all deterministic given the seeded RNG)
  # ----------------------------------------------------------------------

  defp seed_rng, do: :rand.seed(:exsss, {1101, 2202, 3303})

  defp select_one(n) do
    at_least_one = [Enum.to_list(1..n)]
    at_most_one = for a <- 1..n, b <- (a + 1)..n//1, do: [-a, -b]
    at_least_one ++ at_most_one
  end

  defp random_3sat(n_vars, n_clauses) do
    for _ <- 1..n_clauses do
      n_vars
      |> distinct_vars(3)
      |> Enum.map(&random_sign/1)
    end
  end

  defp distinct_vars(n_vars, k) do
    Stream.repeatedly(fn -> :rand.uniform(n_vars) end)
    |> Stream.uniq()
    |> Enum.take(k)
  end

  defp random_sign(v), do: if(:rand.uniform(2) == 1, do: v, else: -v)

  defp pigeonhole(holes) do
    pigeons = holes + 1
    var = fn p, j -> (p - 1) * holes + j end

    placement = for p <- 1..pigeons, do: Enum.map(1..holes, &var.(p, &1))

    exclusivity =
      for j <- 1..holes,
          p1 <- 1..pigeons,
          p2 <- (p1 + 1)..pigeons//1,
          do: [-var.(p1, j), -var.(p2, j)]

    placement ++ exclusivity
  end

  defp queens(n) do
    var = fn r, c -> (r - 1) * n + c end
    cells = for r <- 1..n, c <- 1..n, do: {r, c}

    rows_at_least_one = for r <- 1..n, do: Enum.map(1..n, &var.(r, &1))

    conflicts =
      for {r1, c1} <- cells,
          {r2, c2} <- cells,
          {r1, c1} < {r2, c2},
          r1 == r2 or c1 == c2 or abs(r1 - r2) == abs(c1 - c2),
          do: [-var.(r1, c1), -var.(r2, c2)]

    rows_at_least_one ++ conflicts
  end

  defp planted_coloring(n_vertices, n_edges, k) do
    planted = for v <- 1..n_vertices, into: %{}, do: {v, :rand.uniform(k)}
    var = fn v, c -> (v - 1) * k + c end

    edges =
      Stream.repeatedly(fn -> distinct_vars(n_vertices, 2) end)
      |> Stream.map(&Enum.sort/1)
      |> Stream.filter(fn [a, b] -> planted[a] != planted[b] end)
      |> Stream.uniq()
      |> Enum.take(n_edges)

    at_least_one_color = for v <- 1..n_vertices, do: Enum.map(1..k, &var.(v, &1))

    at_most_one_color =
      for v <- 1..n_vertices, c1 <- 1..k, c2 <- (c1 + 1)..k//1, do: [-var.(v, c1), -var.(v, c2)]

    edge_constraints =
      for [a, b] <- edges, c <- 1..k, do: [-var.(a, c), -var.(b, c)]

    at_least_one_color ++ at_most_one_color ++ edge_constraints
  end

  # ----------------------------------------------------------------------
  # Summary report
  # ----------------------------------------------------------------------

  @name_width 28
  @result_width 11
  @cell_width 12
  @time_columns ["picosat", "0.1.4", "current", "vs 0.1.4", "vs picosat"]
  @memory_columns ["picosat*", "0.1.4", "current", "vs 0.1.4"]

  defp render(results) do
    [{_title, [%{system: system} | _]} | _] = results
    Enum.join([header(system) | Enum.map(results, &render_family/1)], "\n")
  end

  defp header(system) do
    jit = if system.jit_enabled?, do: "JIT enabled", else: "JIT disabled"

    """
    Picosat vs SimpleSat v0.1.4 vs SimpleSat (current), Benchee #{Application.spec(:benchee, :vsn)}
      OS / CPU:      #{system.os}, #{system.cpu_speed}, #{system.num_cores} cores, #{system.available_memory}
      Elixir/Erlang: #{system.elixir} / #{system.erlang} (#{jit})
      picosat build: optimized (-O3 -DNDEBUG)
      benchee:       warmup #{@warmup}s, time #{@time}s, memory_time #{@memory_time}s per job; medians shown
      cases:         one batch per row, the job solves all of it; random families use #{@batch_size} seeded instances
      cap:           a solver whose batch takes over #{div(@cap_ms, 1000)}s is skipped ("> #{div(@cap_ms, 1000)}s")
      vs columns:    other solver ÷ current simple_sat; above 1x the current one is faster / allocates less
      memory:        BEAM allocations incl. garbage; Picosat's C memory is invisible, its column (*) is marshalling only
    """
  end

  defp render_family({title, rows}) do
    groups =
      pad("", @name_width + @result_width) <>
        group("time (median)", length(@time_columns)) <>
        group("memory (median)", length(@memory_columns))

    header =
      pad("case", @name_width) <>
        pad("result", @result_width) <>
        Enum.map_join(@time_columns ++ @memory_columns, &pad(&1, @cell_width))

    lines = [
      "== #{title} ==",
      groups,
      header,
      String.duplicate("-", String.length(header)) | Enum.map(rows, &render_row/1)
    ]

    Enum.map_join(lines, "\n", &String.trim_trailing/1) <> "\n"
  end

  defp group(label, n_columns) do
    width = n_columns * @cell_width - 1
    dashes = width - String.length(label) - 2
    left = div(dashes, 2)

    String.duplicate("-", left) <> " #{label} " <> String.duplicate("-", dashes - left) <> " "
  end

  # Compact quick-mode table, one row per case.
  @quick_columns ["picosat", "dpll", "staged", "current", "vs dpll", "vs staged", "vs picosat"]

  defp render_quick(results) do
    header =
      pad("case", @name_width) <>
        pad("result", @result_width) <> Enum.map_join(@quick_columns, &pad(&1, @cell_width))

    lines = [
      "== quick: picosat vs dpll (pre-optimisation) vs staged (index) vs current (working tree); medians ==",
      header,
      String.duplicate("-", String.length(header)) | Enum.map(results, &render_quick_row/1)
    ]

    Enum.map_join(lines, "\n", &String.trim_trailing/1) <> "\n"
  end

  defp render_quick_row({_title, row}) do
    %{name: name, verdict: verdict, measured: measured} = row
    pico = measured["picosat"]
    dpll = measured["dpll"]
    staged = measured["staged"]
    current = measured["simple_sat"]

    cells =
      [time(pico), time(dpll), time(staged), time(current)] ++
        [ratio(dpll, current, 0), ratio(staged, current, 0), ratio(pico, current, 0)]

    pad(name, @name_width) <>
      pad(verdict, @result_width) <> Enum.map_join(cells, &pad(&1, @cell_width))
  end

  defp render_row(%{name: name, verdict: verdict, measured: measured}) do
    [pico, released, current] = Enum.map(solvers(@full), fn {solver, _} -> measured[solver] end)

    cells =
      [time(pico), time(released), time(current)] ++
        [ratio(released, current, 0), ratio(pico, current, 0)] ++
        [memory(pico), memory(released), memory(current), ratio(released, current, 1)]

    pad(name, @name_width) <>
      pad(verdict, @result_width) <> Enum.map_join(cells, &pad(&1, @cell_width))
  end

  defp time(nil), do: "> #{div(@cap_ms, 1000)}s"
  defp time({ns, _bytes}), do: fmt_time(ns)

  defp memory(nil), do: "n/a"
  defp memory({_ns, bytes}), do: fmt_bytes(bytes)

  defp ratio(baseline, current, index) when is_tuple(baseline) and is_tuple(current) do
    fmt_ratio(elem(baseline, index) / max(elem(current, index), 1))
  end

  defp ratio(_baseline, _current, _index), do: "n/a"

  defp fmt_ratio(ratio) when ratio < 0.1, do: "#{Float.round(ratio, 3)}x"
  defp fmt_ratio(ratio) when ratio < 1, do: "#{Float.round(ratio, 2)}x"
  defp fmt_ratio(ratio), do: "#{Float.round(ratio, 1)}x"

  defp fmt_time(ns) when ns < 1_000, do: "#{round(ns)}ns"
  defp fmt_time(ns) when ns < 1_000_000, do: "#{Float.round(ns / 1_000, 1)}µs"
  defp fmt_time(ns) when ns < 1_000_000_000, do: "#{Float.round(ns / 1_000_000, 2)}ms"
  defp fmt_time(ns), do: "#{Float.round(ns / 1_000_000_000, 2)}s"

  defp fmt_bytes(bytes) when bytes < 1_024, do: "#{round(bytes)}B"
  defp fmt_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)}KB"
  defp fmt_bytes(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)}MB"
  defp fmt_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)}GB"

  # Always leaves at least one space, so overlong values never run together.
  defp pad(string, width), do: String.pad_trailing(string, width - 1) <> " "
end

ComparisonBench.run(System.argv())
