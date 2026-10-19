# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# DPLL where every search step is one fused pass over the clauses (reduce,
# collect units, pick the branch clause), with allocation-free clause scans and
# input validation folded into the first pass. The E-numbered comments refer to
# the optimisation steps as they were measured. On the `sat_bench` branch it is
# one of the candidates `mix sat.bench` times.

defmodule SimpleSat.DPLLOptimized do
  @moduledoc false

  @doc """
  Finds a satisfying assignment for a formula in CNF.

  Takes a list of clauses, where each clause is a list of non-zero integers
  (literals). Returns `{:ok, solution}` with one literal per variable, sorted by
  variable. Variables whose value doesn't affect the result are set to true.

  Returns `{:error, :unsatisfiable}` when no assignment satisfies every clause,
  including when any clause is empty.

  ## Examples

      iex> SimpleSat.DPLLOptimized.solve([[1, 2, -3], [2, 3], [-2], [-1, 3]])
      {:ok, [1, -2, 3]}

      iex> SimpleSat.DPLLOptimized.solve([[1], [1, 2]])
      {:ok, [1, 2]}

      iex> SimpleSat.DPLLOptimized.solve([[1], [-1]])
      {:error, :unsatisfiable}
  """
  @spec solve([[integer]]) :: {:ok, [integer]} | {:error, :unsatisfiable}
  def solve(clauses)
  def solve([]), do: {:ok, []}

  def solve(clauses) do
    # E4c: skip building the stats map; it showed up at ~10% of a 300ns solve.
    {result, _counters} = run(clauses)
    result
  end

  # E0: search-effort counters for the benchmark. Not part of the public API.
  # `decisions` counts branch attempts (both polarities), `propagations` the
  # literals assigned by unit propagation, `conflicts` the dead ends hit.
  @doc false
  @spec solve_with_stats([[integer]]) ::
          {{:ok, [integer]} | {:error, :unsatisfiable},
           %{
             decisions: non_neg_integer,
             propagations: non_neg_integer,
             conflicts: non_neg_integer
           }}
  def solve_with_stats(clauses) do
    {result, counters} = run(clauses)
    {result, stats(counters)}
  end

  defp run([]), do: {{:ok, []}, {0, 0, 0}}

  defp run(clauses) when is_list(clauses) do
    # E5: no separate empty-clause scan; the first pass (`:none`) validates the
    # input and conflicts on an empty clause itself.
    case dpll(clauses, :none, %{}, {0, 0, 0}) do
      {nil, counters} -> {{:error, :unsatisfiable}, counters}
      {assignment, counters} -> {{:ok, solution(clauses, assignment)}, counters}
    end
  end

  defp run(other) do
    raise ArgumentError, "expected a list of clauses, got: #{inspect(other)}"
  end

  # E5: variables no clause ended up depending on are unconstrained; default
  # them to true so the solution covers every input variable. Then sort by
  # variable with `:lists.keysort/2`, which compares only the integer keys
  # (a generic `:lists.sort/1` on the tuples measured 3x slower).
  defp solution(clauses, assignment) do
    for {var, value} <- :lists.keysort(1, Map.to_list(complete(clauses, assignment))),
        do: if(value, do: var, else: -var)
  end

  defp complete([], assignment), do: assignment

  defp complete([clause | rest], assignment),
    do: complete(rest, complete_clause(clause, assignment))

  defp complete_clause([], assignment), do: assignment

  defp complete_clause([literal | rest], assignment) do
    var = abs(literal)

    case assignment do
      %{^var => _value} -> complete_clause(rest, assignment)
      _unassigned -> complete_clause(rest, Map.put(assignment, var, true))
    end
  end

  defp stats({decisions, propagations, conflicts}),
    do: %{decisions: decisions, propagations: propagations, conflicts: conflicts}

  # E2: the search runs on one fused pass per step. `reduce/2` walks the
  # clause list once, applying the literals assigned in the previous step:
  # satisfied clauses are dropped, falsified literals stripped, new unit
  # clauses collected separately, and the shortest remaining clause tracked for
  # branching. Before, each step scanned the clauses three times (collect
  # units, assign, pick the shortest clause) through Enum closures.
  #
  # Invariant: `clauses` contains no literal of an already assigned variable,
  # so a batch of freshly assigned units can be looked up in the assignment map
  # itself instead of a MapSet (E3b).
  defp dpll(clauses, assigned, assignment, counters) do
    case reduce(clauses, assigned) do
      :conflict ->
        {nil, conflict(counters)}

      {[], [], _shortest} ->
        {assignment, counters}

      {clauses, [], shortest} ->
        # E6: branch on the variable of the shortest clause, trying it true
        # first. On "at most one" encodings the shortest clauses are the binary
        # [-a, -b] ones; trying -a first sets variables false one at a time,
        # while a = true satisfies the "at least one" clause and propagates the
        # rest in a single step.
        branch(clauses, assignment, abs(hd(shortest)), counters)

      {clauses, units, _shortest} ->
        propagate(clauses, units, assignment, counters)
    end
  end

  defp branch(clauses, assignment, literal, counters) do
    case try_literal(clauses, assignment, literal, counters) do
      {nil, counters} -> try_literal(clauses, assignment, -literal, counters)
      found -> found
    end
  end

  defp try_literal(clauses, assignment, literal, {decisions, propagations, conflicts}) do
    counters = {decisions + 1, propagations, conflicts}
    dpll(clauses, {:one, literal}, record(assignment, literal), counters)
  end

  # Record the unit literals found by the last pass, then reduce against them.
  defp propagate(clauses, units, assignment, {decisions, propagations, conflicts}) do
    counters = {decisions, propagations + length(units), conflicts}

    case record_units(units, assignment) do
      :conflict -> {nil, conflict(counters)}
      assignment -> dpll(clauses, lookup(units, assignment), assignment, counters)
    end
  end

  defp lookup([unit], _assignment), do: {:one, unit}
  defp lookup(_units, assignment), do: {:many, assignment}

  defp record_units([], assignment), do: assignment

  # E4d: one map operation per unit. Put first; the map only keeps its size
  # when the variable was already assigned, and only then is the value checked.
  defp record_units([unit | rest], assignment) do
    var = abs(unit)
    value = unit > 0
    updated = Map.put(assignment, var, value)

    cond do
      map_size(updated) > map_size(assignment) -> record_units(rest, updated)
      Map.fetch!(assignment, var) == value -> record_units(rest, assignment)
      true -> :conflict
    end
  end

  defp conflict({decisions, propagations, conflicts}),
    do: {decisions, propagations, conflicts + 1}

  # One pass over the clauses. Returns :conflict, or
  # {remaining clauses, new unit literals, shortest remaining clause}.
  # E4: the per-clause helpers are inlined; the profile showed their call
  # overhead at roughly a quarter of the pass.
  @compile {:inline, reduce_clause: 2, shorter: 2, record: 2}
  defp reduce(clauses, assigned), do: reduce(clauses, assigned, [], [], nil)

  defp reduce([], _assigned, acc, units, shortest), do: {acc, units, shortest}

  defp reduce([clause | rest], assigned, acc, units, shortest) do
    case reduce_clause(clause, assigned) do
      :satisfied -> reduce(rest, assigned, acc, units, shortest)
      [] -> :conflict
      [unit] -> reduce(rest, assigned, acc, [unit | units], shortest)
      remaining -> reduce(rest, assigned, [remaining | acc], units, shorter(remaining, shortest))
    end
  end

  # Units are extracted, so a binary clause is the shortest possible; stop
  # measuring once one is found.
  defp shorter(clause, nil), do: clause
  defp shorter(_clause, [_, _] = best), do: best
  defp shorter([_, _] = clause, _best), do: clause
  defp shorter(clause, best), do: if(length(clause) < length(best), do: clause, else: best)

  # E1: scan without allocating and return the original clause when no literal
  # was falsified; only clauses that actually shrink get rebuilt (in the
  # original literal order). Before, every surviving clause was copied and
  # reversed on every assignment.
  # E5: the first pass has nothing assigned yet; use it to validate the input.
  defp reduce_clause(clause, :none), do: validate_clause(clause, clause)
  defp reduce_clause(clause, assigned), do: scan_clause(clause, assigned, clause, 0)

  defp validate_clause([], original), do: original

  defp validate_clause([literal | rest], original)
       when is_integer(literal) and literal != 0,
       do: validate_clause(rest, original)

  defp validate_clause([literal | _rest], original) do
    raise ArgumentError,
          "clause #{inspect(original)} contains #{inspect(literal)}, expected a non-zero integer"
  end

  defp validate_clause(other, _original) do
    raise ArgumentError, "expected a clause (list of non-zero integers), got: #{inspect(other)}"
  end

  defp scan_clause([], _assigned, original, _kept), do: original

  defp scan_clause([literal | rest], assigned, original, kept) do
    case status(literal, assigned) do
      true ->
        :satisfied

      false ->
        prefix = :lists.reverse(:lists.sublist(original, kept))
        rebuild_clause(rest, assigned, prefix)

      nil ->
        scan_clause(rest, assigned, original, kept + 1)
    end
  end

  defp rebuild_clause([], _assigned, acc), do: :lists.reverse(acc)

  defp rebuild_clause([literal | rest], assigned, acc) do
    case status(literal, assigned) do
      true -> :satisfied
      false -> rebuild_clause(rest, assigned, acc)
      nil -> rebuild_clause(rest, assigned, [literal | acc])
    end
  end

  # E3: the value of a literal under the literals assigned in the last step:
  # true (clause satisfied), false (literal falsified) or nil (untouched).
  # A single assigned literal is matched by integer comparison; a batch is
  # looked up in the assignment map, one lookup per literal.
  @compile {:inline, status: 2}
  defp status(literal, {:one, assigned}) when literal == assigned, do: true
  defp status(literal, {:one, assigned}) when literal == -assigned, do: false
  defp status(_literal, {:one, _assigned}), do: nil

  defp status(literal, {:many, assignment}) when literal > 0 do
    case assignment do
      %{^literal => value} -> value
      _ -> nil
    end
  end

  defp status(literal, {:many, assignment}) do
    var = -literal

    case assignment do
      %{^var => value} -> not value
      _ -> nil
    end
  end

  defp record(assignment, literal), do: Map.put(assignment, abs(literal), literal > 0)
end
