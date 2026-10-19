# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.CDCLTest do
  # Instances large enough to need conflicts, learned clauses, backjumps and
  # restarts, which the small formulas in SimpleSatTest never reach.
  use ExUnit.Case

  test "agrees with picosat on random 3-SAT at the phase transition" do
    :rand.seed(:exsss, {4, 5, 6})

    for _ <- 1..200 do
      clauses = random_3sat(50, 213)

      case {Picosat.solve(clauses), SimpleSat.CDCL.solve(clauses)} do
        {{:ok, _}, {:ok, solution}} -> assert_satisfies!(clauses, solution)
        {{:error, :unsatisfiable}, {:error, :unsatisfiable}} -> :ok
        other -> flunk("solvers disagree on #{inspect(clauses)}: #{inspect(other)}")
      end
    end
  end

  test "pigeonhole formulas are unsatisfiable" do
    for holes <- 4..5 do
      assert {:error, :unsatisfiable} = SimpleSat.CDCL.solve(pigeonhole(holes))
    end
  end

  test "8 queens is satisfiable" do
    clauses = queens(8)
    assert {:ok, solution} = SimpleSat.CDCL.solve(clauses)
    assert_satisfies!(clauses, solution)
    assert length(solution) == 64
    assert solution |> Enum.filter(&(&1 > 0)) |> length() == 8
  end

  test "duplicate and tautological literals" do
    assert {:ok, [1, 2]} = SimpleSat.CDCL.solve([[1, 1], [2, -2]])
    assert {:ok, [-1, 2]} = SimpleSat.CDCL.solve([[-1, -1, -1], [1, 2, 2], [1, -1]])
    assert {:error, :unsatisfiable} = SimpleSat.CDCL.solve([[1, 1], [-1, -1]])
  end

  test "conflicting unit clauses are unsatisfiable without search" do
    assert {:error, :unsatisfiable} = SimpleSat.CDCL.solve([[2], [3], [1, 2], [-2]])
  end

  test "unconstrained variables are set to true" do
    assert {:ok, [1, 2, 3]} = SimpleSat.CDCL.solve([[1, 2, 3]])
  end

  defp random_3sat(n_vars, n_clauses) do
    for _ <- 1..n_clauses do
      Stream.repeatedly(fn -> :rand.uniform(n_vars) end)
      |> Stream.uniq()
      |> Enum.take(3)
      |> Enum.map(fn v -> if :rand.uniform(2) == 1, do: v, else: -v end)
    end
  end

  defp pigeonhole(holes) do
    var = fn p, j -> (p - 1) * holes + j end
    placement = for p <- 1..(holes + 1), do: Enum.map(1..holes, &var.(p, &1))

    exclusivity =
      for j <- 1..holes, p1 <- 1..(holes + 1), p2 <- (p1 + 1)..(holes + 1)//1 do
        [-var.(p1, j), -var.(p2, j)]
      end

    placement ++ exclusivity
  end

  defp queens(n) do
    var = fn r, c -> (r - 1) * n + c end
    cells = for r <- 1..n, c <- 1..n, do: {r, c}
    rows = for r <- 1..n, do: Enum.map(1..n, &var.(r, &1))

    conflicts =
      for {r1, c1} <- cells,
          {r2, c2} <- cells,
          {r1, c1} < {r2, c2},
          r1 == r2 or c1 == c2 or abs(r1 - r2) == abs(c1 - c2),
          do: [-var.(r1, c1), -var.(r2, c2)]

    rows ++ conflicts
  end

  defp assert_satisfies!(clauses, solution) do
    assignment = MapSet.new(solution)
    violated = Enum.find(clauses, fn clause -> not Enum.any?(clause, &(&1 in assignment)) end)
    assert violated == nil, "#{inspect(solution)} does not satisfy #{inspect(violated)}"
  end
end
