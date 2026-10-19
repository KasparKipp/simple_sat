# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.Bench do
  @moduledoc false
  # Times every available solver on a recording made by `SimpleSat.Bench.Recorder`
  # and renders the comparison. Driven by `mix sat.bench`; see that task's docs.

  alias SimpleSat.Bench.{Error, Recording, Report}

  @solvers [
    {"Picosat", Picosat},
    {"SimpleSat", SimpleSat},
    {"SimpleSat.DPLL", SimpleSat.DPLL},
    {"SimpleSat.DPLLOptimized", SimpleSat.DPLLOptimized},
    {"SimpleSat.CDCL", SimpleSat.CDCL}
  ]
  @min_samples 5
  @default_seconds 3.0
  @default_timeout 5.0

  @type solver :: {String.t(), module()}
  @type samples :: [float()]

  @doc """
  Loads the recording, checks that every solver agrees on it, times the
  solvers, and writes the report to `sat_bench/report.txt`.

  Options:

    * `:seconds` - time spent per solver on the whole workload, and again in
      total on timing every solver on every distinct formula (default 3.0)
    * `:timeout` - seconds a solver may spend on one formula before it is
      dropped from the comparison (default 5.0)
    * `:log` - progress callback, `fn message -> any end` (default `IO.puts/1`)
    * `:app` - name shown in the report header (default: the current directory)
  """
  @spec run(keyword()) :: String.t()
  def run(opts \\ []) do
    seconds = Keyword.get(opts, :seconds, @default_seconds)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    log = Keyword.get(opts, :log, &IO.puts/1)
    app = Keyword.get(opts, :app, Path.basename(File.cwd!()))

    {calls, formulas} = Recording.load()
    candidates = available_solvers()

    log.(
      "sat_bench: checking #{map_size(formulas)} formulas against #{length(candidates)} solvers"
    )

    {solvers, gave_up} = check_agreement!(formulas, candidates, round(timeout * 1_000))
    Enum.each(gave_up, fn {name, hash} -> log.("sat_bench: #{name} gave up on #{hash}") end)

    workload = Enum.map(calls, &Map.fetch!(formulas, &1))

    whole =
      for {name, solver} <- solvers do
        log.("sat_bench: timing #{name}")
        {name, samples(fn -> Enum.each(workload, &solver.solve/1) end, seconds)}
      end

    log.("sat_bench: timing every solver on each of the #{map_size(formulas)} formulas")
    per_formula = time_each_formula(formulas, solvers, seconds)

    report =
      Report.render(%{
        app: app,
        calls: calls,
        formulas: formulas,
        whole: whole,
        per_formula: per_formula,
        gave_up: gave_up,
        timeout: timeout
      })

    File.write!(Recording.report_path(), report)
    report
  end

  @spec available_solvers() :: [solver()]
  defp available_solvers do
    case for({name, solver} <- @solvers, Code.ensure_loaded?(solver), do: {name, solver}) do
      [] -> raise Error, message: "sat_bench: no SAT solver available to time"
      solvers -> solvers
    end
  end

  # Times every solver on every distinct formula, splitting `seconds` evenly
  # over the solver/formula pairs (each still gets at least @min_samples runs).
  @spec time_each_formula(%{Recording.hash() => Recording.cnf()}, [solver()], number()) ::
          [{Recording.hash(), Recording.cnf(), [{String.t(), samples()}]}]
  defp time_each_formula(formulas, solvers, seconds) do
    budget = seconds / max(map_size(formulas) * length(solvers), 1)

    for {hash, cnf} <- formulas do
      per_solver =
        for {name, solver} <- solvers, do: {name, samples(fn -> solver.solve(cnf) end, budget)}

      {hash, cnf, per_solver}
    end
  end

  # Every solver must agree on satisfiability, and every model must satisfy
  # its formula; otherwise the timings compare wrong answers. The solvers run
  # concurrently per formula; one that exceeds the timeout on any formula is
  # dropped from the comparison (and reported) instead of stalling the bench.
  @spec check_agreement!(%{Recording.hash() => Recording.cnf()}, [solver()], pos_integer()) ::
          {[solver()], [{String.t(), Recording.hash()}]}
  defp check_agreement!(formulas, solvers, timeout_ms) do
    {solvers, gave_up} =
      Enum.reduce(formulas, {solvers, []}, fn {hash, cnf}, {solvers, gave_up} ->
        {results, timed_out} = solve_all(solvers, cnf, timeout_ms)

        case problems(cnf, results) do
          [] ->
            :ok

          problems ->
            raise Error,
              message:
                "sat_bench: formula #{hash} in #{Recording.formulas_path()}: " <>
                  Enum.join(problems, "; ")
        end

        {Enum.reject(solvers, fn {name, _module} -> name in timed_out end),
         Enum.map(timed_out, &{&1, hash}) ++ gave_up}
      end)

    if solvers == [] do
      raise Error,
        message:
          "sat_bench: every solver exceeded the timeout on some formula: #{inspect(gave_up)}"
    end

    {solvers, Enum.reverse(gave_up)}
  end

  # Runs each solver on `cnf` in its own task. Returns the results of the
  # solvers that finished in time, and the names of those that did not.
  @spec solve_all([solver()], Recording.cnf(), pos_integer()) ::
          {[{String.t(), term()}], [String.t()]}
  defp solve_all(solvers, cnf, timeout_ms) do
    tasks =
      for {name, solver} <- solvers, do: {name, Task.async(fn -> solve_safely(solver, cnf) end)}

    outcomes =
      tasks
      |> Enum.map(&elem(&1, 1))
      |> Task.yield_many(timeout: timeout_ms, on_timeout: :kill_task)
      |> Enum.zip(tasks)

    results = for {{_, {:ok, result}}, {name, _task}} <- outcomes, do: {name, result}
    timed_out = for {{_, nil}, {name, _task}} <- outcomes, do: name
    {results, timed_out}
  end

  defp solve_safely(solver, cnf) do
    solver.solve(cnf)
  rescue
    exception -> {:raised, Exception.message(exception)}
  end

  @spec problems(Recording.cnf(), [{String.t(), term()}]) :: [String.t()]
  defp problems(cnf, results) do
    raised = for {name, {:raised, message}} <- results, do: "#{name} raised: #{message}"

    wrong_models =
      for {name, {:ok, model}} <- results,
          not satisfies?(cnf, model),
          do: "#{name} returned a model that doesn't satisfy it"

    outcomes = results |> Enum.map(fn {_name, result} -> elem(result, 0) end) |> Enum.uniq()

    disagree =
      if length(outcomes) > 1, do: ["solvers disagree: #{inspect(results)}"], else: []

    raised ++ wrong_models ++ disagree
  end

  @spec satisfies?(Recording.cnf(), [integer()]) :: boolean()
  defp satisfies?(cnf, model) do
    true_literals = MapSet.new(model)
    Enum.all?(cnf, fn clause -> Enum.any?(clause, &MapSet.member?(true_literals, &1)) end)
  end

  # Warms up for a tenth of the time, then runs `fun` for `seconds` (and at
  # least @min_samples times). Returns sorted durations in microseconds.
  @spec samples((-> term()), number()) :: samples()
  defp samples(fun, seconds) do
    _warmup = collect(fun, deadline(seconds / 10), 0, [])
    collect(fun, deadline(seconds), 0, [])
  end

  @spec collect((-> term()), integer(), non_neg_integer(), samples()) :: samples()
  defp collect(fun, deadline, count, acc) do
    started = System.monotonic_time()
    fun.()
    elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :nanosecond)
    acc = [elapsed / 1_000 | acc]

    if count + 1 >= @min_samples and System.monotonic_time() >= deadline,
      do: Enum.sort(acc),
      else: collect(fun, deadline, count + 1, acc)
  end

  @spec deadline(number()) :: integer()
  defp deadline(seconds) do
    System.monotonic_time() +
      System.convert_time_unit(round(seconds * 1_000), :millisecond, :native)
  end
end
