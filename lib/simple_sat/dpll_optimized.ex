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
    case dpll(clauses, :none, %{}) do
      nil -> {:error, :unsatisfiable}
      assignment -> {:ok, solution(clauses, assignment)}
    end
  end

  # Variables no clause ended up depending on are unconstrained; default
  # them to true so the solution covers every input variable. Then sort by
  # variable with `:lists.keysort/2`.
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

  defp dpll(clauses, assigned, assignment) do
    case reduce(clauses, assigned) do
      :conflict ->
        nil

      {[], [], _shortest} ->
        assignment

      {clauses, [], shortest} ->
        # Try the shortest clause's variable true first. On "at most one"
        # encodings the shortest clauses are the binary [-a, -b] ones; -a first
        # sets variables false one at a time, a = true propagates the rest.
        literal = abs(hd(shortest))

        try_literal(clauses, assignment, literal) ||
          try_literal(clauses, assignment, -literal)

      {clauses, units, _shortest} ->
        propagate(clauses, units, assignment)
    end
  end

  defp try_literal(clauses, assignment, literal),
    do: dpll(clauses, {:one, literal}, record(assignment, literal))

  defp propagate(clauses, units, assignment) do
    case record_units(units, assignment) do
      :conflict -> nil
      assignment -> dpll(clauses, lookup(units, assignment), assignment)
    end
  end

  defp lookup([unit], _assignment), do: {:one, unit}
  defp lookup(_units, assignment), do: {:many, assignment}

  defp record_units([], assignment), do: assignment

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

  # Apply the assigned literals to every clause: drop satisfied clauses, strip
  # falsified literals, conflict if a clause becomes empty. Returns :conflict or
  # {remaining clauses, new unit literals, shortest remaining clause}.
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

  defp reduce_clause(clause, :none), do: clause
  defp reduce_clause(clause, assigned), do: scan_clause(clause, assigned, clause, 0)

  defp scan_clause([], _assigned, original, _kept), do: original

  defp scan_clause([literal | rest], assigned, original, kept) do
    case status(literal, assigned) do
      true ->
        :satisfied

      false ->
        prefix = Enum.reverse(Enum.take(original, kept))
        rebuild_clause(rest, assigned, prefix)

      nil ->
        scan_clause(rest, assigned, original, kept + 1)
    end
  end

  defp rebuild_clause([], _assigned, acc), do: Enum.reverse(acc)

  defp rebuild_clause([literal | rest], assigned, acc) do
    case status(literal, assigned) do
      true -> :satisfied
      false -> rebuild_clause(rest, assigned, acc)
      nil -> rebuild_clause(rest, assigned, [literal | acc])
    end
  end

  # The value of a literal under the literals assigned in the last step:
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
