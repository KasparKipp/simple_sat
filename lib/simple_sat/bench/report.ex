# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.Bench.Report do
  @moduledoc false
  # Plain-text rendering of a bench run: one table for the whole recorded
  # workload, one for the largest formulas, and the solvers that gave up.

  @label_width 24
  @column 14

  @type run :: %{
          app: String.t() | atom(),
          calls: [String.t()],
          formulas: map(),
          whole: [{String.t(), [float()]}],
          largest: [{String.t(), [[integer()]], [{String.t(), [float()]}]}],
          gave_up: [{String.t(), String.t()}],
          timeout: number()
        }

  @spec render(run()) :: String.t()
  def render(run) do
    names = Enum.map(run.whole, &elem(&1, 0))
    solver_column = max(@column, Enum.max(Enum.map(names, &String.length/1)) + 2)

    IO.iodata_to_binary([
      header(run),
      workload_table(run.whole),
      largest_table(run.largest, names, solver_column),
      gave_up(run.gave_up, run.timeout)
    ])
  end

  defp header(run) do
    [
      "SAT solvers on #{run.app}'s formulas, #{DateTime.truncate(DateTime.utc_now(), :second)}\n",
      "Elixir #{System.version()}, OTP #{System.otp_release()}\n",
      "Recorded #{length(run.calls)} solver calls, #{map_size(run.formulas)} distinct formulas\n\n"
    ]
  end

  defp workload_table(whole) do
    fastest = whole |> Enum.map(fn {_name, samples} -> median(samples) end) |> Enum.min()

    [
      "Whole workload: every recorded call once, in order\n",
      row(["solver", "median", "min", "p95", "runs", "vs fastest"], @column),
      for {name, samples} <- Enum.sort_by(whole, fn {_name, samples} -> median(samples) end) do
        row(
          [
            name,
            duration(median(samples)),
            duration(hd(samples)),
            duration(percentile(samples, 0.95)),
            Integer.to_string(length(samples)),
            ratio(median(samples), fastest)
          ],
          @column
        )
      end
    ]
  end

  defp largest_table(largest, names, column) do
    [
      "\nLargest formulas: median per solve, * marks the fastest in the row\n",
      row(["formula", "clauses", "vars" | names], [@column, @column | widths(names, column)]),
      for {hash, cnf, per_solver} <- largest do
        row(
          [
            hash,
            Integer.to_string(length(cnf)),
            Integer.to_string(variables(cnf)) | marked_durations(per_solver)
          ],
          [@column, @column | widths(names, column)]
        )
      end
    ]
  end

  # Every cell gets a trailing character so the numbers stay aligned: `*` on
  # the fastest median of the row, a space on the others.
  defp marked_durations(per_solver) do
    medians = Enum.map(per_solver, fn {_name, samples} -> median(samples) end)
    fastest = Enum.min(medians)
    for median <- medians, do: duration(median) <> if(median == fastest, do: "*", else: " ")
  end

  defp gave_up([], _timeout), do: []

  defp gave_up(gave_up, timeout) do
    [
      "\nDropped: over #{timeout} s on a single formula\n",
      for({name, hash} <- gave_up, do: "#{name} on #{hash}\n")
    ]
  end

  defp widths(names, column), do: Enum.map(names, fn _name -> column end)

  # The first cell is left-aligned; the rest are right-aligned to one width
  # each, or all to the same width when a single integer is given.
  @spec row([String.t()], pos_integer() | [pos_integer()]) :: iodata()
  defp row(cells, column) when is_integer(column),
    do: row(cells, Enum.map(tl(cells), fn _cell -> column end))

  defp row([first | rest], columns) when is_list(columns),
    do: [
      String.pad_trailing(first, @label_width),
      Enum.zip_with(rest, columns, &String.pad_leading/2),
      ?\n
    ]

  @spec median([float()]) :: float()
  defp median(sorted), do: percentile(sorted, 0.5)

  @spec percentile([float()], float()) :: float()
  defp percentile(sorted, fraction),
    do: Enum.at(sorted, max(ceil(length(sorted) * fraction) - 1, 0))

  @spec duration(float()) :: String.t()
  defp duration(micros) when micros >= 1_000,
    do: "#{:erlang.float_to_binary(micros / 1_000, decimals: 3)} ms"

  defp duration(micros), do: "#{:erlang.float_to_binary(micros, decimals: 2)} µs"

  @spec ratio(float(), float()) :: String.t()
  defp ratio(_value, fastest) when fastest == 0, do: "n/a"
  defp ratio(value, fastest), do: "#{:erlang.float_to_binary(value / fastest, decimals: 2)}x"

  @spec variables([[integer()]]) :: non_neg_integer()
  defp variables(cnf), do: cnf |> List.flatten() |> Enum.map(&abs/1) |> Enum.uniq() |> length()
end
