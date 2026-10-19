# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.DPLLTest do
  # The two DPLL candidates shipped on the sat_bench branch. The CDCL solver has
  # its own test; the released solver is covered by SimpleSatTest.
  use ExUnit.Case

  for solver <- [SimpleSat.DPLL, SimpleSat.DPLLOptimized] do
    describe inspect(solver) do
      @solver solver

      test "solves the documented examples" do
        assert {:ok, [1, -2, 3]} = @solver.solve([[1, 2, -3], [2, 3], [-2], [-1, 3]])
        assert {:ok, [1, 2]} = @solver.solve([[1], [1, 2]])
        assert {:error, :unsatisfiable} = @solver.solve([[1], [-1]])
        assert {:ok, []} = @solver.solve([])
        assert {:error, :unsatisfiable} = @solver.solve([[1], []])
      end

      test "agrees with Picosat on small random formulas" do
        :rand.seed(:exsss, {1, 2, 3})

        for _ <- 1..500 do
          clauses = random_formula()

          case {Picosat.solve(clauses), @solver.solve(clauses)} do
            {{:ok, _}, {:ok, solution}} -> assert_satisfies!(clauses, solution)
            {{:error, :unsatisfiable}, {:error, :unsatisfiable}} -> :ok
            other -> flunk("solvers disagree on #{inspect(clauses)}: #{inspect(other)}")
          end
        end
      end
    end
  end

  # Up to 6 variables and 10 clauses of up to 4 literals; duplicates and
  # tautologies are allowed, as in real input.
  defp random_formula do
    for _ <- 1..:rand.uniform(10) do
      for _ <- 1..:rand.uniform(4) do
        var = :rand.uniform(6)
        if :rand.uniform(2) == 1, do: var, else: -var
      end
    end
  end

  defp assert_satisfies!(clauses, solution) do
    assignment = MapSet.new(solution)
    violated = Enum.find(clauses, fn clause -> not Enum.any?(clause, &(&1 in assignment)) end)
    assert violated == nil, "#{inspect(solution)} does not satisfy #{inspect(violated)}"
  end
end
