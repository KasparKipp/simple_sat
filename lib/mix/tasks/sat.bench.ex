# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.Sat.Bench do
  @shortdoc "Times every SAT solver on the formulas your test suite actually solves"

  @moduledoc """
  Which SAT solver is fastest for this app's formulas?

  Records every formula the app hands its SAT solver while the test suite runs,
  then times each solver this branch ships (Picosat if present, SimpleSat,
  SimpleSat.DPLL, SimpleSat.DPLLOptimized, SimpleSat.CDCL) on exactly those
  formulas, call for call. Recording uses the BEAM call tracer, so the app needs
  no config change and nothing is recompiled.

  ## Setup

  Point the dependency at this branch. `override: true` is needed because Ash
  declares `simple_sat` as an optional Hex dependency.

      {:simple_sat, github: "KasparKipp/simple_sat", branch: "sat_bench", override: true}

  ## Usage

  Recording runs `mix test`, so the task needs the test environment. Remaining
  arguments are passed to `mix test`. Failing tests don't stop the timing.

      MIX_ENV=test mix sat.bench                      # record from the whole suite, then time
      MIX_ENV=test mix sat.bench test/my_app/accounts # record from some tests only
      MIX_ENV=test mix sat.bench --retime             # time the last recording again

  ## Options

    * `--retime` - skip the tests and time the recording from the last run
    * `--time SECONDS` - time spent per solver on the whole workload (default 3)
    * `--timeout SECONDS` - a solver that takes longer than this on a single
      formula is dropped from the comparison and listed in the report (default 5)

  ## What gets traced

  With Ash 3 (which solves through `Crux.Implementation.solve_expression/1`),
  that one function. Otherwise `Picosat.solve/1` and `SimpleSat.solve/1`.

  ## Output

  Recordings and the report go to `sat_bench/` in the project root (add it to
  `.gitignore`). Before timing, every solver is run on every distinct formula;
  the task fails if they disagree or return a model that doesn't satisfy it.
  """

  use Mix.Task

  alias SimpleSat.Bench
  alias SimpleSat.Bench.{Error, Recorder, Recording}

  @default_seconds 3.0
  @default_timeout 5.0

  @impl Mix.Task
  def run(args) do
    defaults = %{retime: false, seconds: @default_seconds, timeout: @default_timeout}
    {opts, test_args} = split_args(args, defaults, [])

    # Modules must be loaded before trace patterns are set, and compiling here
    # keeps `mix test` from recompiling (and purging) them afterwards.
    Mix.Task.run("compile")

    if not opts.retime, do: record(test_args)
    Recorder.stop()

    report =
      Bench.run(
        seconds: opts.seconds,
        timeout: opts.timeout,
        log: &Mix.shell().info(&1),
        app: app_name()
      )

    Mix.shell().info(["\n", report, "\nWritten to ", Recording.report_path()])
  rescue
    error in Error -> Mix.raise(error.message)
  end

  defp record(test_args) do
    if Mix.env() != :test do
      Mix.raise("sat_bench records from `mix test`, so run it as: MIX_ENV=test mix sat.bench")
    end

    case Recorder.start() do
      {:ok, targets} ->
        Mix.shell().info(
          "sat_bench: recording calls to #{Enum.map_join(targets, ", ", &Recorder.format_mfa/1)}"
        )

      {:error, message} ->
        Mix.raise(message)
    end

    Mix.Task.run("test", test_args)
  end

  # Our own switches are taken out by hand so that everything else, including
  # `mix test` switches and their values, passes through untouched.
  defp split_args([], opts, rest), do: {opts, Enum.reverse(rest)}

  defp split_args(["--retime" | args], opts, rest),
    do: split_args(args, %{opts | retime: true}, rest)

  defp split_args(["--time", value | args], opts, rest),
    do: split_args(args, %{opts | seconds: seconds!("--time", value)}, rest)

  defp split_args(["--timeout", value | args], opts, rest),
    do: split_args(args, %{opts | timeout: seconds!("--timeout", value)}, rest)

  defp split_args([flag], _opts, _rest) when flag in ["--time", "--timeout"],
    do: Mix.raise("#{flag} expects a number of seconds")

  defp split_args([arg | args], opts, rest), do: split_args(args, opts, [arg | rest])

  defp seconds!(flag, value) do
    case Float.parse(value) do
      {seconds, ""} when seconds > 0 -> seconds
      _other -> Mix.raise("#{flag} expects a positive number of seconds, got: #{value}")
    end
  end

  defp app_name, do: Mix.Project.config()[:app] || Path.basename(File.cwd!())
end
